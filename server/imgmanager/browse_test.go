package imgmanager

import (
	"bytes"
	"fmt"
	"io"
	"io/fs"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	pb "github.com/fregie/img_syncer/proto"
)

func TestSanitizeBrowseDir(t *testing.T) {
	accept := map[string]string{
		"":           "",
		".":          "",
		"manual":     "manual",
		"a/b":        "a/b",
		"my photos":  "my photos",
		"manual-1_x": "manual-1_x",
		// 日期形状目录必须可浏览：与 SanitizeDestDir 不同，这里不拒绝。
		"2026":       "2026",
		"20260102":   "20260102",
		"2026/01/02": "2026/01/02",
		// CleanDirPath 折叠 "." 段、重复斜杠与尾部斜杠（浏览 UI
		// 从不产生这类拼写，折叠后仍在同一目录内）。
		"a/./b": "a/b",
		"a//b":  "a/b",
		"a/":    "a",
	}
	for raw, want := range accept {
		got, err := SanitizeBrowseDir(raw)
		if err != nil {
			t.Fatalf("SanitizeBrowseDir(%q) unexpected error: %v", raw, err)
		}
		if got != want {
			t.Fatalf("SanitizeBrowseDir(%q) = %q, want %q", raw, got, want)
		}
	}
	reject := []string{
		"../x", "a/../b", "/../etc", `a\b`, ".thumbnail", ".thumbnail/x",
		"/", "/abs",
	}
	for _, raw := range reject {
		if got, err := SanitizeBrowseDir(raw); err == nil {
			t.Fatalf("SanitizeBrowseDir(%q) = %q, want error", raw, got)
		}
	}
}

func TestGenPathExactDirLayout(t *testing.T) {
	im := NewImgManager(Option{WorkerNum: 1})
	defer im.Close()
	im.SetDirectoryType(pb.DirectoryType_DIRECTORY_TYPE_01)
	date := time.Date(2026, 1, 2, 15, 4, 5, 0, time.UTC)

	cases := []struct {
		name    string
		file    string
		options Options
		want    string
	}{
		{"exact photo", "photo.jpg", Options{DestDir: "mydir", ExactDestDir: true}, "mydir/photo.jpg"},
		{"exact video", "clip.mp4", Options{DestDir: "mydir", ExactDestDir: true}, "mydir/clip.mp4"},
		{"exact live photo", "photo.jpg", Options{DestDir: "mydir", ExactDestDir: true, IsLivePhoto: true}, "mydir/live_photo/photo.jpg"},
		{"exact live video", "clip.mp4", Options{DestDir: "mydir", ExactDestDir: true, IsLivePhoto: true}, "mydir/live_clip/clip.mp4"},
		{"exact root", "photo.jpg", Options{ExactDestDir: true}, "photo.jpg"},
		{"exact nested dest", "photo.jpg", Options{DestDir: "a/b", ExactDestDir: true}, "a/b/photo.jpg"},
		{"exact date dest", "photo.jpg", Options{DestDir: "2026/01/02", ExactDestDir: true}, "2026/01/02/photo.jpg"},
		// 未开精确模式时保持原有类型分目录行为。
		{"typed photo", "photo.jpg", Options{DestDir: "mydir"}, "mydir/image/photo.jpg"},
		{"typed video", "clip.mp4", Options{DestDir: "mydir"}, "mydir/video/clip.mp4"},
	}
	for _, c := range cases {
		if got := im.genPath(c.file, date, c.options); got != c.want {
			t.Fatalf("%s: genPath = %q, want %q", c.name, got, c.want)
		}
	}

	// 缩略图镜像：.thumbnail 前缀 + 与原件相同的精确路径。
	thumb := filepath.Join(defaultThumbnailDir, im.genPath("pic.jpg", date, Options{DestDir: "mydir", ExactDestDir: true}))
	if thumb != ".thumbnail/mydir/pic.jpg" {
		t.Fatalf("thumbnail exact: path = %q", thumb)
	}
	// 加密后缀行为不变：.aes 追加在完整路径之后。
	enc := Options{DestDir: "mydir", ExactDestDir: true, EncyptOption: EncryptOption{Type: AES_256_GCM, Password: "pw"}}
	if got := im.genPath("pic.jpg", date, enc); got != "mydir/pic.jpg.aes" {
		t.Fatalf("encrypted exact: genPath = %q", got)
	}
}

