package imgmanager

// ImageMetadata 是 Image 结构内嵌的元数据字段集合。
// 注意：EXIF 提取（原 GetImageMetadata）已删除——没有任何调用方读取这些
// 字段，保留结构体只是为了不改变 Image 的字段布局；字段始终为空。
type ImageMetadata struct {
	Model            string
	Datetime         string
	CreateDate       string
	DateTimeOriginal string
	ModifyDate       string
}
