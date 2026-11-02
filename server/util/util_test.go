package util

import (
	"testing"
)

// I-27: Content-Type 统一解析器新增扩展名；I-08: IsVideo 剥离 .aes。
func TestContentTypeByExtension(t *testing.T) {
	cases := map[string]string{
		".heic": "image/heic",
		".heif": "image/heif",
		".dng":  "image/x-adobe-dng",
		".jpg":  "image/jpeg",
		".JPG":  "image/jpeg",
		".mp4":  "video/mp4",
		".xyz":  "",
	}
	for ext, want := range cases {
		if got := ContentTypeByExtension(ext); got != want {
			t.Errorf("ContentTypeByExtension(%q) = %q, want %q", ext, got, want)
		}
	}
}

func TestIsVideoStripsAesSuffix(t *testing.T) {
	if !IsVideo("IMG_0001.mp4.aes") {
		t.Error("IsVideo must treat .mp4.aes as video")
	}
	if IsVideo("IMG_0001.jpg.aes") {
		t.Error("IsVideo must not treat .jpg.aes as video")
	}
	if !IsVideo("IMG_0001.mp4") {
		t.Error("IsVideo must treat .mp4 as video")
	}
	if StripAesSuffix("a.mp4.aes") != "a.mp4" {
		t.Errorf("StripAesSuffix: got %q", StripAesSuffix("a.mp4.aes"))
	}
	if StripAesSuffix("a.mp4") != "a.mp4" {
		t.Errorf("StripAesSuffix must leave non-aes names alone, got %q", StripAesSuffix("a.mp4"))
	}
}

// I-15: 目录参数遍历校验，保留 "." 与 "/" 根拼写。
func TestCleanDirPath(t *testing.T) {
	keep := map[string]string{
		"":                ".",
		".":               ".",
		"/":               "/",
		"a/b":             "a/b",
		"a/./b":           "a/b",
		"/photos/2022/":   "/photos/2022",
		"/photos/2022":    "/photos/2022",
		"storage":         "storage",
		"storage/2022/11": "storage/2022/11",
	}
	for in, want := range keep {
		got, err := CleanDirPath(in)
		if err != nil {
			t.Errorf("CleanDirPath(%q) unexpected error: %v", in, err)
		} else if got != want {
			t.Errorf("CleanDirPath(%q) = %q, want %q", in, got, want)
		}
	}
	reject := []string{"..", "../x", "x/..", "a/../b", "a/../../b", "/../etc", "..\\x", `a\b`, "../", "x/..//y"}
	for _, in := range reject {
		if got, err := CleanDirPath(in); err == nil {
			t.Errorf("CleanDirPath(%q) = %q, want error", in, got)
		}
	}
}

func TestCleanShareName(t *testing.T) {
	if _, err := CleanShareName("photos"); err != nil {
		t.Errorf("CleanShareName(photos): %v", err)
	}
	for _, bad := range []string{"", ".", "..", "a/b", `a\b`, "a..b"} {
		if _, err := CleanShareName(bad); err == nil {
			t.Errorf("CleanShareName(%q) must fail", bad)
		}
	}
}