// memBrowseDrive 是 ListDir/MkdirDir 测试用的内存驱动：按相对
// 路径（"/" 分隔、无前导斜杠，"" 表示根目录）维护目录与文件，
// Range 只返回直接子项、未知目录报错，MkdirAll 逐级建目录，
// Upload 自动建父目录（与真实驱动一致）。
type memBrowseDrive struct {
	dirs       map[string]bool
	files      map[string][]byte
	rangeCalls []string
	mkdirCalls []string
}

type memBrowseEntry struct {
	name    string
	size    int64
	isDir   bool
	modTime time.Time
}

func (e memBrowseEntry) Name() string       { return e.name }
func (e memBrowseEntry) Size() int64        { return e.size }
func (e memBrowseEntry) Mode() fs.FileMode  { return 0 }
func (e memBrowseEntry) ModTime() time.Time { return e.modTime }
func (e memBrowseEntry) IsDir() bool        { return e.isDir }
func (e memBrowseEntry) Sys() interface{}   { return nil }

func newMemBrowseDrive() *memBrowseDrive {
	return &memBrowseDrive{
		dirs:  map[string]bool{"": true},
		files: map[string][]byte{},
	}
}

func (d *memBrowseDrive) mkdirParents(dir string) {
	for dir != "" {
		d.dirs[dir] = true
		dir = parentDir(dir)
	}
}

func parentDir(p string) string {
	if i := strings.LastIndex(p, "/"); i >= 0 {
		return p[:i]
	}
	return ""
}

func (d *memBrowseDrive) Upload(path string, content io.ReadCloser, size int64, modTime time.Time) error {
	defer content.Close()
	data, err := io.ReadAll(content)
	if err != nil {
		return err
	}
	d.mkdirParents(parentDir(path))
	d.files[path] = data
	return nil
}

func (d *memBrowseDrive) IsExist(path string) (bool, error) {
	_, ok := d.files[path]
	return ok, nil
}

func (d *memBrowseDrive) Download(path string) (io.ReadCloser, int64, error) {
	data, ok := d.files[path]
	if !ok {
		return nil, 0, fmt.Errorf("file not found: %s", path)
	}
	return io.NopCloser(bytes.NewReader(data)), int64(len(data)), nil
}

func (d *memBrowseDrive) DownloadWithOffset(path string, offset int64) (io.ReadCloser, int64, error) {
	return d.Download(path)
}

func (d *memBrowseDrive) Delete(path string) error {
	delete(d.files, path)
	return nil
}

func (d *memBrowseDrive) Range(dir string, deal func(fs.FileInfo) bool) error {
	d.rangeCalls = append(d.rangeCalls, dir)
	if dir == "." {
		dir = ""
	}
	if !d.dirs[dir] {
		return fmt.Errorf("no such directory: %s", dir)
	}
	seen := map[string]memBrowseEntry{}
	for p := range d.dirs {
		if p == "" || p == dir {
			continue
		}
		if parentDir(p) == dir {
			seen[filepath.Base(p)] = memBrowseEntry{name: filepath.Base(p), isDir: true}
		}
	}
	for p, data := range d.files {
		if parentDir(p) == dir {
			seen[filepath.Base(p)] = memBrowseEntry{name: filepath.Base(p), size: int64(len(data))}
		}
	}
	names := make([]string, 0, len(seen))
	for name := range seen {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		if !deal(seen[name]) {
			break
		}
	}
	return nil
}

func (d *memBrowseDrive) MkdirAll(dir string) error {
	d.mkdirCalls = append(d.mkdirCalls, dir)
	d.mkdirParents(dir)
	d.dirs[dir] = true
	return nil
}

func (d *memBrowseDrive) Close() error { return nil }

