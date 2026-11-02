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

func (im *ImgManager) genPath(name string, date time.Time, options Options) string {
	date = EffectiveFileDate(date)
	im.dirTypeMu.RLock()
	dirType := im.dirType
	im.dirTypeMu.RUnlock()
	elems := []string{}
	switch dirType {
	case pb.DirectoryType_DIRECTORY_TYPE_01:
		elems = append(elems, date.Format("2006/01/02"))
	case pb.DirectoryType_DIRECTORY_TYPE_02:
		elems = append(elems, date.Format("20060102/"))
	default:
		elems = append(elems, date.Format("2006/01/02"))
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
			dirDate, err := time.Parse("20060102", yinfo.Name())
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
			break
		}
	}
	return nil
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
