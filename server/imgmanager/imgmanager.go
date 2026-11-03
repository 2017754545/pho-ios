package imgmanager

import (
	"encoding/binary"
	"fmt"
	"io"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	pb "github.com/fregie/img_syncer/proto"
	"github.com/fregie/img_syncer/server/util"
)

const (
	defaultWorkerNum          = 2
	defaultThumbnailMaxWidth  = 500
	defaultThumbnailMaxHeight = 500
	defaultThumbnailDir       = ".thumbnail"
)

type ImgManager struct {
	dri       StorageDrive
	driveMu   sync.RWMutex
	dirType   pb.DirectoryType
	dirTypeMu sync.RWMutex
	actCh     chan action
	stopCh    chan struct{}
	wg        sync.WaitGroup
	closeOnce sync.Once
	logger    *log.Logger
	opt       Option
}

type Option struct {
	WorkerNum          int
	ThumbnailMaxWidth  int
	ThumbnailMaxHeight int
	ThumbbailQuality   int
}

func NewImgManager(opt Option) *ImgManager {
	if opt.WorkerNum <= 0 {
		opt.WorkerNum = defaultWorkerNum
	}
	if opt.ThumbnailMaxWidth <= 0 {
		opt.ThumbnailMaxWidth = defaultThumbnailMaxWidth
	}
	if opt.ThumbnailMaxHeight <= 0 {
		opt.ThumbnailMaxHeight = defaultThumbnailMaxHeight
	}
	im := &ImgManager{
		actCh:  make(chan action, 10),
		stopCh: make(chan struct{}),
		logger: log.New(os.Stdout, "[ImgManager] ", log.LstdFlags),
		opt:    opt,
		dri:    &UnimplementedDrive{},
	}
	im.wg.Add(im.opt.WorkerNum)
	for i := 0; i < im.opt.WorkerNum; i++ {
		go im.runWorker()
	}
	return im
}

func (im *ImgManager) SetDirectoryType(dirType pb.DirectoryType) {
	im.dirTypeMu.Lock()
	defer im.dirTypeMu.Unlock()
	im.dirType = dirType
}

func (im *ImgManager) SetDrive(dri StorageDrive) {
	im.driveMu.Lock()
	defer im.driveMu.Unlock()
	if im.dri != nil {
		im.dri.Close()
	}
	im.dri = dri
}

func (im *ImgManager) Drive() StorageDrive {
	im.driveMu.RLock()
	defer im.driveMu.RUnlock()
	return im.dri
}

// Close 优雅关闭：关闭 stopCh 通知所有 worker 退出，worker 在退出前排空
// actCh 中已入队的待删除任务（见 runWorker），等待全部 worker 完成后返回。
// 可重复调用：第二次及以后的调用直接返回 nil，不会重复关闭 stopCh 而 panic。
// 注意：Close 返回后新入队的异步删除会被丢弃（DeleteSingleImgAsync 在
// stopCh 已关闭时不再入队）；同步删除（DeleteSingleImg/DeleteImg）不受影响。
func (im *ImgManager) Close() error {
	im.closeOnce.Do(func() {
		close(im.stopCh)
		im.wg.Wait()
	})
	return nil
}

func (im *ImgManager) drive() (StorageDrive, func()) {
	im.driveMu.RLock()
	return im.dri, func() { im.driveMu.RUnlock() }
}

type actType int

const (
	actDelete actType = iota
)

type action struct {
	t    actType
	path string
}

func (im *ImgManager) runWorker() {
	defer im.wg.Done()
	for {
		select {
		case <-im.stopCh:
			// 排空已入队的待删除任务后再退出，避免 Close 丢弃排队中的删除。
			for {
				select {
				case act := <-im.actCh:
					im.doAction(act)
				default:
					return
				}
			}
		case act := <-im.actCh:
			im.doAction(act)
		}
	}
}

func (im *ImgManager) doAction(act action) {
	switch act.t {
	case actDelete:
		d, unlock := im.drive()
		defer unlock()
		if err := d.Delete(act.path); err != nil {
			im.logger.Println("Error deleting image:", err)
		}
	}
}

type Options struct {
	EncyptOption EncryptOption
	IsLivePhoto  bool
	// DestDir 是手动上传的目标子目录（相对于驱动根目录，如 "manual"），
	// 由 HTTP 头 Image-Dest-Dir 传入。为空表示自动同步的默认布局
	// （根目录 + 日期子目录）。非空时文件按类型分目录存放，不再按
	// 日期分子目录（见 genPath）。调用方必须先经 SanitizeDestDir
	// 校验；Upload 系列方法也会在生成路径前再次校验，非法值直接
	// 返回错误，绝不静默回落到根目录（否则手动上传会与自动同步
	// 混进同一个文件夹）。
	DestDir string
}

// EncryptType 和常量已迁移至 encrypt.go

type EncryptOption struct {
	Type     EncryptType
	Password string
}

type OptionFunc func(*Options)

func WithEncrypt(opt EncryptOption) OptionFunc {
	return func(o *Options) {
		o.EncyptOption = opt
	}
}

func IsLivePhoto(isLivePhoto bool) OptionFunc {
	return func(o *Options) {
		o.IsLivePhoto = isLivePhoto
	}
}

