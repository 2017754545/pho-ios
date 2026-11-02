package smb

import (
	"fmt"
	"io"
	"io/fs"
	"log"
	"net"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/fregie/img_syncer/server/util"
	"github.com/hirochachacha/go-smb2"
)

const smbConnTTL = 5 * time.Minute

// fsRefWaitTimeout 是重连/关闭时等待在途 I/O 用完旧 Share 句柄的最长等待；
// 超时后仍会 Umount（尽力而为），避免重连被一个挂起的网络操作永久堵住。
const fsRefWaitTimeout = 2 * time.Second

type Smb struct {
	addr     string
	username string
	password string

	// cfgMu 保护 shareName/rootPath：SetShare/SetRootPath 在任意 goroutine
	// 调用时都不得与在途 I/O 的读取竞态。
	cfgMu     sync.RWMutex
	shareName string
	rootPath  string

	// fsMu 保护 fs 句柄的交换；fsRefs 是持有句柄快照的在途操作计数。
	// 任何方法都不得直接读写 s.fs，必须经 acquireFS/swapFS 拿到快照后
	// 再操作——重连（checkConn）与 Close 会先换出旧句柄、等引用排空
	// 再 Umount，SetDrive 立即关闭旧驱动时在途 I/O 不会拿到已关闭句柄。
	fsMu              sync.RWMutex
	fs                *smb2.Share
	fsRefs            int32
	lastConnTimestamp int64
	downloadLock      sync.Mutex
	connMu            sync.Mutex
}

// getShareName/getRootPath/setShareName/setRootPath 是 cfgMu 保护的访问器。
func (s *Smb) getShareName() string {
	s.cfgMu.RLock()
	defer s.cfgMu.RUnlock()
	return s.shareName
}

func (s *Smb) getRootPath() string {
	s.cfgMu.RLock()
	defer s.cfgMu.RUnlock()
	return s.rootPath
}

func (s *Smb) setShareName(name string) {
	s.cfgMu.Lock()
	defer s.cfgMu.Unlock()
	s.shareName = name
}

func (s *Smb) setRootPath(path string) {
	s.cfgMu.Lock()
	defer s.cfgMu.Unlock()
	s.rootPath = path
}

// acquireFS 返回当前 Share 句柄快照并计入在途引用；调用方必须在用完
// 后调用 releaseFS。句柄为 nil 时返回 nil 且不计数。
func (s *Smb) acquireFS() *smb2.Share {
	s.fsMu.RLock()
	defer s.fsMu.RUnlock()
	if s.fs == nil {
		return nil
	}
	atomic.AddInt32(&s.fsRefs, 1)
	return s.fs
}

func (s *Smb) releaseFS() {
	atomic.AddInt32(&s.fsRefs, -1)
}

// swapFS 用 newFS 替换当前句柄并返回旧句柄（可能为 nil）。
func (s *Smb) swapFS(newFS *smb2.Share) *smb2.Share {
	s.fsMu.Lock()
	defer s.fsMu.Unlock()
	old := s.fs
	s.fs = newFS
	return old
}

// waitFSRefs 等待在途引用排空，最多等待 timeout，超时返回 false。
func (s *Smb) waitFSRefs(timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	for atomic.LoadInt32(&s.fsRefs) > 0 {
		if time.Now().After(deadline) {
			return false
		}
		time.Sleep(10 * time.Millisecond)
	}
	return true
}

func NewSmbDrive(addr, username, password string) *Smb {
	if strings.Index(addr, ":") < 0 {
		addr = addr + ":445"
	}
	smb := &Smb{
		addr:     addr,
		username: username,
		password: password,
	}

	return smb
}

func (s *Smb) lastConnTime() time.Time {
	ts := atomic.LoadInt64(&s.lastConnTimestamp)
	return time.Unix(ts, 0)
}

func (s *Smb) updateLastConnTime() {
	atomic.StoreInt64(&s.lastConnTimestamp, time.Now().Unix())
}

func (s *Smb) cleanLastConnTime() {
	atomic.StoreInt64(&s.lastConnTimestamp, 0)
}

