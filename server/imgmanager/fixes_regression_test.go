package imgmanager

import (
	"bytes"
	"encoding/binary"
	"errors"
	"io"
	"sync"
	"testing"
	"time"
)

// =============================================================================
// I-01: GCM header chunkSize 校验（0 除零 panic / 超大分配）
// =============================================================================

func TestValidateGCMChunkSize(t *testing.T) {
	if err := validateGCMChunkSize(0); err == nil {
		t.Error("chunkSize 0 must be rejected")
	}
	if err := validateGCMChunkSize(gcmChunkSize); err != nil {
		t.Errorf("writer chunkSize must be accepted: %v", err)
	}
	if err := validateGCMChunkSize(maxGCMChunkSize); err != nil {
		t.Errorf("cap value must be accepted: %v", err)
	}
	if err := validateGCMChunkSize(maxGCMChunkSize + 1); err == nil {
		t.Error("chunkSize over cap must be rejected")
	}
}

// craftedGcmFile 构造只有 header 的伪造 GCM 文件：magic + salt + chunkSize。
func craftedGcmFile(chunkSize uint32) []byte {
	buf := make([]byte, gcmHeaderLen)
	copy(buf[0:gcmMagicLen], []byte(gcmMagic))
	binary.BigEndian.PutUint32(buf[gcmMagicLen+gcmSaltLen:], chunkSize)
	return buf
}

func newImgManagerWithMock(t *testing.T, md *mockDrive) *ImgManager {
	t.Helper()
	im := NewImgManager(Option{WorkerNum: 1})
	t.Cleanup(func() { im.Close() })
	im.dri = md
	return im
}

func TestGetOffsetRejectsZeroChunkSizeWithoutPanic(t *testing.T) {
	md := newMockDrive()
	md.files["2023/01/01/x.jpg.aes"] = craftedGcmFile(0)
	im := newImgManagerWithMock(t, md)

	panicked := false
	var err error
	func() {
		defer func() {
			if r := recover(); r != nil {
				panicked = true
			}
		}()
		_, err = im.GetOffset("2023/01/01/x.jpg.aes", 0, WithEncrypt(EncryptOption{Type: AES_256_GCM, Password: "pw"}))
	}()
	if panicked {
		t.Fatal("GetOffset panicked on chunkSize==0 header (divide by zero)")
	}
	if err == nil {
		t.Fatal("GetOffset must reject chunkSize==0 header")
	}
}

func TestGetOffsetRejectsOversizedChunkSize(t *testing.T) {
	md := newMockDrive()
	md.files["2023/01/01/x.jpg.aes"] = craftedGcmFile(maxGCMChunkSize + 1)
	im := newImgManagerWithMock(t, md)

	_, err := im.GetOffset("2023/01/01/x.jpg.aes", 0, WithEncrypt(EncryptOption{Type: AES_256_GCM, Password: "pw"}))
	if err == nil {
		t.Fatal("GetOffset must reject chunkSize over cap")
	}
}

func TestGetLiveVideoOffsetRejectsZeroChunkSize(t *testing.T) {
	md := newMockDrive()
	dir := "2023/01/01/live_IMG_0001"
	md.rangeFiles[dir] = []mockDirEntry{{name: "IMG_0001.mp4.aes", size: 100}}
	md.files[dir+"/IMG_0001.mp4.aes"] = craftedGcmFile(0)
	im := newImgManagerWithMock(t, md)

	_, err := im.GetLiveVideoOffset(dir+"/IMG_0001.jpg", 0, WithEncrypt(EncryptOption{Type: AES_256_GCM, Password: "pw"}))
	if err == nil {
		t.Fatal("GetLiveVideoOffset must reject chunkSize==0 header")
	}
}

func TestChunkedGcmReaderRejectsBadChunkSize(t *testing.T) {
	for _, cs := range []uint32{0, maxGCMChunkSize + 1} {
		_, err := DecryptedReaderWraper(io.NopCloser(bytes.NewReader(craftedGcmFile(cs))),
			EncryptOption{Type: AES_256_GCM, Password: "pw"})
		if err == nil {
			t.Errorf("chunked GCM reader must reject chunkSize %d", cs)
		}
	}
}