// WithDestDir 设置手动上传的目标子目录。值必须是 SanitizeDestDir
// 接受的相对路径；Upload 系列方法在生成路径前会再次校验。
func WithDestDir(destDir string) OptionFunc {
	return func(o *Options) {
		o.DestDir = destDir
	}
}

// SanitizeDestDir 校验并规范化手动上传的目标子目录：相对于驱动
// 根目录的相对路径，用 `/` 分隔。空字符串表示“未指定”（调用方
// 用它表示自动同步布局，合法）。拒绝：反斜杠、绝对路径（以 `/`
// 开头）、任何 `..` / `.` 元素、空段（`//`、首尾斜杠）、首段为
// `live` / `.thumbnail`、首段为日期目录形状（4 位或 8 位纯数字，
// 会与 RangeByDate 的日期目录遍历重复访问）。严格拒绝而非折叠，
// 因为目录浏览 UI 从不产生这类段，且静默折叠会把文件写到用户
// 没选过的目录。
func SanitizeDestDir(raw string) (string, error) {
	if raw == "" {
		return "", nil
	}
	if strings.Contains(raw, "\\") {
		return "", fmt.Errorf("invalid dest dir separator: %s", raw)
	}
	if strings.HasPrefix(raw, "/") {
		return "", fmt.Errorf("absolute dest dir not allowed: %s", raw)
	}
	if util.HasDotDotElement(raw) {
		return "", fmt.Errorf("path traversal not allowed: %s", raw)
	}
	parts := strings.Split(raw, "/")
	for _, p := range parts {
		if p == "" {
			return "", fmt.Errorf("empty path segment in dest dir: %s", raw)
		}
		if p == "." {
			return "", fmt.Errorf("invalid path segment in dest dir: %s", raw)
		}
	}
	first := parts[0]
	if first == "live" || first == ".thumbnail" {
		return "", fmt.Errorf("reserved dest dir name: %s", raw)
	}
	if isDateDirShape(first) {
		return "", fmt.Errorf("dest dir must not look like a date directory: %s", raw)
	}
	return strings.Join(parts, "/"), nil
}

// isDateDirShape 报告名字是否为日期目录形状：4 位或 8 位纯数字，
// 与 RangeByDate 的年目录（4 位）/ YYYYMMDD 目录（8 位）相同。
func isDateDirShape(name string) bool {
	if len(name) != 4 && len(name) != 8 {
		return false
	}
	for i := 0; i < len(name); i++ {
		if name[i] < '0' || name[i] > '9' {
			return false
		}
	}
	return true
}

// EffectiveFileDate 把照片日期归一为可用于存储路径的“有效日期”：
// 零值或早于 1990-01-01 的日期（客户端缺失/损坏的元数据常见值）
// 一律回退到当前时间，且一次调用只取一次 time.Now()。
// 调用方必须在编码文件名（encodeName）与调用 Upload 之前用同一个
// EffectiveFileDate 结果，否则目录日期（genPath 用 date 参数）与
// 文件名内嵌的时间戳（调用方编码时用的日期）会分叉：此前 genPath
// 在内部把 1990 年前的日期换成 Now，而文件名早已按原日期编码，
// 同一张照片的目录与文件名日期不一致。genPath 自身仍做同样的归一
// 化作为兜底（直接调用 Upload 的调用方未必经过 HTTP 层）。
func EffectiveFileDate(date time.Time) time.Time {
	if date.IsZero() || date.Before(time.Date(1990, 1, 1, 0, 0, 0, 0, time.UTC)) {
		return time.Now()
	}
	return date
}

// genPath 构造存储路径。两种布局：
//   - 默认（DestDir 为空）：{日期目录}/{文件名}，日期目录由 dirType
//     决定（YYYY/MM/DD 或 YYYYMMDD），与历史行为一致。
//   - 手动上传（DestDir 非空）：{dest}/{video|image}/{文件名}，不按
//     日期分子目录。类型目录由文件扩展名决定（util.IsVideo）；
//     Live Photo 的伴生视频（IsLivePhoto 且扩展名为视频）强制进
//     image 目录，与照片同在 live_<base>/ 子目录内——
//     GetLiveVideoOffset 按照片所在目录查找伴生视频，视频必须与
//     照片相邻，绝不能进 video/ 目录。fixPath（.aes 后缀）行为不变。
func (im *ImgManager) genPath(name string, date time.Time, options Options) string {
	date = EffectiveFileDate(date)
	elems := []string{}
	if options.DestDir != "" {
		elems = append(elems, options.DestDir)
		if options.IsLivePhoto || !util.IsVideo(name) {
			elems = append(elems, "image")
		} else {
			elems = append(elems, "video")
		}
	} else {
		im.dirTypeMu.RLock()
		dirType := im.dirType
		im.dirTypeMu.RUnlock()
		switch dirType {
		case pb.DirectoryType_DIRECTORY_TYPE_01:
			elems = append(elems, date.Format("2006/01/02"))
		case pb.DirectoryType_DIRECTORY_TYPE_02:
			elems = append(elems, date.Format("20060102/"))
		default:
			elems = append(elems, date.Format("2006/01/02"))
		}
	}
	if options.IsLivePhoto {
		elems = append(elems, fmt.Sprintf("live_%s", name[:len(name)-len(filepath.Ext(name))]))
	}
	elems = append(elems, name)
	path := filepath.Join(elems...)
	if options.EncyptOption.Password != "" {
		path = fixPath(path, options.EncyptOption.Type)
	}
	return path
}

