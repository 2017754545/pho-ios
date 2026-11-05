package api

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/fregie/img_syncer/server/imgmanager"
)

const (
	rangeBufferSize       = 64 * 1024
	HeaderDate            = "Image-Date"
	HeaderEncryptType     = "Image-Encrypt-Type"
	HeaderEncryptPassword = "Image-Encrypt-Password"
	HeaderIsLivePhoto     = "Image-Is-Live-Photo"
	// HeaderDestDir：手动上传的目标子目录（相对于驱动根目录，如
	// "manual"），仅手动上传发送；自动同步不发送。服务端按
	// SanitizeDestDir 校验，非法值返回 400，绝不静默回落到根目录。
	HeaderDestDir = "Image-Dest-Dir"
	// HeaderDestExact：精确目录模式（"1"/"true"）。与 HeaderDestDir
	// 联用时文件直接落在 DestDir 下，不再按类型分子目录（见
	// imgmanager.WithExactDestDir）；DestDir 为空时落在根目录。
	// 缺省或非法值按 false，即原有类型分目录行为。
	HeaderDestExact = "Image-Dest-Exact"
	maxUploadSize   = 500 << 20 // 500MB
)

// destDirFromHeader 读取并校验 Image-Dest-Dir 头：缺省返回 ""（自动
// 同步布局）；非法值返回错误，调用方应以 400 拒绝该上传。exact 为
// true 时改用 SanitizeBrowseDir 校验（日期形状目录也可以是精确
// 上传目标）。
func destDirFromHeader(r *http.Request, exact bool) (string, error) {
	raw := r.Header.Get(HeaderDestDir)
	if raw == "" {
		return "", nil
	}
	if exact {
		return imgmanager.SanitizeBrowseDir(raw)
	}
	return imgmanager.SanitizeDestDir(raw)
}

// exactDestFromHeader 读取 Image-Dest-Exact 头：缺省或非法值按
// false（原有类型分目录行为），与 IsLivePhoto 头的宽容解析一致。
func exactDestFromHeader(r *http.Request) bool {
	exact, _ := strconv.ParseBool(r.Header.Get(HeaderDestExact))
	return exact
}

func getEncryptType(t string) imgmanager.EncryptType {
	switch t {
	case "AES_128_CFB":
		return imgmanager.AES_128_CFB
	case "AES_256_GCM":
		return imgmanager.AES_256_GCM
	}
	return imgmanager.None
}

func (a *api) SetHttpPort(port int) {
	a.httpPort = port
}

func (a *api) HttpHandler() http.Handler {
	return http.HandlerFunc(a.httpHandler)
}

