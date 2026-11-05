package webdav

import (
	"crypto/tls"
	"fmt"
	"io"
	"io/fs"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"

	"bytes"

	"github.com/fregie/img_syncer/server/util"
	"github.com/studio-b12/gowebdav"
)

type Webdav struct {
	url      string
	username string
	password string

	// mu 保护 rootPath 的读写。cli 在构造后不再更换（无状态 HTTP，
	// 无重连交换），构造完成后可并发安全读取，无需句柄锁。
	mu       sync.RWMutex
	rootPath string
	cli      *gowebdav.Client

	mkdirLock sync.Mutex // serializes mkdir to avoid race in gowebdav lib
}

func (d *Webdav) getRootPath() string {
	d.mu.RLock()
	defer d.mu.RUnlock()
	return d.rootPath
}

func (d *Webdav) setRootPath(path string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.rootPath = path
}

func NewWebdavDrive(url, username, password string, insecure bool) *Webdav {
	d := &Webdav{
		url:      url,
		username: username,
		password: password,
		cli:      gowebdav.NewClient(url, username, password),
	}
	d.cli.SetTransport(&http.Transport{
		TLSClientConfig: &tls.Config{InsecureSkipVerify: insecure},
	})
	if insecure {
		log.Printf("WARNING: TLS certificate verification disabled for WebDAV at %s, do not use in production", url)
	}
	d.cli.SetTimeout(60 * time.Second)
	return d
}

// Close 是 no-op：WebDAV 是无状态 HTTP，没有需要关闭的持久连接。
func (d *Webdav) Close() error {
	return nil
}

func (d *Webdav) Cli() *gowebdav.Client {
	return d.cli
}

func (d *Webdav) IsRootPathSet() bool {
	return d.getRootPath() != ""
}

func (d *Webdav) SetRootPath(rootPath string) error {
	if rootPath == "" {
		return fmt.Errorf("root path is empty")
	}
	// 先校验路径语法：含 ".." 的根路径直接拒绝，不发请求。
	if _, err := util.CleanDirPath(rootPath); err != nil {
		return err
	}
	rootPath = filepath.ToSlash(rootPath)
	var err error
	if rootPath[0] != '/' {
		rootPath = "/" + rootPath
	}
	if rootPath[len(rootPath)-1] != '/' {
		rootPath = rootPath + "/"
	}
	info, err := d.cli.Stat(rootPath)
	if err != nil {
		if os.IsNotExist(err) {
			return fmt.Errorf("root path %s not exist", rootPath)
		}
		return err
	}
	if !info.IsDir() {
		return fmt.Errorf("root path %s is not a dir", rootPath)
	}
	d.setRootPath(rootPath)
	return nil
}

func (d *Webdav) IsExist(path string) (bool, error) {
	rootPath := d.getRootPath()
	if rootPath == "" {
		return false, fmt.Errorf("root path is empty")
	}
	fullPath := filepath.Join(rootPath, path)
	fullPath = filepath.ToSlash(fullPath)
	_, err := d.cli.Stat(fullPath)
	if err != nil {
		if os.IsNotExist(err) {
			return false, nil
		}
		if pathErr, ok := err.(*os.PathError); ok {
			if statusErr, ok := pathErr.Err.(gowebdav.StatusError); ok && statusErr.Status == 404 {
				return false, nil
			}
		}
		return false, err
	}
	return true, nil
}

func (d *Webdav) Download(path string) (io.ReadCloser, int64, error) {
	rootPath := d.getRootPath()
	if rootPath == "" {
		return nil, 0, fmt.Errorf("root path is empty")
	}
	fullPath := filepath.Join(rootPath, path)
	fullPath = filepath.ToSlash(fullPath)
	reader, size, err := d.cli.ReadStreamSized(fullPath)
	if err != nil {
		return nil, 0, err
	}
	if size >= 0 {
		return reader, size, nil
	}
	// extra Stat call when server omits Content-Length — gowebdav library limitation
	info, err := d.cli.Stat(fullPath)
	if err != nil {
		reader.Close()
		return nil, 0, err
	}
	return reader, info.Size(), nil
}

func (d *Webdav) Delete(path string) error {
	rootPath := d.getRootPath()
	if rootPath == "" {
		return fmt.Errorf("root path is empty")
	}
	fullPath := filepath.Join(rootPath, path)
	fullPath = filepath.ToSlash(fullPath)
	err := d.cli.Remove(fullPath)
	if err != nil {
		return err
	}
	return nil
}