// validateDestDir 校验 Options.DestDir 并返回规范化后的值：
// Upload 系列方法在生成路径前调用，非法值直接报错，绝不静默
// 回落到根目录。HTTP 层也会先行校验（返回 400），这里是纵深防御
// （直接调用 Upload 的调用方同样受约束）。
func validateDestDir(options *Options) error {
	if options.DestDir == "" {
		return nil
	}
	sanitized, err := SanitizeDestDir(options.DestDir)
	if err != nil {
		return fmt.Errorf("invalid dest dir: %w", err)
	}
	options.DestDir = sanitized
	return nil
}

// sizeCheckReader 校验 reader 实际产出的字节数与声明一致。
// 防止截断上传（reader 提前 EOF）被当作完整文件保存为损坏文件（issue #83/#82）。
// 实现 io.ReadCloser：Close 透传到底层 reader，保证 GCM 加密 pipe 能被正常关闭。
type sizeCheckReader struct {
	r    io.Reader
	n    int64
	want int64
}

func (s *sizeCheckReader) Read(p []byte) (int, error) {
	n, err := s.r.Read(p)
	s.n += int64(n)
	if err == io.EOF && s.n != s.want {
		return n, fmt.Errorf("upload size mismatch: got %d bytes, declared %d", s.n, s.want)
	}
	return n, err
}

func (s *sizeCheckReader) Close() error {
	if c, ok := s.r.(io.Closer); ok {
		return c.Close()
	}
	return nil
}

func (im *ImgManager) Upload(content io.Reader, contentSize int64, name string, date time.Time, opts ...OptionFunc) error {
	var options Options
	for _, opt := range opts {
		opt(&options)
	}
	if err := validateDestDir(&options); err != nil {
		return err
	}
	path := im.genPath(name, date, options)
	if content == nil {
		return fmt.Errorf("content is nil")
	}
	// size 是建议值（见 StorageDrive.Upload）：SMB/NFS 驱动忽略它，实际
	// 长度由 sizeCheckReader 在流式读取时校验；但负数（HTTP chunked
	// 上传的 ContentLength==-1）在此处直接拒绝，HTTP 层同样返回 411。
	if contentSize < 0 {
		return fmt.Errorf("content size must not be negative: %d", contentSize)
	}
	reader, err := EncryptedReaderWraper(io.NopCloser(content), options.EncyptOption)
	if err != nil {
		im.logger.Println("Error encrypting:", err)
		return fmt.Errorf("error encrypting: %w", err)
	}
	if options.EncyptOption.Type != None && options.EncyptOption.Password != "" {
		contentSize = EncryptedContentSize(contentSize, options.EncyptOption.Type)
	}
	d, unlock := im.drive()
	defer unlock()
	e := d.Upload(path, &sizeCheckReader{r: reader, want: contentSize}, contentSize, date)
	if e != nil {
		im.logger.Println("Error uploading:", e)
		return fmt.Errorf("error uploading: %w", e)
	}
	return nil
}

func (im *ImgManager) UploadThumbnail(thumbnailContent io.Reader, thumbnailSize int64, name string, date time.Time, opts ...OptionFunc) error {
	var options Options
	for _, opt := range opts {
		opt(&options)
	}
	if err := validateDestDir(&options); err != nil {
		return err
	}
	if thumbnailContent == nil {
		return fmt.Errorf("thumbnail content is nil")
	}
	if thumbnailSize < 0 {
		return fmt.Errorf("thumbnail size must not be negative: %d", thumbnailSize)
	}
	path := im.genPath(name, date, options)
	reader, err := EncryptedReaderWraper(io.NopCloser(thumbnailContent), options.EncyptOption)
	if err != nil {
		im.logger.Println("Error encrypting video:", err)
		return fmt.Errorf("error encrypting video: %w", err)
	}
	if options.EncyptOption.Type != None && options.EncyptOption.Password != "" {
		thumbnailSize = EncryptedContentSize(thumbnailSize, options.EncyptOption.Type)
	}
	d, unlock := im.drive()
	defer unlock()
	e := d.Upload(filepath.Join(defaultThumbnailDir, path),
		&sizeCheckReader{r: reader, want: thumbnailSize}, thumbnailSize, date)
	if e != nil {
		im.logger.Printf("Error uploading %s: %s", path, e)
		return fmt.Errorf("error uploading %s thumbnail: %w", path, e)
	}
	return nil
}