func (s *Smb) checkConn() error {
	if time.Since(s.lastConnTime()) < smbConnTTL {
		if fs := s.acquireFS(); fs != nil {
			// 轻量健康检查：对已知存在的路径做 Stat
			checkPath := "/"
			if rp := s.getRootPath(); rp != "" {
				checkPath = rp
			}
			_, err := fs.Stat(checkPath)
			s.releaseFS()
			if err == nil {
				return nil
			}
			// Stat 失败，连接可能已断开，继续执行下方重连
		} else {
			return nil
		}
	}
	s.connMu.Lock()
	defer s.connMu.Unlock()
	// 双重检查：获取锁后可能有其他 goroutine 已完成重连
	if time.Since(s.lastConnTime()) < smbConnTTL {
		if fs := s.acquireFS(); fs != nil {
			_, err := fs.Stat("/")
			s.releaseFS()
			if err == nil {
				return nil
			}
		} else {
			return nil
		}
	}
	old := s.swapFS(nil)
	s.waitFSRefs(fsRefWaitTimeout)
	if old != nil {
		_ = old.Umount()
	}
	return s.Connect()
}

func (s *Smb) Dial() (*smb2.Session, error) {
	if s.addr == "" || s.username == "" {
		return nil, fmt.Errorf("smb config error: addr=%s, username=%s, password=***, shareName=%s", s.addr, s.username, s.getShareName())
	}
	conn, err := (&net.Dialer{Timeout: 30 * time.Second}).Dial("tcp", s.addr)
	if err != nil {
		return nil, err
	}
	d := &smb2.Dialer{
		Initiator: &smb2.NTLMInitiator{
			User:     s.username,
			Password: s.password,
		},
	}
	sess, err := d.Dial(conn)
	if err != nil {
		conn.Close()
		return nil, err
	}
	return sess, nil
}

func (s *Smb) Connect() error {
	if s.getShareName() == "" {
		return fmt.Errorf("smb share name is empty")
	}
	sess, err := s.Dial()
	if err != nil {
		return err
	}

	share, err := sess.Mount(s.getShareName())
	if err != nil {
		sess.Logoff()
		return err
	}
	if old := s.swapFS(share); old != nil {
		_ = old.Umount()
	}
	s.updateLastConnTime()
	return nil
}

func (s *Smb) ListShare() ([]string, error) {
	sess, err := s.Dial()
	if err != nil {
		return nil, err
	}
	defer sess.Logoff()
	shares, err := sess.ListSharenames()
	if err != nil {
		return nil, err
	}
	return shares, nil
}

func (s *Smb) SetShare(shareName string) error {
	if _, err := util.CleanShareName(shareName); err != nil {
		return err
	}
	shares, err := s.ListShare()
	if err != nil {
		return err
	}
	for _, share := range shares {
		if share == shareName {
			s.setShareName(shareName)
			return nil
		}
	}
	return fmt.Errorf("share %s not exist", shareName)
}

func (s *Smb) IsShareSet() bool {
	return s.getShareName() != ""
}

func (s *Smb) IsRootPathSet() bool {
	return s.getRootPath() != ""
}

// ShareName/RootPath 供 API 层读取当前配置（如重配失败时恢复旧值）。
func (s *Smb) ShareName() string { return s.getShareName() }
func (s *Smb) RootPath() string  { return s.getRootPath() }

func (s *Smb) SetRootPath(rootPath string) error {
	if rootPath == "" {
		return fmt.Errorf("root path is empty")
	}
	// 先校验路径语法：含 ".." 的根路径不得用于 Stat/挂载，拒绝时不触网。
	cleaned, err := util.CleanDirPath(rootPath)
	if err != nil {
		return err
	}
	if cleaned == "" {
		return fmt.Errorf("root path is empty")
	}
	if err := s.checkConn(); err != nil {
		return err
	}
	fs := s.acquireFS()
	if fs == nil {
		return fmt.Errorf("smb share is not connected")
	}
	defer s.releaseFS()
	_, err = fs.Stat(cleaned)
	if err != nil {
		if os.IsNotExist(err) {
			return fmt.Errorf("root path %s not exist", cleaned)
		}
		return err
	}
	s.setRootPath(cleaned)
	return nil
}

