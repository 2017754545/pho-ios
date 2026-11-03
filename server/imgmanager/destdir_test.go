package imgmanager

import (
	"bytes"
	"path/filepath"
	"testing"
	"time"

	pb "github.com/fregie/img_syncer/proto"
)

func TestSanitizeDestDir(t *testing.T) {
	accept := map[string]string{
		"":           "",
		"manual":     "manual",
		"a/b":        "a/b",
		"my photos":  "my photos",
		"manual-1_x": "manual-1_x",
	}
	for raw, want := range accept {
		got, err := SanitizeDestDir(raw)
		if err != nil {
			t.Fatalf("SanitizeDestDir(%q) unexpected error: %v", raw, err)
		}
		if got != want {
			t.Fatalf("SanitizeDestDir(%q) = %q, want %q", raw, got, want)
		}
	}
	reject := []string{
		"../x", "a/../b", "/manual", "manual/", "a//b", `a\b`, "a/./b",
		".", "live", "live/x", ".thumbnail", ".thumbnail/x",
		"2026", "20260102", "2026/x", "20260102/x", "a/b/",
	}
	for _, raw := range reject {
		if got, err := SanitizeDestDir(raw); err == nil {
			t.Fatalf("SanitizeDestDir(%q) = %q, want error", raw, got)
		}
	}
}

func TestGenPathDestDirTypeLayout(t *testing.T) {
	im := NewImgManager(Option{WorkerNum: 1})
	defer im.Close()
	im.SetDirectoryType(pb.DirectoryType_DIRECTORY_TYPE_01)
	date := time.Date(2026, 1, 2, 15, 4, 5, 0, time.UTC)

	cases := []struct {
		name    string
		options Options
		want    string
	}{
		{"photo", Options{DestDir: "manual"}, "manual/image/photo.jpg"},
		{"video", Options{DestDir: "manual"}, "manual/video/clip.mp4"},
		{"live photo", Options{DestDir: "manual", IsLivePhoto: true}, "manual/image/live_photo/photo.jpg"},
		// Live 伴生视频强制 image + live_ 布局，绝不进 video/。
		{"live video", Options{DestDir: "manual", IsLivePhoto: true}, "manual/image/live_clip/clip.mp4"},
		{"nested dest", Options{DestDir: "a/b"}, "a/b/image/photo.jpg"},
		{"nested dest video", Options{DestDir: "a/b"}, "a/b/video/clip.mp4"},
	}
	names := map[string]string{
		"photo":             "photo.jpg",
		"video":             "clip.mp4",
		"live photo":        "photo.jpg",
		"live video":        "clip.mp4",
		"nested dest":       "photo.jpg",
		"nested dest video": "clip.mp4",
	}
	for _, c := range cases {
		got := im.genPath(names[c.name], date, c.options)
		if got != c.want {
			t.Fatalf("%s: genPath = %q, want %q", c.name, got, c.want)
		}
	}

	// 无 DestDir 时保持日期目录布局（两种 dirType）。
	if got := im.genPath("pic1.jpg", date, Options{}); got != "2026/01/02/pic1.jpg" {
		t.Fatalf("no dest type01: genPath = %q", got)
	}
	im.SetDirectoryType(pb.DirectoryType_DIRECTORY_TYPE_02)
	if got := im.genPath("pic1.jpg", date, Options{}); got != "20260102/pic1.jpg" {
		t.Fatalf("no dest type02: genPath = %q", got)
	}

	// 加密后缀行为不变：.aes 追加在完整路径之后。
	enc := Options{DestDir: "manual", EncyptOption: EncryptOption{Type: AES_256_GCM, Password: "pw"}}
	if got := im.genPath("pic.jpg", date, enc); got != "manual/image/pic.jpg.aes" {
		t.Fatalf("encrypted dest: genPath = %q", got)
	}
	// 缩略图镜像：.thumbnail 前缀 + 与原件相同的 dest/type 路径。
	thumb := filepath.Join(defaultThumbnailDir, im.genPath("pic.jpg", date, Options{DestDir: "manual"}))
	if thumb != ".thumbnail/manual/image/pic.jpg" {
		t.Fatalf("thumbnail dest: path = %q", thumb)
	}
}

func TestUploadDestDirPaths(t *testing.T) {
	mock := newMockDrive()
	im := NewImgManager(Option{WorkerNum: 1})
	defer im.Close()
	im.SetDrive(mock)
	im.SetDirectoryType(pb.DirectoryType_DIRECTORY_TYPE_01)
	date := time.Date(2026, 1, 2, 15, 4, 5, 0, time.UTC)
	content := []byte("data")

	if err := im.Upload(bytes.NewReader(content), int64(len(content)), "pic.jpg", date, WithDestDir("manual")); err != nil {
		t.Fatalf("Upload photo: %v", err)
	}
	if err := im.Upload(bytes.NewReader(content), int64(len(content)), "clip.mp4", date, WithDestDir("manual")); err != nil {
		t.Fatalf("Upload video: %v", err)
	}
	if err := im.UploadLiveVideo(bytes.NewReader(content), int64(len(content)), "clip.mp4", date, IsLivePhoto(true), WithDestDir("manual")); err != nil {
		t.Fatalf("UploadLiveVideo: %v", err)
	}
	if err := im.UploadThumbnail(bytes.NewReader(content), int64(len(content)), "pic.jpg", date, WithDestDir("manual")); err != nil {
		t.Fatalf("UploadThumbnail: %v", err)
	}
	// 非法 DestDir：报错且不写任何文件。
	if err := im.Upload(bytes.NewReader(content), int64(len(content)), "pic.jpg", date, WithDestDir("../evil")); err == nil {
		t.Fatalf("Upload with traversal dest dir: want error")
	}

	mock.mu.Lock()
	defer mock.mu.Unlock()
	want := []string{
		"manual/image/pic.jpg",
		"manual/video/clip.mp4",
		"manual/image/live_clip/clip.mp4",
		".thumbnail/manual/image/pic.jpg",
	}
	for _, p := range want {
		if _, ok := mock.files[p]; !ok {
			t.Fatalf("missing uploaded file %q, got %v", p, mock.files)
		}
	}
	if len(mock.files) != len(want) {
		t.Fatalf("unexpected files: %v", mock.files)
	}
}