func (im *ImgManager) UploadLiveVideo(content io.Reader, size int64, name string, date time.Time, opts ...OptionFunc) error {
	var options Options
	for _, opt := range opts {
		opt(&options)
	}
	if err := validateDestDir(&options); err != nil {
		return err
	}
	if content == nil {
		return fmt.Errorf("thumbnail content is nil")
	}
	if size < 0 {
		return fmt.Errorf("live video size must not be negative: %d", size)
	}
	path := im.genPath(name, date, options)
	reader, err := EncryptedReaderWraper(io.NopCloser(content), options.EncyptOption)
	if err != nil {
		im.logger.Println("Error encrypting video:", err)
		return fmt.Errorf("error encrypting video: %w", err)
	}
	if options.EncyptOption.Type != None && options.EncyptOption.Password != "" {
		size = EncryptedContentSize(size, options.EncyptOption.Type)
	}
	d, unlock := im.drive()
	defer unlock()
	e := d.Upload(path, &sizeCheckReader{r: reader, want: size}, size, date)
	if e != nil {
		im.logger.Printf("Error uploading %s: %s", path, e)
		return fmt.Errorf("error uploading %s thumbnail: %w", path, e)
	}
	return nil
}

func (im *ImgManager) GetImg(path string, opts ...OptionFunc) (*Image, error) {
	var options Options
	for _, opt := range opts {
		opt(&options)
	}
	img := &Image{}
	var err error
	var rc io.ReadCloser
	d, unlock := im.drive()
	defer unlock()
	rc, img.Size, err = d.Download(path)
	if err != nil {
		return img, err
	}
	encType := getPathEncType(path)
	if encType != None {
		detectedType, restoredRc, err := DetectEncryptFormat(rc)
		if err != nil {
			return img, err
		}
		options.EncyptOption.Type = detectedType
		img.Content, err = DecryptedReaderWraper(restoredRc, options.EncyptOption)
		if err != nil {
			return img, err
		}
		img.Size = DecryptedContentSize(img.Size, detectedType)
	} else {
		img.Content = rc
	}
	img.Path = path
	if filepath.Ext(path) == ".aes" {
		img.ContentType = util.ContentTypeByExtension(filepath.Ext(strings.TrimSuffix(path, ".aes")))
	} else {
		img.ContentType = util.ContentTypeByExtension(filepath.Ext(path))
	}
	return img, nil
}

func (im *ImgManager) GetOffset(path string, offset int64, opts ...OptionFunc) (*Image, error) {
	var options Options
	for _, opt := range opts {
		opt(&options)
	}
	if offset < 0 {
		return nil, fmt.Errorf("offset must not be negative: %d", offset)
	}
	if getPathEncType(path) != None {
		// 加密文件：先读 header 判断 GCM/CFB
		d, unlock := im.drive()
		rc, storedSize, err := d.Download(path)
		if err != nil {
			unlock()
			return nil, err
		}
		magic := make([]byte, gcmMagicLen)
		if _, err := io.ReadFull(rc, magic); err != nil {
			rc.Close()
			unlock()
			return nil, fmt.Errorf("failed to read magic bytes: %w", err)
		}
		if string(magic) == gcmMagic {
			// GCM 路径 — 支持任意 offset
			// 继续读剩余 header: salt(16B) + chunkSize(4B)
			headerRemain := make([]byte, gcmSaltLen+4)
			if _, err := io.ReadFull(rc, headerRemain); err != nil {
				rc.Close()
				unlock()
				return nil, fmt.Errorf("failed to read GCM header: %w", err)
			}
			salt := make([]byte, gcmSaltLen)
			copy(salt, headerRemain[:gcmSaltLen])
			chunkSize := binary.BigEndian.Uint32(headerRemain[gcmSaltLen:])
			// 损坏文件的 header 可能带 chunkSize==0（除零 panic）或超大值
			// （超大缓冲区分配）：在任何除法/分配之前校验并拒绝。
			if err := validateGCMChunkSize(chunkSize); err != nil {
				rc.Close()
				unlock()
				return nil, err
			}
			rc.Close() // 释放第一次 Download
			unlock()   // 释放 drive 锁

			chunkIndex := offset / int64(chunkSize)
			withinChunk := offset % int64(chunkSize)
			ciphertextStart := int64(gcmHeaderLen) + chunkIndex*(int64(chunkSize)+int64(gcmNonceSize)+int64(gcmTagSize))

			d2, unlock2 := im.drive()
			diskRc, diskSize, err := d2.DownloadWithOffset(path, ciphertextStart)
			if err != nil {
				unlock2()
				return nil, err
			}
			if diskSize != storedSize {
				diskRc.Close()
				unlock2()
				return nil, fmt.Errorf("stored size mismatch: first=%d second=%d", storedSize, diskSize)
			}

			seekRc, err := NewGcmSeekReader(diskRc, options.EncyptOption.Password, GcmSeekOpts{
				ChunkSize:         chunkSize,
				Salt:              salt,
				TotalStoredSize:   storedSize,
				StartChunkIndex:   chunkIndex,
				WithinChunkOffset: withinChunk,
			})
			if err != nil {
				diskRc.Close()
				unlock2()
				return nil, err
			}

			img := &Image{
				Content: seekRc,
				// 明文大小按 header 的 chunkSize 换算，而非写入器常量，
				// 否则外来分块大小的文件会在此算错 Content-Length。
				Size:        DecryptedContentSizeWithChunkSize(storedSize, AES_256_GCM, chunkSize),
				Path:        path,
				ContentType: util.ContentTypeByExtension(filepath.Ext(strings.TrimSuffix(path, ".aes"))),
			}
			// 注意：seekRc.Close() 负责关闭 diskRc，但 drive 锁需要在此释放
			unlock2()
			return img, nil
		}
		// CFB 旧路径：不支持 seek，仅 offset=0 走 GetImg 兜底
		rc.Close()
		unlock()
		if offset == 0 {
			return im.GetImg(path, opts...)
		}
		return nil, fmt.Errorf("encrypted file (CFB) not support get offset")
	}
	img := &Image{}
	var err error
	d, unlock := im.drive()
	defer unlock()
	img.Content, img.Size, err = d.DownloadWithOffset(path, offset)
	if err != nil {
		return img, err
	}
	img.Path = path
	if filepath.Ext(path) == ".aes" {
		img.ContentType = util.ContentTypeByExtension(filepath.Ext(strings.TrimSuffix(path, ".aes")))
	} else {
		img.ContentType = util.ContentTypeByExtension(filepath.Ext(path))
	}
	return img, nil
}