func TestGcmSeekReaderRejectsOversizedChunkSize(t *testing.T) {
	_, err := NewGcmSeekReader(io.NopCloser(bytes.NewReader(nil)), "pw", GcmSeekOpts{
		ChunkSize: maxGCMChunkSize + 1,
		Salt:      make([]byte, gcmSaltLen),
	})
	if err == nil {
		t.Error("NewGcmSeekReader must reject chunkSize over cap")
	}
}

// =============================================================================
// I-18/I-28: 截断尺寸钳制 + header chunkSize 换算
// =============================================================================

func TestDecryptedContentSizeNeverNegative(t *testing.T) {
	cases := []struct {
		size int64
		typ  EncryptType
	}{
		{0, AES_128_CFB}, {10, AES_128_CFB}, {cfbIVLen, AES_128_CFB},
		{0, AES_256_GCM}, {10, AES_256_GCM}, {gcmHeaderLen, AES_256_GCM},
		{gcmHeaderLen + 1, AES_256_GCM}, {-5, AES_256_GCM}, {-5, None},
	}
	for _, c := range cases {
		if got := DecryptedContentSize(c.size, c.typ); got < 0 {
			t.Errorf("DecryptedContentSize(%d, %v) = %d, must never be negative", c.size, c.typ, got)
		}
	}
	// 恰好只有 IV/header 时明文为 0。
	if got := DecryptedContentSize(cfbIVLen, AES_128_CFB); got != 0 {
		t.Errorf("CFB overhead-only size: got %d, want 0", got)
	}
	if got := DecryptedContentSize(gcmHeaderLen, AES_256_GCM); got != 0 {
		t.Errorf("GCM header-only size: got %d, want 0", got)
	}
}

func TestDecryptedContentSizeWithChunkSize(t *testing.T) {
	// 明文 600 KiB、512 KiB 分块：2 块，开销 = 24 + 2*28。
	const chunkSize = 512 * 1024
	plain := int64(600 * 1024)
	stored := plain + gcmHeaderLen + 2*int64(gcmNonceSize+gcmTagSize)
	if got := DecryptedContentSizeWithChunkSize(stored, AES_256_GCM, chunkSize); got != plain {
		t.Errorf("WithChunkSize: got %d, want %d", got, plain)
	}
	// 常量版本按 1 MiB 分块换算，同一存储大小会算出不同结果——
	// 这正是 header chunkSize 必须传入的原因（两者分歧即 bug 表现）。
	if got := DecryptedContentSize(stored, AES_256_GCM); got == plain {
		t.Errorf("constant-size version unexpectedly equals header-size version for foreign chunk size")
	}
	if got := DecryptedContentSizeWithChunkSize(stored, AES_256_GCM, 0); got < 0 {
		t.Errorf("zero chunkSize must fall back to constant, got %d", got)
	}
}

// =============================================================================
// I-08/I-27: 加密 Live Video 发现 + Content-Type 统一
// =============================================================================

func TestGetLiveVideoOffsetFindsEncryptedVideo(t *testing.T) {
	md := newMockDrive()
	dir := "2023/01/01/live_IMG_0001"
	// 100 字节非 PHO1 内容：CFB 旧格式，空口令时解密直通。
	content := bytes.Repeat([]byte("B"), 100)
	md.rangeFiles[dir] = []mockDirEntry{{name: "IMG_0001.mp4.aes", size: int64(len(content))}}
	md.files[dir+"/IMG_0001.mp4.aes"] = content
	im := newImgManagerWithMock(t, md)

	img, err := im.GetLiveVideoOffset(dir+"/IMG_0001.jpg", 0)
	if err != nil {
		t.Fatalf("GetLiveVideoOffset must find xxx.mp4.aes: %v", err)
	}
	defer img.Content.Close()
	if img.ContentType != "video/mp4" {
		t.Errorf("ContentType: got %q, want %q", img.ContentType, "video/mp4")
	}
}

