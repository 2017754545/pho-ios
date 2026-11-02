package util

import (
	"fmt"
	"path"
	"strings"
)

// CleanDirPath 校验并规范化一个由客户端传入的目录参数（ListDrive*Dir 的
// Dir、SetRootPath 的 root 等），防止 `..` 逃出共享/挂载根目录。
// 与 api.sanitizePath 不同：根目录的两种拼写 "." 与 "/" 是合法输入，
// 原样保留（"." 保留 "."，"/" 保留 "/"）；空字符串由调用方先行默认化，
// 这里同样接受并返回 "."。NFS/WebDAV 浏览传入的绝对拼写（"/photos/2022/"，
// 以导出根为界）同样合法并保留。
// 拒绝：反斜杠、原始路径中的任何 ".." 元素（即使 Clean 后会折叠回界内，
// 如 "/../etc"——目录浏览 UI 从不产生 ".." 段，严格拒绝无合法误伤）。
func CleanDirPath(p string) (string, error) {
	if p == "" {
		return ".", nil
	}
	if strings.Contains(p, "\\") {
		return "", fmt.Errorf("invalid path separator: %s", p)
	}
	if HasDotDotElement(p) {
		return "", fmt.Errorf("path traversal not allowed: %s", p)
	}
	// 统一用斜杠语义处理：驱动层路径均为类 POSIX 形式。
	slash := path.Clean(p)
	if slash == ".." || strings.HasPrefix(slash, "../") || strings.Contains(slash, "/../") {
		return "", fmt.Errorf("path traversal not allowed: %s", p)
	}
	return slash, nil
}

// CleanShareName 校验共享名：必须是单个名称元素，不得包含路径分隔符
// 或 ".."，否则 ListDrive*Dir / SetShare 可能越过目标共享。
func CleanShareName(share string) (string, error) {
	if share == "" {
		return "", fmt.Errorf("share name is empty")
	}
	if strings.ContainsAny(share, "/\\") || share == "." || share == ".." || strings.Contains(share, "..") {
		return "", fmt.Errorf("invalid share name: %s", share)
	}
	return share, nil
}

// HasDotDotElement 报告路径中是否存在 ".." 元素（用于根路径校验前置检查）。
func HasDotDotElement(p string) bool {
	for _, el := range strings.Split(strings.ReplaceAll(p, "\\", "/"), "/") {
		if el == ".." {
			return true
		}
	}
	return false
}