func (im *ImgManager) GetThumbnail(path string, opts ...OptionFunc) (*Image, error) {
	var options Options
	for _, opt := range opts {
		opt(&options)
	}
	img := &Image{}
	var err error
	var rc io.ReadCloser
	thumbnailPath := filepath.Join(defaultThumbnailDir, path)
	d, unlock := im.drive()
	defer unlock()
	rc, img.Size, err = d.Download(thumbnailPath)
	if err != nil {
		return img, fmt.Errorf("error downloading thumbnail: %w", err)
	}
	encType := getPathEncType(path)
	if encType != None {
		detectedType, restoredRc, err := DetectEncryptFormat(rc)
		if err != nil {
			return img, fmt.Errorf("error detecting encrypt format: %w", err)
		}
		options.EncyptOption.Type = detectedType
		img.Content, err = DecryptedReaderWraper(restoredRc, options.EncyptOption)
		if err != nil {
			return img, fmt.Errorf("error decrypting thumbnail: %w", err)
		}
		img.Size = DecryptedContentSize(img.Size, detectedType)
	} else {
		img.Content = rc
	}
	img.Path = thumbnailPath
	if filepath.Ext(path) == ".aes" {
		img.ContentType = util.ContentTypeByExtension(filepath.Ext(strings.TrimSuffix(path, ".aes")))
	} else {
		img.ContentType = util.ContentTypeByExtension(filepath.Ext(thumbnailPath))
	}
	return img, nil
}

// baseNameWithoutExt 返回文件名去掉 .aes 后缀与扩展名后的主名，
// 如 "IMG_0001.mp4.aes" -> "IMG_0001"、"IMG_0001.jpg" -> "IMG_0001"。
// 加密 Live Video 存为 .mp4.aes：不先剥 .aes，扩展名比较与主名比较
// 都会错过它，导致 /live/ 路由永远报 video not found。
func baseNameWithoutExt(name string) string {
	base := filepath.Base(util.StripAesSuffix(name))
	return base[:len(base)-len(filepath.Ext(base))]
}

