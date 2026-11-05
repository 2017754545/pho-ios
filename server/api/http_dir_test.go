package api

import (
	"bytes"
	"encoding/json"
	"errors"
	"io/fs"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// errTestDrive 是注入驱动 Range 的通用错误，供错误透传测试使用。
var errTestDrive = errors.New("test drive error")

// fakeFileInfo 是 Range 条目的最小 fs.FileInfo 实现，供目录浏览
// 端点测试构造驱动返回的单层条目。
type fakeFileInfo struct {
	name    string
	size    int64
	isDir   bool
	modTime time.Time
}

func (f fakeFileInfo) Name() string      { return f.name }
func (f fakeFileInfo) Size() int64       { return f.size }
func (f fakeFileInfo) Mode() fs.FileMode { return 0 }
func (f fakeFileInfo) ModTime() time.Time {
	return f.modTime
}
func (f fakeFileInfo) IsDir() bool      { return f.isDir }
func (f fakeFileInfo) Sys() interface{} { return nil }

func doDirPost(a *api, url, body string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodPost, url, bytes.NewReader([]byte(body)))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	a.HttpHandler().ServeHTTP(rec, req)
	return rec
}

type dirListJSON struct {
	Entries []struct {
		Name    string    `json:"name"`
		IsDir   bool      `json:"is_dir"`
		Size    int64     `json:"size"`
		ModTime time.Time `json:"mod_time"`
	} `json:"entries"`
}

func TestDirListSingleLevel(t *testing.T) {
	a, drive := newDestTestAPI()
	modTime := time.Date(2026, 1, 2, 15, 4, 5, 0, time.UTC)
	drive.rangeEntries = map[string][]fs.FileInfo{
		".": {
			fakeFileInfo{name: "2026", isDir: true, modTime: modTime},
			fakeFileInfo{name: "a.jpg", size: 42, modTime: modTime},
			fakeFileInfo{name: ".thumbnail", isDir: true, modTime: modTime},
			fakeFileInfo{name: "notes.txt", size: 7, modTime: modTime},
		},
		"2026": {
			fakeFileInfo{name: "01", isDir: true, modTime: modTime},
			fakeFileInfo{name: "b.jpg", size: 13, modTime: modTime},
		},
	}

	// 根目录："" 拼写映射到驱动 Range(".")，.thumbnail 被隐藏，
	// 其余条目单层返回（含非媒体文件，客户端决定如何展示）。
	rec := doDirPost(a, "/__dir/list", `{"dir":""}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("list root: status %d body %q", rec.Code, rec.Body.String())
	}
	var resp dirListJSON
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode list response: %v", err)
	}
	if len(resp.Entries) != 3 {
		t.Fatalf("root entries = %+v, want 3 (.thumbnail hidden)", resp.Entries)
	}
	if resp.Entries[0].Name != "2026" || !resp.Entries[0].IsDir {
		t.Fatalf("entry[0] = %+v, want dir 2026", resp.Entries[0])
	}
	if resp.Entries[1].Name != "a.jpg" || resp.Entries[1].IsDir || resp.Entries[1].Size != 42 {
		t.Fatalf("entry[1] = %+v, want file a.jpg size 42", resp.Entries[1])
	}
	if !resp.Entries[2].ModTime.Equal(modTime) {
		t.Fatalf("entry[2] mod_time = %v, want %v", resp.Entries[2].ModTime, modTime)
	}
	if len(drive.rangeDirs) != 1 || drive.rangeDirs[0] != "." {
		t.Fatalf("rangeDirs = %v, want [\".\"]", drive.rangeDirs)
	}

	// 子目录：dir 原样传给驱动 Range，不递归（"01" 只出现一次，
	// 不展开其下内容）。
	rec = doDirPost(a, "/__dir/list", `{"dir":"2026"}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("list 2026: status %d body %q", rec.Code, rec.Body.String())
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode list response: %v", err)
	}
	if len(resp.Entries) != 2 || resp.Entries[0].Name != "01" || resp.Entries[1].Name != "b.jpg" {
		t.Fatalf("2026 entries = %+v, want [01 b.jpg]", resp.Entries)
	}
}

func TestDirListInvalidDirRejectedWithoutDriveAccess(t *testing.T) {
	a, drive := newDestTestAPI()
	for _, body := range []string{
		`{"dir":"../evil"}`,
		`{"dir":"a/../b"}`,
		`{"dir":".thumbnail"}`,
		`{"dir":".thumbnail/x"}`,
		`{"dir":"a\\b"}`,
		`{"dir":"/abs"}`,
	} {
		rec := doDirPost(a, "/__dir/list", body)
		if rec.Code != http.StatusBadRequest {
			t.Fatalf("list %s: status %d, want 400", body, rec.Code)
		}
	}
	if len(drive.rangeDirs) != 0 {
		t.Fatalf("invalid dirs reached drive Range: %v", drive.rangeDirs)
	}

	// 驱动错误透传为 400，不伪造空列表。
	drive.rangeErr = errTestDrive
	rec := doDirPost(a, "/__dir/list", `{"dir":"missing"}`)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("drive error: status %d, want 400", rec.Code)
	}
}

func TestDirListMethodNotAllowed(t *testing.T) {
	a, _ := newDestTestAPI()
	req := httptest.NewRequest(http.MethodGet, "/__dir/list", nil)
	rec := httptest.NewRecorder()
	a.HttpHandler().ServeHTTP(rec, req)
	if rec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("GET /__dir/list: status %d, want 405", rec.Code)
	}
	if rec.Header().Get("Allow") != "POST" {
		t.Fatalf("Allow = %q, want POST", rec.Header().Get("Allow"))
	}
}

