package nfs

import (
	"strings"
	"testing"
)

// I-15: SetRootPath 在触网/重连前拒绝含 ".." 的根路径，且不 panic。
func TestSetRootPathRejectsTraversalWithoutNetwork(t *testing.T) {
	d := &Nfs{cli: nil, host: "127.0.0.1", target: "share"}
	for _, p := range []string{"../etc", "a/../../b", "/../etc"} {
		panicked := false
		var err error
		func() {
			defer func() {
				if r := recover(); r != nil {
					panicked = true
				}
			}()
			err = d.SetRootPath(p)
		}()
		if panicked {
			t.Fatalf("SetRootPath(%q) panicked", p)
		}
		if err == nil || !strings.Contains(err.Error(), "traversal") {
			t.Errorf("SetRootPath(%q): got %v, want traversal error", p, err)
		}
	}
	if d.IsRootPathSet() {
		t.Error("rejected SetRootPath must not set rootPath")
	}
}