func (im *ImgManager) GetLiveVideoOffset(path string, offset int64, opts ...OptionFunc) (*Image, error) {
	var options Options
	for _, opt := range opts {
		opt(&options)
	}
	if offset < 0 {
		return nil, fmt.Errorf("offset must not be negative: %d", offset)
	}
	var videoPath string
	dir := filepath.Dir(path)
	func() {
		d, unlock := im.drive()
		defer unlock()
		d.Range(dir, func(info fs.FileInfo) bool {
			name := info.Name()
			// IsVideo 已剥离 .aes 再判扩展名；主名比较同样先剥 .aes，
			// 否则 "IMG.mp4.aes" 与照片 "IMG.jpg" 的主名永远不等。
			if util.IsVideo(name) && baseNameWithoutExt(name) == baseNameWithoutExt(path) {
				videoPath = filepath.Join(dir, name)
				return false
			}
			return true
		})
	}()
	if videoPath == "" {
		return nil, fmt.Errorf("video not found")
	}
	if getPathEncType(videoPath) != None {
		// 加密视频：先读 header 判断 GCM/CFB
		d, unlock := im.drive()
		rc, storedSize, err := d.Download(videoPath)
		if err != nil {
			unlock()
			return nil, err
		}
		magic := make([]byte, gcmMagicLen)
		if _, err := io.ReadFull(rc, magic); err != nil {
			rc.Close()
			unlock()
			return nil, fmt.Errorf("failed to read magic bytes: %w", err)
		}
		if string(magic) == gcmMagic {
			// GCM 路径 — 支持任意 offset
			headerRemain := make([]byte, gcmSaltLen+4)
			if _, err := io.ReadFull(rc, headerRemain); err != nil {
				rc.Close()
				unlock()
				return nil, fmt.Errorf("failed to read GCM header: %w", err)
			}
			salt := make([]byte, gcmSaltLen)
			copy(salt, headerRemain[:gcmSaltLen])
			chunkSize := binary.BigEndian.Uint32(headerRemain[gcmSaltLen:])
			if err := validateGCMChunkSize(chunkSize); err != nil {
				rc.Close()
				unlock()
				return nil, err
			}
			rc.Close()
			unlock()

			chunkIndex := offset / int64(chunkSize)
			withinChunk := offset % int64(chunkSize)
			ciphertextStart := int64(gcmHeaderLen) + chunkIndex*(int64(chunkSize)+int64(gcmNonceSize)+int64(gcmTagSize))

			d2, unlock2 := im.drive()
			diskRc, diskSize, err := d2.DownloadWithOffset(videoPath, ciphertextStart)
			if err != nil {
				unlock2()
				return nil, err
			}
			if diskSize != storedSize {
				diskRc.Close()
				unlock2()
				return nil, fmt.Errorf("stored size mismatch: first=%d second=%d", storedSize, diskSize)
			}

			seekRc, err := NewGcmSeekReader(diskRc, options.EncyptOption.Password, GcmSeekOpts{
				ChunkSize:         chunkSize,
				Salt:              salt,
				TotalStoredSize:   storedSize,
				StartChunkIndex:   chunkIndex,
				WithinChunkOffset: withinChunk,
			})
			if err != nil {
				diskRc.Close()
				unlock2()
				return nil, err
			}

			img := &Image{
				Content:     seekRc,
				Size:        DecryptedContentSizeWithChunkSize(storedSize, AES_256_GCM, chunkSize),
				Path:        videoPath,
				ContentType: util.ContentTypeByExtension(filepath.Ext(strings.TrimSuffix(videoPath, ".aes"))),
			}
			unlock2()
			return img, nil
		}
		// CFB 旧路径：不支持 seek，仅 offset=0 走 GetImg 兜底
		rc.Close()
		unlock()
		if offset == 0 {
			return im.GetImg(videoPath, opts...)
		}
		return nil, fmt.Errorf("encrypted file (CFB) not support get offset")
	}
	// log.Printf("load video: %s", videoPath)
	img := &Image{}
	var err error
	d, unlock := im.drive()
	defer unlock()
	img.Content, img.Size, err = d.DownloadWithOffset(videoPath, offset)
	if err != nil {
		return img, err
	}
	img.Path = videoPath
	if filepath.Ext(videoPath) == ".aes" {
		img.ContentType = util.ContentTypeByExtension(filepath.Ext(strings.TrimSuffix(videoPath, ".aes")))
	} else {
		img.ContentType = util.ContentTypeByExtension(filepath.Ext(videoPath))
	}
	// log.Printf("Live video path: %s", videoPath)
	// log.Printf("Content-Type: %s", img.ContentType)
	return img, nil
}

func (im *ImgManager) DeleteSingleImg(path string) error {
	if path != "" {
		d, unlock := im.drive()
		defer unlock()
		err := d.Delete(filepath.Join(defaultThumbnailDir, path))
		if err != nil {
			im.logger.Println("Error deleting thumbnail:", err)
		}
		parentDir := filepath.Base(filepath.Dir(filepath.ToSlash(path)))
		if strings.HasPrefix(parentDir, "live_") {
			d.Range(filepath.Dir(path), func(info fs.FileInfo) bool {
				err := d.Delete(filepath.Join(filepath.Dir(path), info.Name()))
				if err != nil {
					im.logger.Println("Error deleting live video:", err)
				}
				return true
			})
			err := d.Delete(filepath.Dir(path))
			if err != nil {
				im.logger.Println("Error deleting live video dir:", err)
			}
		}
		return d.Delete(path)
	}
	return nil
}

// DeleteSingleImgAsync 把删除入队，由 worker 池异步执行。
// 这是 worker 池唯一的入队入口（池内不处理上传——上传全部同步执行）。
// Close() 后调用不会阻塞：stopCh 已关闭时直接丢弃该删除请求。
func (im *ImgManager) DeleteSingleImgAsync(path string) {
	if path != "" {
		select {
		case im.actCh <- action{t: actDelete, path: path}:
		case <-im.stopCh:
		}
	}
}

// DeleteImg 同步删除 paths 中的每一项，返回与 paths 等长的逐项错误
// 切片（成功项为 nil，空路径也为 nil）。调用方必须检查返回值：
// 此前本函数丢弃全部后端错误，导致 API 层永远报告删除成功。
// DeleteSingleImg 内部仍只记录缩略图/live 附属文件的删除失败日志，
// 返回的是主文件的删除结果。
func (im *ImgManager) DeleteImg(paths []string) []error {
	errs := make([]error, len(paths))
	for i, path := range paths {
		if path != "" {
			errs[i] = im.DeleteSingleImg(path)
		}
	}
	return errs
}

type dirInfo struct {
	date time.Time
	dir  string
}

type ImgInfo struct {
	Path        string
	Size        int64
	IsLivePhoto bool
}

