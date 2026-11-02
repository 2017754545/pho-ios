package webdav

import (
	"bytes"
	"io"
	"strings"
	"testing"
)

// I-15: SetRootPath 在发请求前拒绝含 ".." 的根路径。
func TestSetRootPathRejectsTraversalWithoutNetwork(t *testing.T) {
	d := NewWebdavDrive("http://127.0.0.1:1", "", "", false)
	for _, p := range []string{"../etc", "a/../../b", "/../etc"} {
		if err := d.SetRootPath(p); err == nil || !strings.Contains(err.Error(), "traversal") {
			t.Errorf("SetRootPath(%q): got %v, want traversal error", p, err)
		}
	}
	if d.IsRootPathSet() {
		t.Error("rejected SetRootPath must not set rootPath")
	}
}

// I-12: offset==size 返回空流与总大小；offset>size 报错。
func TestDownloadWithOffsetAtAndBeyondSize(t *testing.T) {
	content := bytes.Repeat([]byte("hello"), 100) // 500 bytes
	stub := newWebdavStub(t, content)
	stub.addFile("/storage/test.txt", content)
	d := NewWebdavDrive(stub.URL(), "", "", false)
	if err := d.SetRootPath("storage"); err != nil {
		t.Fatalf("SetRootPath: %v", err)
	}

	// offset == size：空流 + 总大小。
	reader, size, err := d.DownloadWithOffset("test.txt", int64(len(content)))
	if err != nil {
		t.Fatalf("offset==size: %v", err)
	}
	data, err := io.ReadAll(reader)
	if err != nil {
		t.Fatalf("ReadAll: %v", err)
	}
	reader.Close()
	if size != int64(len(content)) {
		t.Errorf("size: got %d, want %d", size, len(content))
	}
	if len(data) != 0 {
		t.Errorf("offset==size must return empty stream, got %d bytes", len(data))
	}

	// offset > size：错误。
	_, _, err = d.DownloadWithOffset("test.txt", int64(len(content))+1)
	if err == nil {
		t.Fatal("offset>size must return error")
	}
	if !strings.Contains(err.Error(), "bigger than file size") {
		t.Errorf("offset>size error: got %v", err)
	}
}