func (a *api) httpHandler(w http.ResponseWriter, r *http.Request) {
	// 目录浏览端点在下载/上传分支之前拦截：GET 下载把路径当作文件
	// 名，POST 上传把路径当作目标文件名，"/__dir/..." 若落入任一
	// 分支都会被误解为文件操作。
	switch r.URL.Path {
	case "/__dir/list", "/__dir/mkdir":
		if r.Method != http.MethodPost {
			w.Header().Set("Allow", "POST")
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		if r.URL.Path == "/__dir/list" {
			a.httpDirList(w, r)
		} else {
			a.httpDirMkdir(w, r)
		}
		return
	}
	switch r.Method {
	case http.MethodGet:
		a.httpDownload(w, r)
	case http.MethodPost:
		if strings.HasPrefix(r.URL.Path, "/thumbnail/") {
			a.httpUploadThumbnail(w, r)
		} else if strings.HasPrefix(r.URL.Path, "/live/") {
			a.httpUploadLiveVideo(w, r)
		} else {
			a.httpUpload(w, r)
		}
	default:
		// 未知方法此前无分支：net/http 隐式返回 200 空 body。
		w.Header().Set("Allow", "GET, POST")
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func (a *api) httpUpload(w http.ResponseWriter, r *http.Request) {
	path := r.URL.Path
	if path == "" {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	if r.ContentLength == 0 {
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	if r.ContentLength < 0 {
		// 分块传输（ContentLength==-1）无声明长度：sizeCheckReader
		// 无法校验，拒绝并要求 Length Required。Dart 客户端始终
		// 设置长度，应用路径不受影响。
		w.WriteHeader(http.StatusLengthRequired)
		return
	}
	date := r.Header.Get(HeaderDate)
	enctype := getEncryptType(r.Header.Get(HeaderEncryptType))
	encPassword := r.Header.Get(HeaderEncryptPassword)
	isLivePhotoStr := r.Header.Get(HeaderIsLivePhoto)
	isLivePhoto, err := strconv.ParseBool(isLivePhotoStr)
	if err != nil {
		isLivePhoto = false
	}
	length := r.ContentLength
	dateTime, err := time.Parse("2006:01:02 15:04:05", date)
	if err != nil {
		dateTime = time.Now()
	}
	// 同一个有效日期同时用于文件名编码与存储目录：此前 genPath 在
	// 内部把 1990 年前日期换成 Now，而文件名已按原日期编码，两者分叉。
	dateTime = imgmanager.EffectiveFileDate(dateTime)
	name := strings.TrimPrefix(path, "/")
	name, err = sanitizePath(name)
	if err != nil {
		http.Error(w, "invalid path", http.StatusBadRequest)
		return
	}
	exact := exactDestFromHeader(r)
	destDir, err := destDirFromHeader(r, exact)
	if err != nil {
		http.Error(w, "invalid dest dir: "+err.Error(), http.StatusBadRequest)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxUploadSize)
	err = a.im.Upload(r.Body, length, encodeName(dateTime, name), dateTime, imgmanager.WithEncrypt(imgmanager.EncryptOption{
		Type:     enctype,
		Password: encPassword,
	}), imgmanager.IsLivePhoto(isLivePhoto), imgmanager.WithDestDir(destDir), imgmanager.WithExactDestDir(exact))

	if err != nil {
		var maxBytesErr *http.MaxBytesError
		if errors.As(err, &maxBytesErr) {
			w.WriteHeader(http.StatusRequestEntityTooLarge)
		} else {
			w.WriteHeader(http.StatusBadRequest)
		}
		w.Write([]byte(err.Error()))
		return
	}
	r.Body.Close()
	w.WriteHeader(http.StatusOK)
}

func (a *api) httpUploadThumbnail(w http.ResponseWriter, r *http.Request) {
	path := r.URL.Path
	if path == "" {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	if r.ContentLength == 0 {
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	if r.ContentLength < 0 {
		// 分块传输（ContentLength==-1）无声明长度：sizeCheckReader
		// 无法校验，拒绝并要求 Length Required。Dart 客户端始终
		// 设置长度，应用路径不受影响。
		w.WriteHeader(http.StatusLengthRequired)
		return
	}
	name := strings.TrimPrefix(path, "/thumbnail/")
	name, err := sanitizePath(name)
	if err != nil {
		http.Error(w, "invalid path", http.StatusBadRequest)
		return
	}
	date := r.Header.Get(HeaderDate)
	enctype := getEncryptType(r.Header.Get(HeaderEncryptType))
	encPassword := r.Header.Get(HeaderEncryptPassword)
	isLivePhotoStr := r.Header.Get(HeaderIsLivePhoto)
	isLivePhoto, err := strconv.ParseBool(isLivePhotoStr)
	if err != nil {
		isLivePhoto = false
	}
	length := r.ContentLength
	dateTime, err := time.Parse("2006:01:02 15:04:05", date)
	if err != nil {
		dateTime = time.Now()
	}
	// 同一个有效日期同时用于文件名编码与存储目录：此前 genPath 在
	// 内部把 1990 年前日期换成 Now，而文件名已按原日期编码，两者分叉。
	dateTime = imgmanager.EffectiveFileDate(dateTime)
	exact := exactDestFromHeader(r)
	destDir, err := destDirFromHeader(r, exact)
	if err != nil {
		http.Error(w, "invalid dest dir: "+err.Error(), http.StatusBadRequest)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxUploadSize)
	err = a.im.UploadThumbnail(r.Body, length, encodeName(dateTime, name), dateTime, imgmanager.WithEncrypt(imgmanager.EncryptOption{
		Type:     enctype,
		Password: encPassword,
	}), imgmanager.IsLivePhoto(isLivePhoto), imgmanager.WithDestDir(destDir), imgmanager.WithExactDestDir(exact))
	if err != nil {
		var maxBytesErr *http.MaxBytesError
		if errors.As(err, &maxBytesErr) {
			w.WriteHeader(http.StatusRequestEntityTooLarge)
		} else {
			w.WriteHeader(http.StatusBadRequest)
		}
		w.Write([]byte(err.Error()))
		return
	}
	r.Body.Close()
	w.WriteHeader(http.StatusOK)
}

func (a *api) httpUploadLiveVideo(w http.ResponseWriter, r *http.Request) {
	path := r.URL.Path
	if path == "" {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	if r.ContentLength == 0 {
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	if r.ContentLength < 0 {
		// 分块传输（ContentLength==-1）无声明长度：sizeCheckReader
		// 无法校验，拒绝并要求 Length Required。Dart 客户端始终
		// 设置长度，应用路径不受影响。
		w.WriteHeader(http.StatusLengthRequired)
		return
	}
	name := strings.TrimPrefix(path, "/live/")
	name, err := sanitizePath(name)
	if err != nil {
		http.Error(w, "invalid path", http.StatusBadRequest)
		return
	}
	date := r.Header.Get(HeaderDate)
	enctype := getEncryptType(r.Header.Get(HeaderEncryptType))
	encPassword := r.Header.Get(HeaderEncryptPassword)
	length := r.ContentLength
	dateTime, err := time.Parse("2006:01:02 15:04:05", date)
	if err != nil {
		dateTime = time.Now()
	}
	// 同一个有效日期同时用于文件名编码与存储目录：此前 genPath 在
	// 内部把 1990 年前日期换成 Now，而文件名已按原日期编码，两者分叉。
	dateTime = imgmanager.EffectiveFileDate(dateTime)
	// Live 视频强制 image + live_ 布局（见 genPath）：伴生视频必须与
	// 照片同目录，IsLivePhoto(true) 保证类型目录取 image 而非 video。
	exact := exactDestFromHeader(r)
	destDir, err := destDirFromHeader(r, exact)
	if err != nil {
		http.Error(w, "invalid dest dir: "+err.Error(), http.StatusBadRequest)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxUploadSize)
	err = a.im.UploadLiveVideo(r.Body, length, encodeName(dateTime, name), dateTime, imgmanager.WithEncrypt(imgmanager.EncryptOption{
		Type:     enctype,
		Password: encPassword,
	}), imgmanager.IsLivePhoto(true), imgmanager.WithDestDir(destDir), imgmanager.WithExactDestDir(exact))
	if err != nil {
		var maxBytesErr *http.MaxBytesError
		if errors.As(err, &maxBytesErr) {
			w.WriteHeader(http.StatusRequestEntityTooLarge)
		} else {
			w.WriteHeader(http.StatusBadRequest)
		}
		w.Write([]byte(err.Error()))
		return
	}
	r.Body.Close()
	w.WriteHeader(http.StatusOK)
}

// dirRequest 是 /__dir/list 与 /__dir/mkdir 的请求体：dir 相对
// 于驱动根目录，"" 表示根目录。
type dirRequest struct {
	Dir string `json:"dir"`
}

// dirEntry 是 /__dir/list 的响应条目：单层直接子项，排序由客户端负责。
type dirEntry struct {
	Name    string    `json:"name"`
	IsDir   bool      `json:"is_dir"`
	Size    int64     `json:"size"`
	ModTime time.Time `json:"mod_time"`
}

type dirListResponse struct {
	Entries []dirEntry `json:"entries"`
}

// httpDirList 处理 POST /__dir/list：返回 dir 的单层条目。
// 目录不存在、驱动未配置、dir 非法时返回 400 与错误消息。
func (a *api) httpDirList(w http.ResponseWriter, r *http.Request) {
	var req dirRequest
	if err := decodeDirRequest(w, r, &req); err != nil {
		return
	}
	entries, err := a.im.ListDir(req.Dir)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	resp := dirListResponse{Entries: make([]dirEntry, 0, len(entries))}
	for _, e := range entries {
		resp.Entries = append(resp.Entries, dirEntry{
			Name:    e.Name,
			IsDir:   e.IsDir,
			Size:    e.Size,
			ModTime: e.ModTime,
		})
	}
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(resp); err != nil {
		log.Printf("encode dir list response failed: %v", err)
	}
}

// httpDirMkdir 处理 POST /__dir/mkdir：创建 dir 及其父目录。
// dir 非法时返回 400 且驱动一次都不会被调用。
func (a *api) httpDirMkdir(w http.ResponseWriter, r *http.Request) {
	var req dirRequest
	if err := decodeDirRequest(w, r, &req); err != nil {
		return
	}
	if err := a.im.MkdirDir(req.Dir); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Write([]byte(`{"ok":true}`))
}

// decodeDirRequest 读 /__dir/* 的 JSON 请求体（限 64KiB）：
// 读/解析失败时写 400 并返回错误，调用方直接返回。
func decodeDirRequest(w http.ResponseWriter, r *http.Request, req *dirRequest) error {
	r.Body = http.MaxBytesReader(w, r.Body, 64<<10)
	defer r.Body.Close()
	if err := json.NewDecoder(r.Body).Decode(req); err != nil {
		http.Error(w, "invalid request body: "+err.Error(), http.StatusBadRequest)
		return err
	}
	return nil
}

type downloadType int

const (
	downloadTypeNormal downloadType = iota
	downloadTypeThumbnail
	downloadTypeLiveVideo
)

func (a *api) httpDownload(w http.ResponseWriter, r *http.Request) {
	path := r.URL.Path
	if path == "" {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	downloadType := downloadTypeNormal
	if strings.HasPrefix(path, "/thumbnail") {
		downloadType = downloadTypeThumbnail
		path = strings.TrimPrefix(path, "/thumbnail")
	} else if strings.HasPrefix(path, "/live") {
		downloadType = downloadTypeLiveVideo
		path = strings.TrimPrefix(path, "/live")
	}
	path = strings.TrimPrefix(path, "/")
	cleaned, err := sanitizePath(path)
	if err != nil {
		http.Error(w, "invalid path", http.StatusBadRequest)
		return
	}
	path = cleaned
	enctype := getEncryptType(r.Header.Get(HeaderEncryptType))
	encPassword := r.Header.Get(HeaderEncryptPassword)
	rangeHeader := r.Header.Get("Range")
	if rangeHeader != "" {
		rangeHeader = strings.TrimSpace(rangeHeader)
		kv := strings.Split(rangeHeader, "=")
		if len(kv) != 2 || kv[0] != "bytes" {
			http.Error(w, "bad range", http.StatusBadRequest)
			return
		}
		parts := strings.Split(kv[1], "-")
		if len(parts) != 2 {
			http.Error(w, "bad range", http.StatusBadRequest)
			return
		}
		if parts[0] == "" {
			http.Error(w, "suffix byte range not supported", http.StatusBadRequest)
			return
		}
		start, err := strconv.ParseInt(parts[0], 10, 64)
		if err != nil {
			http.Error(w, "bad range", http.StatusBadRequest)
			return
		}
		if start < 0 {
			http.Error(w, "invalid range start", http.StatusBadRequest)
			return
		}
		var img *imgmanager.Image
		switch downloadType {
		case downloadTypeNormal:
			img, err = a.im.GetOffset(path, start, imgmanager.WithEncrypt(imgmanager.EncryptOption{
				Type:     enctype,
				Password: encPassword,
			}))
		case downloadTypeLiveVideo:
			img, err = a.im.GetLiveVideoOffset(path, start, imgmanager.WithEncrypt(imgmanager.EncryptOption{
				Type:     enctype,
				Password: encPassword,
			}))
		case downloadTypeThumbnail:
			http.Error(w, "Not support Range", http.StatusBadRequest)
			return
		}
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		defer img.Content.Close()
		// 范围边界统一在 HTTP 层校验（各后端 offset==size 均返回空流，
		// 但 HTTP 语义上 start 超出文件末尾是 416）：
		// start >= size 时不再算出负的 Content-Length。
		if img.Size < 0 {
			http.Error(w, "invalid file size", http.StatusInternalServerError)
			return
		}
		if start >= img.Size {
			w.Header().Set("Content-Range", fmt.Sprintf("bytes */%d", img.Size))
			http.Error(w, "range start beyond file size", http.StatusRequestedRangeNotSatisfiable)
			return
		}
		var readLen int64 = img.Size - start
		end := img.Size - 1
		if len(parts) > 1 && parts[1] != "" {
			end, err = strconv.ParseInt(parts[1], 10, 64) // 解析 end 部分
			if err != nil {
				// 畸形 Range end 是客户端错误，此前返回 500。
				http.Error(w, "bad range", http.StatusBadRequest)
				return
			}
			if end < 0 {
				http.Error(w, "invalid range end", http.StatusBadRequest)
				return
			}
			if end < start {
				http.Error(w, "invalid range: end before start", http.StatusBadRequest)
				return
			}
			if end > img.Size-1 {
				end = img.Size - 1
			}
			readLen = end - start + 1
		}
		w.Header().Add("Content-Type", img.ContentType)
		w.Header().Add("Content-Length", strconv.FormatInt(readLen, 10))
		w.Header().Add("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, end, img.Size))
		// for k, v := range w.Header() {
		// 	log.Printf("Header: %s: %s", k, v)
		// }
		w.WriteHeader(http.StatusPartialContent)
		_, err = io.CopyBuffer(w, io.LimitReader(img.Content, readLen), make([]byte, rangeBufferSize))
		if err != nil {
			log.Printf("Error copying image content: %v", err)
			return
		}
		return
	}
	var img *imgmanager.Image
	switch downloadType {
	case downloadTypeNormal:
		img, err = a.im.GetImg(path, imgmanager.WithEncrypt(imgmanager.EncryptOption{
			Type:     enctype,
			Password: encPassword,
		}))
	case downloadTypeThumbnail:
		img, err = a.im.GetThumbnail(path, imgmanager.WithEncrypt(imgmanager.EncryptOption{
			Type:     enctype,
			Password: encPassword,
		}))
	case downloadTypeLiveVideo:
		img, err = a.im.GetLiveVideoOffset(path, 0, imgmanager.WithEncrypt(imgmanager.EncryptOption{
			Type:     enctype,
			Password: encPassword,
		}))
	}
	if err != nil {
		w.WriteHeader(http.StatusBadRequest)
		w.Write([]byte(err.Error()))
		return
	}
	defer img.Content.Close()
	w.Header().Add("Content-Length", strconv.FormatInt(img.Size, 10))
	w.Header().Add("Content-Type", img.ContentType)
	w.WriteHeader(http.StatusOK)
	_, err = io.Copy(w, img.Content)
	if err != nil {
		w.Write([]byte(err.Error()))
		return
	}
}

// func (a *api) httpDownloadThumbnail(w http.ResponseWriter, r *http.Request) {
// 	path := r.URL.Path
// 	if path == "" {
// 		w.WriteHeader(http.StatusNotFound)
// 		return
// 	}
// 	enctype := getEncryptType(r.Header.Get(HeaderEncryptType))
// 	encPassword := r.Header.Get(HeaderEncryptPassword)
// 	realPath := strings.TrimPrefix(path, "/thumbnail")
// 	img, err := a.im.GetThumbnail(realPath, imgmanager.WithEncrypt(imgmanager.EncryptOption{
// 		Type:     enctype,
// 		Password: encPassword,
// 	}))
// 	if err != nil {
// 		w.WriteHeader(http.StatusInternalServerError)
// 		w.Write([]byte(err.Error()))
// 		return
// 	}
// 	contentType := mime.TypeByExtension(filepath.Ext(realPath))
// 	defer img.Content.Close()
// 	w.Header().Add("Content-Length", strconv.FormatInt(img.Size, 10))
// 	w.Header().Add("Content-Type", contentType)
// 	w.WriteHeader(http.StatusOK)
// 	_, err = io.Copy(w, img.Content)
// 	if err != nil {
// 		w.Write([]byte(err.Error()))
// 		return
// 	}
// }

func encodeName(time time.Time, name string) string {
	return fmt.Sprintf("%s_%s", time.Format("20060102030405"), name)
}