func (im *ImgManager) RangeByDate(date time.Time, f func(info ImgInfo) bool) error {
	d, unlock := im.drive()
	defer unlock()
	t := date
	if t.IsZero() {
		t = time.Now()
	}
	year, month, day := t.Date()
	dirInfos := make([]dirInfo, 0)
	yDir, err := im.listDir(d, ".")
	if err != nil {
		im.logger.Println("Error listing year dir:", err)
		return err
	}
	// sort.Sort(desc(yDir))
	// type 02
	for _, yinfo := range yDir {
		// 目录项必须是目录：一个恰好 8 字符的文件名（如备份文件）
		// 不得被当作日期目录解析进结果。
		if !yinfo.IsDir() {
			continue
		}
		if len(yinfo.Name()) == 8 {
			// 日期目录名按本地时区解析：time.Parse 返回 UTC 午夜，
			// 在东时区会比本地午夜晚数小时，导致请求当日的目录被
			// dirDate.After(t) 误判为未来而排除（type-01 分支用
			// time.Local 构造 dirDate，两边必须一致）。
			dirDate, err := time.ParseInLocation("20060102", yinfo.Name(), time.Local)
			if err != nil {
				im.logger.Printf("Error parsing date: %s, %s", yinfo.Name(), err)
				continue
			}
			// 与 t（零值已归一为 Now）比较，而非原始 date：
			// 零值 date 时 After(zero) 恒真，此前导致零日期查询永远无匹配。
			if !dirDate.After(t) {
				dirInfos = append(dirInfos, dirInfo{
					date: dirDate,
					dir:  yinfo.Name(),
				})
			}
		}
	}
	// type 01
	for _, yinfo := range yDir {
		if yinfo.Name() == "live" {
			continue
		}
		if !yinfo.IsDir() {
			continue
		}
		if len(yinfo.Name()) != 4 {
			continue
		}
		yNum, err := strconv.Atoi(yinfo.Name())
		if err != nil {
			continue
		}
		if yNum > year {
			continue
		}
		mDir, err := im.listDir(d, filepath.Base(yinfo.Name()))
		if err != nil {
			im.logger.Println("Error listing month dir:", err)
			continue
		}
		// sort.Sort(desc(mDir))
		for _, minfo := range mDir {
			if minfo.Name() == "live" {
				continue
			}
			if !minfo.IsDir() {
				continue
			}
			mNum, err := strconv.Atoi(minfo.Name())
			if err != nil {
				continue
			}
			if yNum == year && mNum > int(month) {
				continue
			}
			dDir, err := im.listDir(d, filepath.Join(yinfo.Name(), minfo.Name()))
			if err != nil {
				im.logger.Println("Error listing day dir:", err)
				continue
			}
			// sort.Sort(desc(dDir))
			for _, dinfo := range dDir {
				if !dinfo.IsDir() {
					continue
				}
				dNum, err := strconv.Atoi(dinfo.Name())
				if err != nil {
					continue
				}
				if yNum == year && mNum == int(month) && dNum > day {
					continue
				}
				dirPath := filepath.Join(yinfo.Name(), minfo.Name(), dinfo.Name())
				dirDate := time.Date(yNum, time.Month(mNum), dNum, 0, 0, 0, 0, time.Local)
				if !dirDate.After(t) {
					dirInfos = append(dirInfos, dirInfo{
						date: dirDate,
						dir:  dirPath,
					})
				}
			}
		}
	}

	sort.Sort(dirDesc(dirInfos))
	stoppedEarly := false
	for _, dirInfo := range dirInfos {
		goOn := true
		var walkErr error
		err := d.Range(dirInfo.dir, func(info fs.FileInfo) bool {
			if info.IsDir() {
				if strings.HasPrefix(info.Name(), "live_") {
					// 内层 Range 的错误必须向上传播（此前被丢弃），且
					// 回调返回 false（提前停止）时内层遍历也要停——
					// 此前内层恒返回 true，提前停止信号传不到 live_ 子目录。
					if rerr := d.Range(filepath.Join(dirInfo.dir, info.Name()), func(info2 fs.FileInfo) bool {
						if !util.IsVideo(info2.Name()) {
							goOn = f(ImgInfo{
								Path:        filepath.Join(dirInfo.dir, info.Name(), info2.Name()),
								Size:        info2.Size(),
								IsLivePhoto: true,
							})
						}
						return goOn
					}); rerr != nil {
						walkErr = rerr
						goOn = false
					}
				}
				return goOn
			}
			goOn = f(ImgInfo{
				Path:        filepath.Join(dirInfo.dir, info.Name()),
				Size:        info.Size(),
				IsLivePhoto: false,
			})
			return goOn
		})
		if err != nil {
			return err
		}
		if walkErr != nil {
			return walkErr
		}
		if !goOn {
			stoppedEarly = true
			break
		}
	}
	if stoppedEarly {
		return nil
	}
	// 相册目录阶段：手动上传的文件按类型分目录存放在驱动根目录下
	// 的一级子目录（如 manual/video/、manual/image/）中，路径中
	// 没有日期，日期目录遍历永远看不到它们；若不纳入枚举，
	// FilterNotUploaded 会误判它们未上传，自动同步会重传一份到
	// 日期目录。相册文件按编码文件名匹配，与日期截止无关，因此
	// 不论传入的 date 一律纳入（排在日期目录之后，不改变已有
	// 列表顺序）。遍历覆盖任意一级相册目录（不只当前配置的手动
	// 目录），改手动目录设置后旧目录下的文件仍被发现，不重传。
	return im.rangeAlbumDirs(d, f)
}