func TestGetImgAesContentType(t *testing.T) {
	md := newMockDrive()
	md.files["2023/01/01/IMG.jpg.aes"] = bytes.Repeat([]byte("A"), 100)
	im := newImgManagerWithMock(t, md)

	img, err := im.GetImg("2023/01/01/IMG.jpg.aes")
	if err != nil {
		t.Fatalf("GetImg: %v", err)
	}
	defer img.Content.Close()
	if img.ContentType != "image/jpeg" {
		t.Errorf("ContentType: got %q, want %q", img.ContentType, "image/jpeg")
	}
	if img.Size != 100-cfbIVLen {
		t.Errorf("Size: got %d, want %d", img.Size, 100-cfbIVLen)
	}
}

// =============================================================================
// I-20: Close 幂等 + 排空待删除队列
// =============================================================================

func TestCloseIdempotentAndDrainsPendingDeletes(t *testing.T) {
	md := newMockDrive()
	im := NewImgManager(Option{WorkerNum: 1})
	im.dri = md

	im.DeleteSingleImgAsync("2023/01/01/x.jpg")
	if err := im.Close(); err != nil {
		t.Fatalf("first Close: %v", err)
	}
	found := false
	for _, c := range md.deleteCalls {
		if c == "2023/01/01/x.jpg" {
			found = true
		}
	}
	if !found {
		t.Errorf("pending async delete was dropped by Close; deleteCalls=%v", md.deleteCalls)
	}
	// 第二次 Close 不得 panic。
	panicked := false
	func() {
		defer func() {
			if r := recover(); r != nil {
				panicked = true
			}
		}()
		_ = im.Close()
	}()
	if panicked {
		t.Fatal("second Close panicked")
	}
	// Close 后入队不得阻塞。
	done := make(chan struct{})
	go func() {
		im.DeleteSingleImgAsync("2023/01/01/y.jpg")
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("DeleteSingleImgAsync blocked after Close")
	}
}

// =============================================================================
// I-23: 有效日期归一
// =============================================================================

func TestEffectiveFileDate(t *testing.T) {
	before := time.Now()
	if got := EffectiveFileDate(time.Time{}); got.Before(before) || got.After(time.Now().Add(time.Second)) {
		t.Errorf("zero date must fall back to now, got %v", got)
	}
	if got := EffectiveFileDate(time.Date(1980, 5, 4, 0, 0, 0, 0, time.UTC)); got.Year() != time.Now().Year() {
		t.Errorf("pre-1990 date must fall back to now, got %v", got)
	}
	want := time.Date(2023, 6, 7, 8, 9, 10, 0, time.UTC)
	if got := EffectiveFileDate(want); !got.Equal(want) {
		t.Errorf("normal date must be unchanged: got %v, want %v", got, want)
	}
}

// =============================================================================
// I-25: 同名同秒并发上传 last-writer-wins（无竞态、无错误）
// =============================================================================

func TestConcurrentSameFileUploadsLastWriterWins(t *testing.T) {
	md := newMockDrive()
	im := newImgManagerWithMock(t, md)
	date := time.Date(2023, 1, 1, 10, 0, 0, 0, time.Local)

	const n = 8
	contents := make([][]byte, n)
	for i := range contents {
		contents[i] = bytes.Repeat([]byte{byte('a' + i)}, 64)
	}
	var wg sync.WaitGroup
	errs := make([]error, n)
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			errs[i] = im.Upload(bytes.NewReader(contents[i]), int64(len(contents[i])), "IMG_0001.jpg", date)
		}(i)
	}
	wg.Wait()
	for i, err := range errs {
		if err != nil {
			t.Errorf("upload %d failed: %v", i, err)
		}
	}
	stored, ok := md.files["2023/01/01/IMG_0001.jpg"]
	if !ok {
		t.Fatal("same-file concurrent upload stored nothing")
	}
	matched := false
	for _, c := range contents {
		if bytes.Equal(stored, c) {
			matched = true
		}
	}
	if !matched {
		t.Errorf("stored content %q matches none of the writers (torn write?)", stored[:8])
	}
}

// =============================================================================
// I-29: RangeByDate 零日期 / type-02 IsDir / 错误传播 / live_ 提前停止
// =============================================================================