// Upload 的 size 参数被忽略（见 StorageDrive.Upload）：读到 EOF 为止，
// 长度校验由 ImgManager 的 sizeCheckReader 完成。
func (s *Smb) Upload(path string, content io.ReadCloser, size int64, lastModified time.Time) error {
	_ = size
	defer content.Close()
	if err := s.checkConn(); err != nil {
		return err
	}
	rootPath := s.getRootPath()
	if rootPath == "" {
		return fmt.Errorf("root path is empty")
	}
	fs := s.acquireFS()
	if fs == nil {
		return fmt.Errorf("smb share is not connected")
	}
	defer s.releaseFS()
	fullPath := filepath.Join(rootPath, path)
	if err := fs.MkdirAll(filepath.Dir(fullPath), 0755); err != nil {
		s.cleanLastConnTime()
		return err
	}
	f, err := fs.Create(fullPath)
	if err != nil {
		s.cleanLastConnTime()
		return err
	}

	_, copyErr := io.Copy(f, content)
	closeErr := f.Close()
	if copyErr != nil {
		// 删除残缺文件，防止 FilterNotUploaded 按名匹配将其标记为已上传（issue #83/#82）
		if rmErr := fs.Remove(fullPath); rmErr != nil {
			log.Printf("remove partial file failed (non-fatal): %v", rmErr)
		}
		return fmt.Errorf("copy error: %v", copyErr)
	}
	if closeErr != nil {
		// Close 失败同样可能只写了部分数据：与 copyErr 分支一样删除残缺文件。
		if rmErr := fs.Remove(fullPath); rmErr != nil {
			log.Printf("remove partial file failed (non-fatal): %v", rmErr)
		}
		return fmt.Errorf("close error: %v", closeErr)
	}
	if !lastModified.IsZero() {
		// 修改时间设置失败是非致命错误，仅记录日志
		if err := fs.Chtimes(fullPath, lastModified, lastModified); err != nil {
			log.Printf("set modification time failed (non-fatal): %v", err)
		}
	}
	s.updateLastConnTime()

	return nil
}

func (s *Smb) IsExist(path string) (bool, error) {
	if err := s.checkConn(); err != nil {
		return false, err
	}
	rootPath := s.getRootPath()
	if rootPath == "" {
		return false, fmt.Errorf("root path is empty")
	}
	fs := s.acquireFS()
	if fs == nil {
		return false, fmt.Errorf("smb share is not connected")
	}
	defer s.releaseFS()
	fullPath := filepath.Join(rootPath, path)
	_, err := fs.Stat(fullPath)
	if err != nil {
		if os.IsNotExist(err) {
			s.updateLastConnTime()
			return false, nil
		}
		s.cleanLastConnTime()
		return false, err
	}
	s.updateLastConnTime()
	return true, nil
}

func (s *Smb) Download(path string) (io.ReadCloser, int64, error) {
	// if err := s.checkConn(); err != nil {
	// 	return nil, 0, err
	// }
	// if s.rootPath == "" {
	// 	return nil, 0, fmt.Errorf("root path is empty")
	// }
	// fullPath := filepath.Join(s.rootPath, path)
	// f, err := s.fs.Open(fullPath)
	// if err != nil {
	// 	s.cleanLastConnTime()
	// 	return nil, 0, err
	// }
	// fi, err := f.Stat()
	// if err != nil {
	// 	return nil, 0, fmt.Errorf("stat %s error: %v", path, err)
	// }
	// log.Printf("got %s stat, size: %d", path, fi.Size())
	// s.updateLastConnTime()
	// return f, fi.Size(), nil
	return s.DownloadWithOffset(path, 0)
}

// lockedReadCloser 把 downloadLock 持有到流关闭为止：此前锁只在
// Open+Seek 期间持有，Read 发生在解锁之后，并发下载并未真正串行化。
// 调用方必须 Close 返回的流，否则后续下载会一直阻塞在锁上。
type lockedReadCloser struct {
	rc     io.ReadCloser
	unlock func()
	once   sync.Once
}

