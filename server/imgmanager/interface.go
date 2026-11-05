package imgmanager

import (
	"errors"
	"io"
	"io/fs"
	"time"
)

type StorageDrive interface {
	// Upload 写入 path。size 是声明的字节数，仅供参考（advisory）：
	// SMB 与 NFS 驱动忽略它、读到 EOF 为止，WebDAV 驱动用它设置
	// Content-Length；长度校验由调用方（ImgManager 的 sizeCheckReader）
	// 在流式读取时完成，驱动不得依赖 size 强制截断或补齐。
	Upload(string, io.ReadCloser, int64, time.Time) error
	IsExist(path string) (bool, error)
	Download(path string) (io.ReadCloser, int64, error)
	DownloadWithOffset(path string, offset int64) (io.ReadCloser, int64, error)
	Delete(path string) error
	Range(dir string, deal func(fs.FileInfo) bool) error
	// MkdirAll 创建 dir（相对于驱动根目录，"" 或 "." 表示根目录，已
	// 存在时成功）及其全部不存在的父目录。ListDir/MkdirDir 浏览端点
	// 用它创建用户在“文件”页签新建的文件夹。
	MkdirAll(dir string) error
	Close() error
}

type Image struct {
	Content     io.ReadCloser
	Path        string
	Size        int64
	ContentType string
	ImageMetadata
}

const (
	// ContentTypeJpeg = "image/jpeg"
	// ContentTypePng  = "image/png"
	// ContentTypeGif  = "image/gif"

	JpegSuffix = ".jpg"
	PngSuffix  = ".png"
	DngSuffix  = ".dng"
)

type UnimplementedDrive struct{}

func (d *UnimplementedDrive) Upload(_ string, _ io.ReadCloser, _ int64, _ time.Time) error {
	return errors.New("no available drive")
}

func (d *UnimplementedDrive) IsExist(path string) (bool, error) {
	return false, errors.New("no available drive")
}

func (d *UnimplementedDrive) Download(path string) (io.ReadCloser, int64, error) {
	return nil, 0, errors.New("no available drive")
}

func (d *UnimplementedDrive) DownloadWithOffset(path string, offset int64) (io.ReadCloser, int64, error) {
	return nil, 0, errors.New("no available drive")
}

func (d *UnimplementedDrive) Delete(path string) error {
	return errors.New("no available drive")
}

func (d *UnimplementedDrive) Range(dir string, deal func(fs.FileInfo) bool) error {
	return errors.New("no available drive")
}

func (d *UnimplementedDrive) MkdirAll(dir string) error {
	return errors.New("no available drive")
}

func (d *UnimplementedDrive) Close() error {
	return nil
}