func TestRangeByDateZeroDateMatches(t *testing.T) {
	md := newMockDrive()
	md.rangeFiles["."] = []mockDirEntry{
		{name: "20260718", isDir: true},
		{name: "20260719", isDir: true},
	}
	md.rangeFiles["20260718"] = []mockDirEntry{{name: "a.jpg", size: 10}}
	md.rangeFiles["20260719"] = []mockDirEntry{{name: "b.jpg", size: 10}}
	im := newImgManagerWithMock(t, md)

	var paths []string
	if err := im.RangeByDate(time.Time{}, func(info ImgInfo) bool {
		paths = append(paths, info.Path)
		return true
	}); err != nil {
		t.Fatalf("RangeByDate: %v", err)
	}
	if len(paths) != 2 {
		t.Fatalf("zero date must match past dirs, got %v", paths)
	}
}

func TestRangeByDateType02SkipsFiles(t *testing.T) {
	md := newMockDrive()
	md.rangeFiles["."] = []mockDirEntry{
		{name: "20260719", isDir: true},
		{name: "20260720", isDir: false}, // 8 字符文件，不得当作日期目录
	}
	md.rangeFiles["20260719"] = []mockDirEntry{{name: "a.jpg", size: 10}}
	md.rangeFiles["20260720"] = []mockDirEntry{{name: "should_not_appear.jpg", size: 10}}
	im := newImgManagerWithMock(t, md)

	var paths []string
	date := time.Date(2026, 7, 20, 0, 0, 0, 0, time.Local)
	if err := im.RangeByDate(date, func(info ImgInfo) bool {
		paths = append(paths, info.Path)
		return true
	}); err != nil {
		t.Fatalf("RangeByDate: %v", err)
	}
	if len(paths) != 1 || paths[0] != "20260719/a.jpg" {
		t.Fatalf("expected only 20260719/a.jpg, got %v", paths)
	}
}

func TestRangeByDatePropagatesRangeError(t *testing.T) {
	md := newMockDrive()
	md.rangeFiles["."] = []mockDirEntry{{name: "20260719", isDir: true}}
	md.rangeFiles["20260719"] = []mockDirEntry{{name: "a.jpg", size: 10}}
	md.rangeErr["20260719"] = errors.New("drive read boom")
	im := newImgManagerWithMock(t, md)

	date := time.Date(2026, 7, 20, 0, 0, 0, 0, time.Local)
	err := im.RangeByDate(date, func(info ImgInfo) bool { return true })
	if err == nil || err.Error() != "drive read boom" {
		t.Fatalf("RangeByDate must propagate inner Range error, got %v", err)
	}
}

func TestRangeByDatePropagatesLiveSubdirError(t *testing.T) {
	md := newMockDrive()
	md.rangeFiles["."] = []mockDirEntry{{name: "20260719", isDir: true}}
	md.rangeFiles["20260719"] = []mockDirEntry{{name: "live_IMG", isDir: true}}
	md.rangeErr["20260719/live_IMG"] = errors.New("live subdir boom")
	im := newImgManagerWithMock(t, md)

	date := time.Date(2026, 7, 20, 0, 0, 0, 0, time.Local)
	err := im.RangeByDate(date, func(info ImgInfo) bool { return true })
	if err == nil || err.Error() != "live subdir boom" {
		t.Fatalf("RangeByDate must propagate live_ subdir Range error, got %v", err)
	}
}

func TestRangeByDateLiveEarlyStopPropagates(t *testing.T) {
	md := newMockDrive()
	md.rangeFiles["."] = []mockDirEntry{{name: "20260719", isDir: true}}
	md.rangeFiles["20260719"] = []mockDirEntry{{name: "live_IMG", isDir: true}}
	md.rangeFiles["20260719/live_IMG"] = []mockDirEntry{
		{name: "IMG.mp4", size: 50},
		{name: "a.jpg", size: 10},
		{name: "b.jpg", size: 10},
	}
	im := newImgManagerWithMock(t, md)

	var paths []string
	date := time.Date(2026, 7, 20, 0, 0, 0, 0, time.Local)
	if err := im.RangeByDate(date, func(info ImgInfo) bool {
		paths = append(paths, info.Path)
		return false // 提前停止
	}); err != nil {
		t.Fatalf("RangeByDate: %v", err)
	}
	if len(paths) != 1 {
		t.Fatalf("early stop must propagate into live_ subdir, got %d paths: %v", len(paths), paths)
	}
}