func (l *lockedReadCloser) Read(p []byte) (int, error) { return l.rc.Read(p) }

func (l *lockedReadCloser) Close() error {
	err := l.rc.Close()
	l.once.Do(l.unlock)
	return err
}

// DownloadWithOffset 从 SMB 远程文件读取指定偏移量起的内容。
// 偏移量约定（与 NFS/WebDAV 统一）：offset > size 报错；offset == size
// 返回位于 EOF 的空流（HTTP 层再按 416 处理）。
// 注意：由于 go-smb2 库不支持在同一 Share 上并发读取，下载操作通过
// downloadLock 串行化，锁由返回流的 Close 释放。
func (s *Smb) DownloadWithOffset(path string, offset int64) (io.ReadCloser, int64, error) {
	s.downloadLock.Lock()
	fsAcquired := false
	fail := func(err error) (io.ReadCloser, int64, error) {
		if fsAcquired {
			s.releaseFS()
		}
		s.downloadLock.Unlock()
		return nil, 0, err
	}
	if err := s.checkConn(); err != nil {
		return fail(err)
	}
	rootPath := s.getRootPath()
	if rootPath == "" {
		return fail(fmt.Errorf("root path is empty"))
	}
	fs := s.acquireFS()
	if fs == nil {
		return fail(fmt.Errorf("smb share is not connected"))
	}
	// 句柄引用随返回的流存活：流 Close 时才释放引用并解锁，
	// 否则重连/关闭会在读取中途 Umount 正在读的 Share。
	fsAcquired = true
	fullPath := filepath.Join(rootPath, path)
	f, err := fs.Open(fullPath)
	if err != nil {
		s.cleanLastConnTime()
		return fail(err)
	}
	s.updateLastConnTime()
	fi, err := f.Stat()
	if err != nil {
		f.Close()
		s.cleanLastConnTime()
		return fail(err)
	}
	if offset > fi.Size() {
		f.Close()
		return fail(fmt.Errorf("offset %d is bigger than file size %d", offset, fi.Size()))
	}
	if _, err = f.Seek(offset, io.SeekStart); err != nil {
		f.Close()
		s.cleanLastConnTime()
		return fail(err)
	}
	return &lockedReadCloser{rc: f, unlock: func() {
		s.releaseFS()
		s.downloadLock.Unlock()
	}}, fi.Size(), nil
}

func (s *Smb) Delete(path string) error {
	if err := s.checkConn(); err != nil {
		return err
	}
	rootPath := s.getRootPath()
	if rootPath == "" {
		return fmt.Errorf("root path is empty")
	}
	fs := s.acquireFS()
	if fs == nil {
		return fmt.Errorf("smb share is not connected")
	}
	defer s.releaseFS()
	fullPath := filepath.Join(rootPath, path)
	err := fs.Remove(fullPath)
	if err != nil {
		s.cleanLastConnTime()
		return err
	}
	s.updateLastConnTime()

	return nil
}

func (s *Smb) Close() error {
	old := s.swapFS(nil)
	s.waitFSRefs(fsRefWaitTimeout)
	if old != nil {
		_ = old.Umount()
	}
	return nil
}

func (s *Smb) Range(dir string, deal func(fs.FileInfo) bool) error {
	if err := s.checkConn(); err != nil {
		return err
	}
	rootPath := s.getRootPath()
	if rootPath == "" {
		return fmt.Errorf("root path is empty")
	}
	fs := s.acquireFS()
	if fs == nil {
		return fmt.Errorf("smb share is not connected")
	}
	defer s.releaseFS()
	fullPath := filepath.Join(rootPath, dir)
	infos, err := fs.ReadDir(fullPath)
	if err != nil {
		s.cleanLastConnTime()
		return err
	}
	s.updateLastConnTime()
	sort.Sort(desc(infos))
	for _, info := range infos {
		if !deal(info) {
			break
		}
	}
	return nil
}

type desc []fs.FileInfo

func (d desc) Len() int      { return len(d) }
func (d desc) Swap(i, j int) { d[i], d[j] = d[j], d[i] }
func (d desc) Less(i, j int) bool {
	return d[i].ModTime().After(d[j].ModTime())
}
