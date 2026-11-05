package nfs

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/fregie/img_syncer/server/util"
	"github.com/vmware/go-nfs-client/nfs"
	"github.com/vmware/go-nfs-client/nfs/rpc"
)

// nfsConnRefWaitTimeout 是重连/关闭时等待在途 I/O 用完旧连接的最长等待。
const nfsConnRefWaitTimeout = 2 * time.Second

type Nfs struct {
	host   string
	target string

	// cfgMu 保护 rootPath 的读写。
	cfgMu    sync.RWMutex
	rootPath string

	// connMu 保护 cli/mount 对的交换；connRefs 是持有连接快照的在途操作计数。
	// 任何方法都不得直接读写 d.cli/d.mount，必须经 acquireConn 拿到快照——
	// 重连与 Close 会先换出旧连接、等引用排空再关闭，避免在途 I/O
	// 拿到已关闭的连接句柄。
	connMu            sync.RWMutex
	mount             *nfs.Mount
	cli               *nfs.Target
	connRefs          int32
	lastConnTimestamp int64
	reconnMu          sync.Mutex // 保护重连过程的序列化
}

// nfsConn 是 cli/mount 对的快照，成对使用、成对关闭。
type nfsConn struct {
	mount *nfs.Mount
	cli   *nfs.Target
}

func (d *Nfs) getRootPath() string {
	d.cfgMu.RLock()
	defer d.cfgMu.RUnlock()
	return d.rootPath
}

func (d *Nfs) setRootPath(path string) {
	d.cfgMu.Lock()
	defer d.cfgMu.Unlock()
	d.rootPath = path
}

// acquireConn 返回当前连接快照并计入在途引用；调用方必须调用 releaseConn。
// 连接尚未建立时返回 nil 快照且不计数。
func (d *Nfs) acquireConn() nfsConn {
	d.connMu.RLock()
	defer d.connMu.RUnlock()
	if d.cli == nil {
		return nfsConn{}
	}
	atomic.AddInt32(&d.connRefs, 1)
	return nfsConn{mount: d.mount, cli: d.cli}
}

func (d *Nfs) releaseConn() {
	atomic.AddInt32(&d.connRefs, -1)
}

// swapConn 替换当前连接对并返回旧对。
func (d *Nfs) swapConn(c nfsConn) nfsConn {
	d.connMu.Lock()
	defer d.connMu.Unlock()
	old := nfsConn{mount: d.mount, cli: d.cli}
	d.mount, d.cli = c.mount, c.cli
	return old
}

func (d *Nfs) waitConnRefs(timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	for atomic.LoadInt32(&d.connRefs) > 0 {
		if time.Now().After(deadline) {
			return false
		}
		time.Sleep(10 * time.Millisecond)
	}
	return true
}

func (c nfsConn) close() {
	if c.cli != nil {
		c.cli.Close()
	}
	if c.mount != nil {
		c.mount.Close()
	}
}

func NewNfsDrive(url string) (*Nfs, error) {
	re := strings.Split(url, ":")
	if len(re) != 2 {
		return nil, fmt.Errorf("url format error")
	}
	d := &Nfs{
		host:   re[0],
		target: re[1],
	}
	mount, err := nfs.DialMount(d.host)
	if err != nil {
		return nil, err
	}
	mount.SetTimeout(60 * time.Second)
	auth := rpc.NewAuthUnix("root", 0, 0)
	target, err := mount.Mount(d.target, auth.Auth())
	if err != nil {
		return nil, err
	}
	target.SetTimeout(60 * time.Second)
	d.mount = mount
	d.cli = target
	return d, nil
}

func (d *Nfs) Close() error {
	old := d.swapConn(nfsConn{})
	d.waitConnRefs(nfsConnRefWaitTimeout)
	old.close()
	return nil
}

func (d *Nfs) Cli() *nfs.Target {
	d.connMu.RLock()
	defer d.connMu.RUnlock()
	return d.cli
}

func (d *Nfs) lastConnTime() time.Time {
	ts := atomic.LoadInt64(&d.lastConnTimestamp)
	return time.Unix(ts, 0)
}