func TestListDirMkdirDir(t *testing.T) {
	drive := newMemBrowseDrive()
	im := NewImgManager(Option{WorkerNum: 1})
	defer im.Close()
	im.SetDrive(drive)

	// 预置一棵树：根下有日期目录、普通目录、文件与 .thumbnail。
	for _, dir := range []string{"2026/01/02", "trips", ".thumbnail"} {
		if err := drive.MkdirAll(dir); err != nil {
			t.Fatal(err)
		}
	}
	drive.mkdirCalls = nil
	for _, path := range []string{"2026/01/02/a.jpg", "2026/top.jpg", "trips/b.mp4", "root.jpg", ".thumbnail/x.jpg"} {
		if err := drive.Upload(path, io.NopCloser(bytes.NewReader([]byte("data"))), 4, time.Time{}); err != nil {
			t.Fatal(err)
		}
	}

	// 根列表：单层（2026/01/02 下的 a.jpg 不出现），.thumbnail 隐藏。
	entries, err := im.ListDir("")
	if err != nil {
		t.Fatalf("ListDir root: %v", err)
	}
	names := map[string]bool{}
	for _, e := range entries {
		names[e.Name] = e.IsDir
	}
	want := map[string]bool{"2026": true, "trips": true, "root.jpg": false}
	if len(names) != len(want) {
		t.Fatalf("root entries = %v, want %v", names, want)
	}
	for name, isDir := range want {
		if got, ok := names[name]; !ok || got != isDir {
			t.Fatalf("root entries = %v, want %v", names, want)
		}
	}
	if len(drive.rangeCalls) != 1 || drive.rangeCalls[0] != "." {
		t.Fatalf("rangeCalls = %v, want [\".\"]", drive.rangeCalls)
	}

	// 子目录列表：只返回直接子项。
	entries, err = im.ListDir("2026")
	if err != nil {
		t.Fatalf("ListDir 2026: %v", err)
	}
	if len(entries) != 2 {
		t.Fatalf("2026 entries = %v, want [01 top.jpg]", entries)
	}

	// 不存在的目录：驱动错误透传。
	if _, err := im.ListDir("missing"); err == nil {
		t.Fatal("ListDir missing: want error")
	}

	// 非法 dir：校验失败，驱动 Range 一次都不调到。
	rangeBefore := len(drive.rangeCalls)
	for _, dir := range []string{"../evil", ".thumbnail", "a/../b"} {
		if _, err := im.ListDir(dir); err == nil {
			t.Fatalf("ListDir(%q): want error", dir)
		}
	}
	if len(drive.rangeCalls) != rangeBefore {
		t.Fatalf("rangeCalls grew on invalid dirs: %v", drive.rangeCalls)
	}

	// 建目录：逐级父目录都被创建。
	if err := im.MkdirDir("new/nested/deep"); err != nil {
		t.Fatalf("MkdirDir: %v", err)
	}
	if len(drive.mkdirCalls) != 1 || drive.mkdirCalls[0] != "new/nested/deep" {
		t.Fatalf("mkdirCalls = %v, want [new/nested/deep]", drive.mkdirCalls)
	}
	entries, err = im.ListDir("new/nested")
	if err != nil {
		t.Fatalf("ListDir new/nested: %v", err)
	}
	if len(entries) != 1 || entries[0].Name != "deep" || !entries[0].IsDir {
		t.Fatalf("new/nested entries = %+v", entries)
	}

	// 建根目录：直接成功，不调驱动；非法 dir：零次触及驱动。
	if err := im.MkdirDir(""); err != nil {
		t.Fatalf("MkdirDir root: %v", err)
	}
	mkdirBefore := len(drive.mkdirCalls)
	for _, dir := range []string{"../evil", ".thumbnail/x"} {
		if err := im.MkdirDir(dir); err == nil {
			t.Fatalf("MkdirDir(%q): want error", dir)
		}
	}
	if len(drive.mkdirCalls) != mkdirBefore {
		t.Fatalf("mkdirCalls grew on invalid dirs: %v", drive.mkdirCalls)
	}
}

func TestUploadExactDestDirValidation(t *testing.T) {
	drive := newMemBrowseDrive()
	im := NewImgManager(Option{WorkerNum: 1})
	defer im.Close()
	im.SetDrive(drive)
	date := time.Date(2026, 1, 2, 15, 4, 5, 0, time.UTC)

	// 精确模式 + 日期形状目录：合法，文件直接落在其下。
	err := im.Upload(bytes.NewReader([]byte("data")), 4, "pic.jpg", date,
		WithDestDir("2026/01/02"), WithExactDestDir(true))
	if err != nil {
		t.Fatalf("exact date dest upload: %v", err)
	}
	if _, ok := drive.files["2026/01/02/pic.jpg"]; !ok {
		t.Fatalf("files = %v, want 2026/01/02/pic.jpg", drive.files)
	}

	// 非精确模式 + 日期形状目录：仍被 SanitizeDestDir 拒绝。
	err = im.Upload(bytes.NewReader([]byte("data")), 4, "pic.jpg", date,
		WithDestDir("2026"))
	if err == nil {
		t.Fatal("typed date dest upload: want error")
	}

	// 精确模式 + .thumbnail：仍拒绝。
	err = im.Upload(bytes.NewReader([]byte("data")), 4, "pic.jpg", date,
		WithDestDir(".thumbnail"), WithExactDestDir(true))
	if err == nil {
		t.Fatal("exact .thumbnail dest upload: want error")
	}
}
