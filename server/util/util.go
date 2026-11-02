package util

import (
	"mime"
	"path/filepath"
	"strings"
)

// StripAesSuffix 去掉加密文件名的 .aes 后缀（不区分大小写），
// 其余名称原样返回。加密视频存为 xxx.mp4.aes，判断视频类型与
// 比较无后缀文件名时都必须先剥离它。
func StripAesSuffix(name string) string {
	if len(name) > 4 && strings.EqualFold(name[len(name)-4:], ".aes") {
		return name[:len(name)-4]
	}
	return name
}

func IsVideo(name string) bool {
	ext := filepath.Ext(StripAesSuffix(name))
	switch strings.ToLower(ext) {
	case ".mp4", ".avi", ".rmvb", ".rm", ".flv", ".wmv", ".mkv", ".mov", ".mpg", ".mpeg", ".3gp", ".3g2", ".asf", ".asx", ".vob", ".m2ts", ".mts", ".ts":
		return true
	}
	return false
}

// ContentTypeByExtension 是全项目唯一的 Content-Type 解析器。
// 显式映射表优先于系统 mime 表：系统表的 .heic 等条目因平台而异
// （如本机返回 image/heif），显式表保证各平台结果一致。
func ContentTypeByExtension(ext string) string {
	ext = strings.ToLower(ext)
	if t, ok := defaultMimeMap[ext]; ok {
		return t
	}
	return mime.TypeByExtension(ext)
}

var defaultMimeMap = map[string]string{
	".bmp":  "image/bmp",
	".gif":  "image/gif",
	".heic": "image/heic",
	".heif": "image/heif",
	".dng":  "image/x-adobe-dng",
	".jpeg": "image/jpeg",
	".jpg":  "image/jpeg",
	".png":  "image/png",
	".tif":  "image/tiff",
	".tiff": "image/tiff",
	".webp": "image/webp",
	".ico":  "image/x-icon",
	".svg":  "image/svg+xml",

	".avi":  "video/x-msvideo",
	".mkv":  "video/x-matroska",
	".mov":  "video/quicktime",
	".mp4":  "video/mp4",
	".mpeg": "video/mpeg",
	".ogv":  "video/ogg",
	".webm": "video/webm",
	".3gp":  "video/3gpp",
	".3g2":  "video/3gpp2",
}