func (d *Nfs) updateLastConnTime() {
	atomic.StoreInt64(&d.lastConnTimestamp, time.Now().Unix())
}

func (d *Nfs) cleanLastConnTime() {
	atomic.StoreInt64(&d.lastConnTimestamp, 0)
}

func (d *Nfs) checkConn() error {
	// 快速 TTL 检查（无需加锁）
	if time.Since(d.lastConnTime()) < 90*time.Second {
		return nil
	}
	// FSInfo 健康探测（锁外执行，成功则刷新 TTL）
	if conn := d.acquireConn(); conn.cli != nil {
		_, err := conn.cli.FSInfo()
		d.releaseConn()
		if err == nil {
			d.updateLastConnTime()
			return nil
		}
	}
	// 需要重连，序列化执行
	d.reconnMu.Lock()
	defer d.reconnMu.Unlock()
	// 双重检查：可能其他 goroutine 已重连
	if time.Since(d.lastConnTime()) < 90*time.Second {
		return nil
	}
	old := d.swapConn(nfsConn{})
	d.waitConnRefs(nfsConnRefWaitTimeout)
	old.close()
	mount, err := nfs.DialMount(d.host)
	if err != nil {
		return err
	}
	mount.SetTimeout(60 * time.Second)
	auth := rpc.NewAuthUnix("root", 0, 0)
	target, err := mount.Mount(d.target, auth.Auth())
	if err != nil {
		mount.Close()
		return err
	}
	target.SetTimeout(60 * time.Second)
	d.swapConn(nfsConn{mount: mount, cli: target})
	d.updateLastConnTime()
	return nil
}

func (d *Nfs) IsRootPathSet() bool {
	return d.getRootPath() != ""
}

// normalizeRootPath returns a normalized path with leading and trailing slashes.
// Pure string function — no I/O.
func normalizeRootPath(path string) string {
	if path == "" {
		return "/"
	}
	path = filepath.ToSlash(path)
	if path[0] != '/' {
		path = "/" + path
	}
	if path[len(path)-1] != '/' {
		path = path + "/"
	}
	return path
}

func (d *Nfs) SetRootPath(rootPath string) error {
	if rootPath == "" {
		return fmt.Errorf("root path is empty")
	}
	// 先校验路径语法：含 ".." 的根路径直接拒绝，不触网、不 panic。
	if _, err := util.CleanDirPath(rootPath); err != nil {
		return err
	}
	// 未建立连接（cli 为 nil）时先重连：此前直接调用 ReadDirPlus 会 panic。
	if err := d.checkConn(); err != nil {
		return err
	}
	conn := d.acquireConn()
	if conn.cli == nil {
		return fmt.Errorf("nfs client is not connected")
	}
	defer d.releaseConn()
	rootPath = normalizeRootPath(rootPath)
	_, err := conn.cli.ReadDirPlus(rootPath)
	if err != nil {
		return err
	}
	d.setRootPath(rootPath)
	return nil
}

// connReadCloser 把连接引用持有到流关闭为止，避免重连/关闭在读取
// 中途关闭正在读的 NFS 连接。
type connReadCloser struct {
	rc      io.ReadCloser
	release func()
	once    sync.Once
}

func (c *connReadCloser) Read(p []byte) (int, error) { return c.rc.Read(p) }

func (c *connReadCloser) Close() error {
	err := c.rc.Close()
	c.once.Do(c.release)
	return err
}

func (d *Nfs) IsExist(path string) (bool, error) {
	if err := d.checkConn(); err != nil {
		return false, err
	}
	rootPath := d.getRootPath()
	if rootPath == "" {
		return false, fmt.Errorf("root path is empty")
	}
	conn := d.acquireConn()
	if conn.cli == nil {
		return false, fmt.Errorf("nfs client is not connected")
	}
	defer d.releaseConn()
	fullPath := filepath.Join(rootPath, path)
	_, _, err := conn.cli.Lookup(fullPath)
	if err != nil {
		if err, ok := err.(*nfs.Error); ok {
			if err.ErrorNum == nfs.NFS3ErrIsDir {
				d.updateLastConnTime()
				return true, nil
			}
		}
		if errors.Is(err, os.ErrNotExist) {
			d.updateLastConnTime()
			return false, nil
		}
		d.cleanLastConnTime()
		return false, err
	}
	d.updateLastConnTime()
	return true, nil
}