func TestDirMkdir(t *testing.T) {
	a, drive := newDestTestAPI()

	rec := doDirPost(a, "/__dir/mkdir", `{"dir":"trips/2026"}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("mkdir: status %d body %q", rec.Code, rec.Body.String())
	}
	var okResp struct {
		OK bool `json:"ok"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &okResp); err != nil || !okResp.OK {
		t.Fatalf("mkdir response = %q, want {\"ok\":true}", rec.Body.String())
	}
	if len(drive.mkdirDirs) != 1 || drive.mkdirDirs[0] != "trips/2026" {
		t.Fatalf("mkdirDirs = %v, want [trips/2026]", drive.mkdirDirs)
	}

	// 根目录（""）直接成功，不调驱动。
	rec = doDirPost(a, "/__dir/mkdir", `{"dir":""}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("mkdir root: status %d body %q", rec.Code, rec.Body.String())
	}
	if len(drive.mkdirDirs) != 1 {
		t.Fatalf("mkdirDirs after root = %v, want unchanged", drive.mkdirDirs)
	}

	// 非法 dir：400 且驱动一次都不调到。
	for _, body := range []string{`{"dir":"../evil"}`, `{"dir":".thumbnail"}`} {
		rec = doDirPost(a, "/__dir/mkdir", body)
		if rec.Code != http.StatusBadRequest {
			t.Fatalf("mkdir %s: status %d, want 400", body, rec.Code)
		}
	}
	if len(drive.mkdirDirs) != 1 {
		t.Fatalf("mkdirDirs after invalid = %v, want unchanged", drive.mkdirDirs)
	}
}

func TestDirMkdirMalformedBody(t *testing.T) {
	a, drive := newDestTestAPI()
	rec := doDirPost(a, "/__dir/mkdir", `not json`)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("malformed body: status %d, want 400", rec.Code)
	}
	if len(drive.mkdirDirs) != 0 {
		t.Fatalf("mkdirDirs = %v, want empty", drive.mkdirDirs)
	}
}

func TestUploadExactDestDirHeader(t *testing.T) {
	a, drive := newDestTestAPI()
	date := "2026:01:02 15:04:05"

	// 精确模式：照片/视频直接落在 DestDir 下，不按类型分子目录。
	rec := doUpload(a, http.MethodPost, "/IMG_0001.jpg", []byte("data"), map[string]string{
		"Image-Date":       date,
		"Image-Dest-Dir":   "mydir",
		"Image-Dest-Exact": "1",
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("exact photo upload: status %d body %q", rec.Code, rec.Body.String())
	}
	rec = doUpload(a, http.MethodPost, "/VID_0001.mp4", []byte("data"), map[string]string{
		"Image-Date":       date,
		"Image-Dest-Dir":   "mydir",
		"Image-Dest-Exact": "1",
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("exact video upload: status %d body %q", rec.Code, rec.Body.String())
	}
	// Live 伴生视频：live_ 子目录规则不变，仍相对于 DestDir。
	rec = doUpload(a, http.MethodPost, "/live/VID_0001.mp4", []byte("data"), map[string]string{
		"Image-Date":       date,
		"Image-Dest-Dir":   "mydir",
		"Image-Dest-Exact": "1",
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("exact live video upload: status %d body %q", rec.Code, rec.Body.String())
	}
	// 缩略图镜像：.thumbnail 前缀 + 精确 dest 路径。
	rec = doUpload(a, http.MethodPost, "/thumbnail/IMG_0001.jpg", []byte("thumb"), map[string]string{
		"Image-Date":       date,
		"Image-Dest-Dir":   "mydir",
		"Image-Dest-Exact": "1",
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("exact thumbnail upload: status %d body %q", rec.Code, rec.Body.String())
	}
	// 精确模式 + 日期形状目录：合法（浏览路径校验允许日期段）。
	rec = doUpload(a, http.MethodPost, "/IMG_0002.jpg", []byte("data"), map[string]string{
		"Image-Date":       date,
		"Image-Dest-Dir":   "2026/01/02",
		"Image-Dest-Exact": "1",
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("exact date-dir upload: status %d body %q", rec.Code, rec.Body.String())
	}
	// 精确模式 + 根目录：DestDir 为空时直接落在根目录。
	rec = doUpload(a, http.MethodPost, "/IMG_0003.jpg", []byte("data"), map[string]string{
		"Image-Date":       date,
		"Image-Dest-Exact": "1",
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("exact root upload: status %d body %q", rec.Code, rec.Body.String())
	}

	want := []string{
		"mydir/20260102030405_IMG_0001.jpg",
		"mydir/20260102030405_VID_0001.mp4",
		"mydir/live_20260102030405_VID_0001/20260102030405_VID_0001.mp4",
		".thumbnail/mydir/20260102030405_IMG_0001.jpg",
		"2026/01/02/20260102030405_IMG_0002.jpg",
		"20260102030405_IMG_0003.jpg",
	}
	if len(drive.paths) != len(want) {
		t.Fatalf("uploaded paths = %v, want %v", drive.paths, want)
	}
	for i, w := range want {
		if drive.paths[i] != w {
			t.Fatalf("path[%d] = %q, want %q", i, drive.paths[i], w)
		}
	}

	// 精确模式 + 非法 dest：400 且零写入。
	rec = doUpload(a, http.MethodPost, "/IMG_0004.jpg", []byte("data"), map[string]string{
		"Image-Date":       date,
		"Image-Dest-Dir":   "../evil",
		"Image-Dest-Exact": "1",
	})
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("exact traversal dest: status %d, want 400", rec.Code)
	}
	if len(drive.paths) != len(want) {
		t.Fatalf("paths after rejected upload = %v, want unchanged", drive.paths)
	}
}
