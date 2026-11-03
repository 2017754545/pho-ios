package api

import (
	"bytes"
	"io"
	"io/fs"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/fregie/img_syncer/server/imgmanager"
)

// recordingDrive 记录 Upload 收到路径的 StorageDrive，用于验证
// Image-Dest-Dir 头是否落到存储路径上。
type recordingDrive struct {
	paths []string
}

func (d *recordingDrive) Upload(path string, content io.ReadCloser, size int64, modTime time.Time) error {
	d.paths = append(d.paths, path)
	_, err := io.Copy(io.Discard, content)
	return err
}
func (d *recordingDrive) IsExist(path string) (bool, error) { return false, nil }
func (d *recordingDrive) Download(path string) (io.ReadCloser, int64, error) {
	return io.NopCloser(bytes.NewReader(nil)), 0, nil
}
func (d *recordingDrive) DownloadWithOffset(path string, offset int64) (io.ReadCloser, int64, error) {
	return io.NopCloser(bytes.NewReader(nil)), 0, nil
}
func (d *recordingDrive) Delete(path string) error { return nil }
func (d *recordingDrive) Range(dir string, deal func(fs.FileInfo) bool) error {
	return nil
}
func (d *recordingDrive) Close() error { return nil }

func newDestTestAPI() (*api, *recordingDrive) {
	drive := &recordingDrive{}
	im := imgmanager.NewImgManager(imgmanager.Option{WorkerNum: 1})
	im.SetDrive(drive)
	a := NewApi(im)
	a.SetHttpPort(0)
	return a, drive
}

func doUpload(a *api, method, url string, body []byte, headers map[string]string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, url, bytes.NewReader(body))
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	rec := httptest.NewRecorder()
	a.HttpHandler().ServeHTTP(rec, req)
	return rec
}

func TestUploadDestDirHeader(t *testing.T) {
	a, drive := newDestTestAPI()
	date := "2026:01:02 15:04:05"

	// 照片进 image/，视频进 video/，均不带日期目录。
	rec := doUpload(a, http.MethodPost, "/IMG_0001.jpg", []byte("data"), map[string]string{
		"Image-Date":     date,
		"Image-Dest-Dir": "manual",
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("photo upload: status %d body %q", rec.Code, rec.Body.String())
	}
	rec = doUpload(a, http.MethodPost, "/VID_0001.mp4", []byte("data"), map[string]string{
		"Image-Date":     date,
		"Image-Dest-Dir": "manual",
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("video upload: status %d body %q", rec.Code, rec.Body.String())
	}
	// Live 视频进 image/live_ 子目录，不进 video/。
	rec = doUpload(a, http.MethodPost, "/live/VID_0001.mp4", []byte("data"), map[string]string{
		"Image-Date":     date,
		"Image-Dest-Dir": "manual",
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("live video upload: status %d body %q", rec.Code, rec.Body.String())
	}
	// 缩略图镜像同样带 dest/type 前缀。
	rec = doUpload(a, http.MethodPost, "/thumbnail/IMG_0001.jpg", []byte("thumb"), map[string]string{
		"Image-Date":     date,
		"Image-Dest-Dir": "manual",
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("thumbnail upload: status %d body %q", rec.Code, rec.Body.String())
	}

	want := []string{
		"manual/image/20260102030405_IMG_0001.jpg",
		"manual/video/20260102030405_VID_0001.mp4",
		"manual/image/live_20260102030405_VID_0001/20260102030405_VID_0001.mp4",
		".thumbnail/manual/image/20260102030405_IMG_0001.jpg",
	}
	if len(drive.paths) != len(want) {
		t.Fatalf("uploaded paths = %v, want %v", drive.paths, want)
	}
	for i, w := range want {
		if drive.paths[i] != w {
			t.Fatalf("path[%d] = %q, want %q", i, drive.paths[i], w)
		}
	}
}

func TestUploadDestDirHeaderInvalidRejected(t *testing.T) {
	a, drive := newDestTestAPI()
	rec := doUpload(a, http.MethodPost, "/IMG_0001.jpg", []byte("data"), map[string]string{
		"Image-Date":     "2026:01:02 15:04:05",
		"Image-Dest-Dir": "../evil",
	})
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("traversal dest: status %d, want 400", rec.Code)
	}
	if len(drive.paths) != 0 {
		t.Fatalf("rejected upload still wrote: %v", drive.paths)
	}
}

func TestUploadWithoutDestDirKeepsDateLayout(t *testing.T) {
	a, drive := newDestTestAPI()
	rec := doUpload(a, http.MethodPost, "/IMG_0001.jpg", []byte("data"), map[string]string{
		"Image-Date": "2026:01:02 15:04:05",
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("upload: status %d body %q", rec.Code, rec.Body.String())
	}
	if len(drive.paths) != 1 || drive.paths[0] != "2026/01/02/20260102030405_IMG_0001.jpg" {
		t.Fatalf("paths = %v", drive.paths)
	}
}