func (d *Nfs) Download(path string) (io.ReadCloser, int64, error) {
	if err := d.checkConn(); err != nil {
		return nil, 0, err
	}
	rootPath := d.getRootPath()
	if rootPath == "" {
		return nil, 0, fmt.Errorf("root path is empty")
	}
	conn := d.acquireConn()
	if conn.cli == nil {
		return nil, 0, fmt.Errorf("nfs client is not connected")
	}
	fullPath := filepath.Join(rootPath, path)
	file, err := conn.cli.Open(fullPath)
	if err != nil {
		d.releaseConn()
		d.cleanLastConnTime()
		return nil, 0, fmt.Errorf("open file error: %v", err)
	}
	length := file.FileSize()
	if length < 0 {
		info, _, err := conn.cli.Lookup(fullPath)
		if err != nil {
			file.Close()
			d.releaseConn()
			return nil, 0, fmt.Errorf("lookup file info error: %v", err)
		}
		length = int64(info.Size())
	}
	d.updateLastConnTime()
	return &connReadCloser{rc: file, release: d.releaseConn}, length, nil
}

// DownloadWithOffset 的偏移量约定（与 SMB/WebDAV 统一）：offset > size
// 报错；offset == size 返回位于 EOF 的空流（HTTP 层再按 416 处理）。
// 此前 offset >= size（size>0 时）直接报错，与另两个后端不一致。
func (d *Nfs) DownloadWithOffset(path string, offset int64) (io.ReadCloser, int64, error) {
	if err := d.checkConn(); err != nil {
		return nil, 0, err
	}
	rootPath := d.getRootPath()
	if rootPath == "" {
		return nil, 0, fmt.Errorf("root path is empty")
	}
	conn := d.acquireConn()
	if conn.cli == nil {
		return nil, 0, fmt.Errorf("nfs client is not connected")
	}
	fail := func(length int64, err error) (io.ReadCloser, int64, error) {
		d.releaseConn()
		return nil, length, err
	}
	fullPath := filepath.Join(rootPath, path)
	file, err := conn.cli.Open(fullPath)
	if err != nil {
		d.cleanLastConnTime()
		return fail(0, fmt.Errorf("open file error: %v", err))
	}
	length := file.FileSize()
	if length < 0 {
		info, _, err := conn.cli.Lookup(fullPath)
		if err != nil {
			file.Close()
			return fail(0, fmt.Errorf("lookup file info error: %v", err))
		}
		length = int64(info.Size())
	}
	if offset > length {
		file.Close()
		return fail(length, fmt.Errorf("offset is out of range"))
	}
	_, err = file.Seek(offset, io.SeekStart)
	if err != nil {
		file.Close()
		return fail(length, err)
	}
	d.updateLastConnTime()
	return &connReadCloser{rc: file, release: d.releaseConn}, length, nil
}

func (d *Nfs) Delete(path string) error {
	if err := d.checkConn(); err != nil {
		return err
	}
	rootPath := d.getRootPath()
	if rootPath == "" {
		return fmt.Errorf("root path is empty")
	}
	conn := d.acquireConn()
	if conn.cli == nil {
		return fmt.Errorf("nfs client is not connected")
	}
	defer d.releaseConn()
	fullPath := filepath.Join(rootPath, path)
	err := conn.cli.Remove(fullPath)
	if err != nil {
		return err
	}
	d.updateLastConnTime()
	return nil
}