// isAlbumDirName 报告根目录项是否为相册目录候选：目录、不是
// `live` / `.thumbnail`、不是日期目录形状（日期目录已由日期
// 遍历处理，相册遍历跳过以免重复访问同一目录两次）。
func isAlbumDirName(info fs.FileInfo) bool {
	if !info.IsDir() {
		return false
	}
	name := info.Name()
	if name == "live" || name == ".thumbnail" {
		return false
	}
	if len(name) == 8 {
		if _, err := time.Parse("20060102", name); err == nil {
			return false
		}
	}
	if len(name) == 4 {
		if _, err := strconv.Atoi(name); err == nil {
			return false
		}
	}
	return true
}

// rangeAlbumDirs 枚举全部一级相册目录下的文件。相册根按名字排序
// 后遍历，保证顺序确定。回调返回 false（提前停止）或 Range 出错
// 时立即停止并向上传播，与日期目录阶段的语义一致。
func (im *ImgManager) rangeAlbumDirs(d StorageDrive, f func(info ImgInfo) bool) error {
	rootEntries, err := im.listDir(d, ".")
	if err != nil {
		im.logger.Println("Error listing album dirs:", err)
		return err
	}
	albums := make([]string, 0)
	for _, info := range rootEntries {
		if isAlbumDirName(info) {
			albums = append(albums, info.Name())
		}
	}
	sort.Strings(albums)
	for _, album := range albums {
		goOn, err := im.walkAlbumDir(d, album, 0, f)
		if err != nil {
			return err
		}
		if !goOn {
			return nil
		}
	}
	return nil
}

// albumWalkMaxDepth 是相册遍历相对相册根的最大递归深度：覆盖
// 多段手动目录（如 a/b）+ 类型目录（video/image）+ live_ 子目录，
// 同时给任意嵌套的非日期树一个上界，避免无界递归。
const albumWalkMaxDepth = 4

// walkAlbumDir 递归枚举一个相册目录内的文件：直接文件上报
// IsLivePhoto=false；live_ 子目录内的非视频文件按 IsLivePhoto=true
// 上报（与日期目录阶段的 live_ 语义完全一致），伴生视频不单独
// 上报（由 GetLiveVideoOffset 按照片所在目录查找）；`.thumbnail`
// 子目录在任何一层都跳过，避免缩略图被当成照片。返回是否应
// 继续遍历（回调返回 false 即停止）。
func (im *ImgManager) walkAlbumDir(d StorageDrive, dir string, depth int, f func(info ImgInfo) bool) (bool, error) {
	goOn := true
	var walkErr error
	err := d.Range(dir, func(info fs.FileInfo) bool {
		if !goOn {
			return false
		}
		if info.IsDir() {
			name := info.Name()
			if name == ".thumbnail" {
				return true
			}
			if strings.HasPrefix(name, "live_") {
				if rerr := d.Range(filepath.Join(dir, name), func(info2 fs.FileInfo) bool {
					if info2.IsDir() {
						return goOn
					}
					if !util.IsVideo(info2.Name()) {
						goOn = f(ImgInfo{
							Path:        filepath.Join(dir, name, info2.Name()),
							Size:        info2.Size(),
							IsLivePhoto: true,
						})
					}
					return goOn
				}); rerr != nil {
					walkErr = rerr
					goOn = false
				}
				return goOn
			}
			if depth < albumWalkMaxDepth {
				cont, rerr := im.walkAlbumDir(d, filepath.Join(dir, name), depth+1, f)
				if rerr != nil {
					walkErr = rerr
					goOn = false
				} else {
					goOn = cont
				}
			}
			return goOn
		}
		goOn = f(ImgInfo{
			Path:        filepath.Join(dir, info.Name()),
			Size:        info.Size(),
			IsLivePhoto: false,
		})
		return goOn
	})
	if err != nil {
		return false, err
	}
	if walkErr != nil {
		return false, walkErr
	}
	return goOn, nil
}

func (im *ImgManager) listDir(d StorageDrive, path string) ([]fs.FileInfo, error) {
	infos := make([]fs.FileInfo, 0)
	err := d.Range(path, func(info fs.FileInfo) bool {
		infos = append(infos, info)
		return true
	})
	return infos, err
}

// type asc []fs.FileInfo

// func (a asc) Len() int      { return len(a) }
// func (a asc) Swap(i, j int) { a[i], a[j] = a[j], a[i] }
// func (a asc) Less(i, j int) bool {
// 	yi, err := strconv.Atoi(a[i].Name())
// 	if err != nil {
// 		return false
// 	}
// 	yj, err := strconv.Atoi(a[j].Name())
// 	if err != nil {
// 		return true
// 	}
// 	return yi < yj
// }

type desc []fs.FileInfo

func (d desc) Len() int      { return len(d) }
func (d desc) Swap(i, j int) { d[i], d[j] = d[j], d[i] }
func (d desc) Less(i, j int) bool {
	yi, err := strconv.Atoi(d[i].Name())
	if err != nil {
		return false
	}
	yj, err := strconv.Atoi(d[j].Name())
	if err != nil {
		return true
	}
	return yi > yj
}

type dirDesc []dirInfo

func (d dirDesc) Len() int      { return len(d) }
func (d dirDesc) Swap(i, j int) { d[i], d[j] = d[j], d[i] }
func (d dirDesc) Less(i, j int) bool {
	return d[i].date.After(d[j].date)
}
