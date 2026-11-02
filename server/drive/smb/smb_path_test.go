package smb

import (
	"testing"
)

// I-15: SetRootPath / SetShare 在触网前拒绝遍历路径。
func TestSetRootPathRejectsTraversalWithoutNetwork(t *testing.T) {
	s := &Smb{}
	for _, p := range []string{"../etc", "a/../../b", "/../etc", `..\etc`} {
		if err := s.SetRootPath(p); err == nil {
			t.Errorf("SetRootPath(%q): expected rejection, got nil", p)
		}
	}
	if s.IsRootPathSet() {
		t.Error("rejected SetRootPath must not set rootPath")
	}
}

func TestSetShareRejectsTraversalWithoutNetwork(t *testing.T) {
	s := &Smb{}
	for _, name := range []string{"..", "a/b", `a\b`} {
		if err := s.SetShare(name); err == nil {
			t.Errorf("SetShare(%q): expected error, got nil", name)
		}
	}
}