// Upload 的 size 参数被忽略（见 StorageDrive.Upload）：读到 EOF 为止，
// 长度校验由 ImgManager 的 sizeCheckReader 完成。
func (d *Nfs) Upload(path string, reader io.ReadCloser, size int64, lastModified time.Time) error {
	_ = size
	_ = lastModified
	if err := d.checkConn(); err != nil {
		return err
	}
	if reader == nil {
		return fmt.Errorf("reader is nil")
	}
	defer reader.Close()
	rootPath := d.getRootPath()
	if rootPath == "" {
		return fmt.Errorf("root path is empty")
	}
	conn := d.acquireConn()
	if conn.cli == nil {
		return fmt.Errorf("nfs client is not connected")
	}
	defer d.releaseConn()
	fullPath := filepath.Join(rootPath, path)
	err := d.mkdirAll(filepath.Dir(fullPath), 0755)
	if err != nil {
		d.cleanLastConnTime()
		return fmt.Errorf("mkdir %s error: %v", filepath.Dir(fullPath), err)
	}
	_, err = conn.cli.Create(fullPath, 0644)
	if err != nil {
		d.cleanLastConnTime()
		return fmt.Errorf("create file error: %v", err)
	}
	f, err := conn.cli.OpenFile(fullPath, 0644)
	if err != nil {
		conn.cli.Remove(fullPath)
		d.cleanLastConnTime()
		return fmt.Errorf("open file error: %v", err)
	}
	_, copyErr := io.Copy(f, reader)
	closeErr := f.Close()
	if copyErr != nil {
		conn.cli.Remove(fullPath)
		return copyErr
	}
	if closeErr != nil {
		// Close 失败同样可能只写了部分数据：删除残缺文件并返回错误，
		// 此前 Close 错误被直接丢弃，截断文件会被当作已同步。
		conn.cli.Remove(fullPath)
		return closeErr
	}
	d.updateLastConnTime()
	return nil
}

func (d *Nfs) Range(dir string, deal func(fs.FileInfo) bool) error {
	if err := d.checkConn(); err != nil {
		return err
	}
	rootPath := d.getRootPath()
	if rootPath == "" {
		return fmt.Errorf("root path is empty")
	}
	conn := d.acquireConn()
	if conn.cli == nil {
		return fmt.Errorf("nfs client is not connected")
	}
	defer d.releaseConn()
	fullPath := filepath.Join(rootPath, dir)
	infos, err := conn.cli.ReadDirPlus(fullPath)
	if err != nil {
		d.cleanLastConnTime()
		return err
	}
	sort.Sort(desc(infos))
	for _, info := range infos {
		if info.Name() == "." || info.Name() == ".." {
			continue
		}
		if !deal(info) {
			break
		}
	}
	d.updateLastConnTime()
	return nil
}

// MkdirAll 实现 StorageDrive.MkdirAll：dir 相对于驱动根目录，
// 已存在时成功。复用 mkdirAll 按段逐级建目录（Upload 建父目录
// 用的同一原语）。
func (d *Nfs) MkdirAll(dir string) error {
	if err := d.checkConn(); err != nil {
		return err
	}
	rootPath := d.getRootPath()
	if rootPath == "" {
		return fmt.Errorf("root path is empty")
	}
	if err := d.mkdirAll(filepath.Join(rootPath, dir), 0755); err != nil {
		d.cleanLastConnTime()
		return err
	}
	d.updateLastConnTime()
	return nil
}

type desc []*nfs.EntryPlus

func (d desc) Len() int      { return len(d) }
func (d desc) Swap(i, j int) { d[i], d[j] = d[j], d[i] }
func (d desc) Less(i, j int) bool {
	return d[i].ModTime().After(d[j].ModTime())
}

// mkdirAll makes a directory path and all parents that does not exist by d.cli.Mkdir.
func (d *Nfs) mkdirAll(path string, perm fs.FileMode) error {
	if d.getRootPath() == "" {
		return fmt.Errorf("root path is empty")
	}
	conn := d.acquireConn()
	if conn.cli == nil {
		return fmt.Errorf("nfs client is not connected")
	}
	defer d.releaseConn()
	eles := strings.Split(path, "/")
	if len(eles) == 0 {
		return nil
	}
	for i := 1; i <= len(eles); i++ {
		dir := "/" + filepath.Join(eles[:i]...)
		// 根目录是 NFS mount point 本身，已存在且无法 mkdir（空 filename 会触发 GARBAGE_ARGS）
		if dir == "/" {
			continue
		}
		_, err := conn.cli.Mkdir(dir, perm)
		if err != nil {
			if os.IsExist(err) {
				continue
			}
			return fmt.Errorf("mkdir %s error: %v", dir, err)
		}
	}

	return nil
}