// DownloadWithOffset 的偏移量约定（与 SMB/NFS 统一）：offset > size
// 报错；offset == size 返回空流与总大小（HTTP 层再按 416 处理）。
// 快捷路径不预 Stat（Content-Range 自带总量，见
// TestDownloadWithOffsetReturnsTotalSizeWithoutStat）；服务器对越界
// Range 返回错误时才 Stat 一次区分 offset==size 与 offset>size。
func (d *Webdav) DownloadWithOffset(path string, offset int64) (io.ReadCloser, int64, error) {
	rootPath := d.getRootPath()
	if rootPath == "" {
		return nil, 0, fmt.Errorf("root path is empty")
	}
	if offset < 0 {
		return nil, 0, fmt.Errorf("offset must not be negative: %d", offset)
	}
	fullPath := filepath.Join(rootPath, path)
	fullPath = filepath.ToSlash(fullPath)
	reader, size, err := d.cli.ReadStreamRangeSized(fullPath, offset, -1)
	if err != nil {
		if offset == 0 {
			return nil, 0, err
		}
		// 越界时服务器已拒绝：Stat 区分“恰好在末尾”与“超出末尾”。
		info, serr := d.cli.Stat(fullPath)
		if serr != nil {
			return nil, 0, err
		}
		if offset > info.Size() {
			return nil, info.Size(), fmt.Errorf("offset %d is bigger than file size %d", offset, info.Size())
		}
		if offset == info.Size() {
			return io.NopCloser(bytes.NewReader(nil)), info.Size(), nil
		}
		return nil, 0, err
	}
	if size >= 0 {
		return reader, size, nil
	}
	info, err := d.cli.Stat(fullPath)
	if err != nil {
		reader.Close()
		return nil, 0, err
	}
	if offset > info.Size() {
		reader.Close()
		return nil, info.Size(), fmt.Errorf("offset %d is bigger than file size %d", offset, info.Size())
	}
	if offset == info.Size() {
		reader.Close()
		return io.NopCloser(bytes.NewReader(nil)), info.Size(), nil
	}
	return reader, info.Size(), nil
}

func (d *Webdav) Upload(path string, reader io.ReadCloser, size int64, lastModified time.Time) error {
	if reader == nil {
		return fmt.Errorf("reader is nil")
	}
	defer reader.Close()
	rootPath := d.getRootPath()
	if rootPath == "" {
		return fmt.Errorf("root path is empty")
	}
	fullPath := filepath.Join(rootPath, path)
	fullPath = filepath.ToSlash(fullPath)
	d.mkdirLock.Lock()
	err := d.cli.MkdirAll(filepath.Dir(fullPath), 0755)
	d.mkdirLock.Unlock()
	if err != nil {
		return err
	}
	err = d.cli.WriteStream(fullPath, reader, size, 0666)
	if err != nil {
		// 写失败时删除残缺文件：与 SMB/NFS 驱动一致，否则截断文件
		// 会被 FilterNotUploaded 按名匹配为已上传（尽力删除，失败仅记日志）。
		if rmErr := d.cli.Remove(fullPath); rmErr != nil {
			log.Printf("remove partial file failed (non-fatal): %v", rmErr)
		}
		return err
	}

	return nil
}

func (d *Webdav) Range(dir string, deal func(fs.FileInfo) bool) error {
	rootPath := d.getRootPath()
	if rootPath == "" {
		return fmt.Errorf("root path is empty")
	}
	fullPath := filepath.Join(rootPath, dir)
	fullPath = filepath.ToSlash(fullPath)
	infos, err := d.cli.ReadDir(fullPath)
	if err != nil {
		return err
	}
	sort.Sort(desc(infos))
	for _, info := range infos {
		if !deal(info) {
			break
		}
	}
	return nil
}

// MkdirAll 实现 StorageDrive.MkdirAll：dir 相对于驱动根目录，
// 已存在时成功。用与 Upload 建父目录同一原语（cli.MkdirAll），
// 同样经 mkdirLock 串行化（gowebdav 库的 mkdir 竞态防护）。
func (d *Webdav) MkdirAll(dir string) error {
	rootPath := d.getRootPath()
	if rootPath == "" {
		return fmt.Errorf("root path is empty")
	}
	fullPath := filepath.ToSlash(filepath.Join(rootPath, dir))
	d.mkdirLock.Lock()
	err := d.cli.MkdirAll(fullPath, 0755)
	d.mkdirLock.Unlock()
	return err
}

type desc []fs.FileInfo

func (d desc) Len() int      { return len(d) }
func (d desc) Swap(i, j int) { d[i], d[j] = d[j], d[i] }
func (d desc) Less(i, j int) bool {
	return d[i].ModTime().After(d[j].ModTime())
}