func dirEntries(entries ...mockDirEntry) []mockDirEntry { return entries }

func TestRangeByDateDiscoversAlbumDirs(t *testing.T) {
	mock := newMockDrive()
	file := func(name string) mockDirEntry { return mockDirEntry{name: name, size: 10} }
	dir := func(name string) mockDirEntry { return mockDirEntry{name: name, isDir: true} }
	mock.rangeFiles = map[string][]mockDirEntry{
		".": {
			dir("2026"), dir("manual"), dir("archive"), dir(".thumbnail"), dir("live"), file("notes.txt"),
		},
		"2026":         {dir("01")},
		"2026/01":      {dir("02")},
		"2026/01/02":   {file("20260102030405_IMG_0001.jpg")},
		"manual":       {dir("video"), dir("image")},
		"manual/video": {file("20260102030405_VID_0001.mp4")},
		"manual/image": {file("20260102030405_IMG_0002.jpg"), dir("live_20260102030405_IMG_0003")},
		"manual/image/live_20260102030405_IMG_0003": {
			file("20260102030405_IMG_0003.jpg"), file("20260102030405_IMG_0003.mp4"),
		},
		"archive":                 {dir("video")},
		"archive/video":           {file("20250101000000_OLD.mp4")},
		".thumbnail":              {dir("manual")},
		".thumbnail/manual":       {dir("image")},
		".thumbnail/manual/image": {file("thumb.jpg")},
		"live":                    {file("orphan.jpg")},
	}
	im := NewImgManager(Option{WorkerNum: 1})
	defer im.Close()
	im.SetDrive(mock)

	found := map[string]bool{}
	var liveFlags map[string]bool = map[string]bool{}
	err := im.RangeByDate(time.Date(2026, 2, 1, 0, 0, 0, 0, time.UTC), func(info ImgInfo) bool {
		found[info.Path] = true
		liveFlags[info.Path] = info.IsLivePhoto
		return true
	})
	if err != nil {
		t.Fatalf("RangeByDate: %v", err)
	}
	want := map[string]bool{
		"2026/01/02/20260102030405_IMG_0001.jpg":                                false,
		"manual/video/20260102030405_VID_0001.mp4":                              false,
		"manual/image/20260102030405_IMG_0002.jpg":                              false,
		"manual/image/live_20260102030405_IMG_0003/20260102030405_IMG_0003.jpg": true,
		"archive/video/20250101000000_OLD.mp4":                                  false,
	}
	for path, wantLive := range want {
		if !found[path] {
			t.Fatalf("missing discovered path %q, found %v", path, found)
		}
		if liveFlags[path] != wantLive {
			t.Fatalf("path %q IsLivePhoto = %v, want %v", path, liveFlags[path], wantLive)
		}
	}
	// 不应被发现：live_ 内的伴生视频（由 GetLiveVideoOffset 查找）、
	// 缩略图镜像、根 live 目录、根部普通文件。
	forbidden := []string{
		"manual/image/live_20260102030405_IMG_0003/20260102030405_IMG_0003.mp4",
		".thumbnail/manual/image/thumb.jpg",
		"live/orphan.jpg",
		"notes.txt",
	}
	for _, path := range forbidden {
		if found[path] {
			t.Fatalf("unexpected discovered path %q", path)
		}
	}
	if len(found) != len(want) {
		t.Fatalf("discovered %d paths, want %d: %v", len(found), len(want), found)
	}
}

func TestRangeByDateAlbumEarlyStop(t *testing.T) {
	mock := newMockDrive()
	file := func(name string) mockDirEntry { return mockDirEntry{name: name, size: 10} }
	dir := func(name string) mockDirEntry { return mockDirEntry{name: name, isDir: true} }
	mock.rangeFiles = map[string][]mockDirEntry{
		".":            {dir("2026"), dir("manual")},
		"2026":         {dir("01")},
		"2026/01":      {dir("02")},
		"2026/01/02":   {file("a.jpg")},
		"manual":       {dir("image")},
		"manual/image": {file("b.jpg")},
	}
	im := NewImgManager(Option{WorkerNum: 1})
	defer im.Close()
	im.SetDrive(mock)

	count := 0
	err := im.RangeByDate(time.Date(2026, 2, 1, 0, 0, 0, 0, time.UTC), func(info ImgInfo) bool {
		count++
		return false // 第一个就停
	})
	if err != nil {
		t.Fatalf("RangeByDate: %v", err)
	}
	if count != 1 {
		t.Fatalf("early stop visited %d files, want 1", count)
	}
}
