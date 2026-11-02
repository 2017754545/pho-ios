package api_test

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/md5"
	"crypto/rand"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"

	pb "github.com/fregie/img_syncer/proto"
	"github.com/fregie/img_syncer/test/static"
	"github.com/hirochachacha/go-smb2"
	"github.com/stretchr/testify/suite"
	"google.golang.org/grpc"
)

// EncryptTestSuite 覆盖加密上传/下载的端到端集成测试（需要 Docker SMB 容器）。
type EncryptTestSuite struct {
	suite.Suite
	srv   pb.ImgSyncerClient
	share *smb2.Share
}

func TestEncryptTestSuite(t *testing.T) {
	suite.Run(t, new(EncryptTestSuite))
}

func (s *EncryptTestSuite) SetupTest() {
	err := cleanSmb()
	s.Nilf(err, "failed to clean smb share: %s", err)
	err = initSmbDir()
	s.Nilf(err, "failed to init smb dir: %s", err)
	grpcConn, err := grpc.Dial(grpcAddr, grpc.WithInsecure())
	s.Nil(err)
	s.srv = pb.NewImgSyncerClient(grpcConn)
	s.share, err = initSmbShare()
	s.Nil(err)
}

func (s *EncryptTestSuite) setupSmbDrive() {
	rsp, err := s.srv.SetDriveSMB(context.Background(), &pb.SetDriveSMBRequest{
		Addr:     smbSrvAddr,
		Username: smbUser,
		Password: smbPass,
		Share:    smbShare,
		Root:     smbRootDir,
	})
	s.Nil(err)
	s.True(rsp.Success)
}

// =============================================================================
// 加密上传 → HTTP 下载 round-trip
// =============================================================================

// TestEncryptRoundTripSMB 验证 legacy CFB 文件的解密 round-trip。
//
// 意图行为（以代码为准）：CFB 加密入口已在 EncryptedReaderWraper 中弃用
// 并在运行时拒绝（"CFB encryption is deprecated, use GCM"），因此 CFB
// 文件无法再经 HTTP 上传；但旧 CFB 文件的解密仍受支持（magic 检测
// fallback 到 CFB）。旧版测试经 HTTP 上传 CFB 并期望成功，与当前
// 拒绝逻辑矛盾，已按意图行为改写：先断言上传被拒绝，再直接在 share
// 上写入 legacy CFB 文件，验证 HTTP GET 解密 round-trip。
func (s *EncryptTestSuite) TestEncryptRoundTripSMB() {
	s.setupSmbDrive()

	original := static.Pic1
	password := "smb-roundtrip-pw"

	// CFB 加密上传必须被拒绝。
	_, err := s.uploadEncrypted("pic1.jpg", "2022:11:08 12:34:36", "AES_128_CFB", password)
	s.NotNilf(err, "CFB encrypted upload must be rejected, but it succeeded")

	// 直接在 share 上写入 legacy CFB 文件，验证解密 round-trip。
	encryptedPath := s.seedLegacyCfbFile("pic1.jpg", password, original)
	s.Nil(waitfile(s.srv, encryptedPath, 5*time.Second))

	// HTTP GET 下载（无 Range header → 走 GetImg 解密路径）
	downloaded, err := s.downloadEncrypted(encryptedPath, password)
	s.Nilf(err, "download failed: %v", err)

	if !bytes.Equal(downloaded, original) {
		s.Failf("encrypted round-trip mismatch",
			"downloaded %d bytes, original %d bytes", len(downloaded), len(original))
	}
}

// =============================================================================
// Range 请求在 .aes 文件上的行为
// =============================================================================

func (s *EncryptTestSuite) TestEncryptRejectsRangeOnAes() {
	s.setupSmbDrive()

	password := "range-reject-pw"

	// Legacy CFB 文件直接写入 share（CFB 上传已被拒绝，见 TestEncryptRoundTripSMB）。
	encryptedPath := s.seedLegacyCfbFile("pic1.jpg", password, static.Pic1)

	s.Nil(waitfile(s.srv, encryptedPath, 5*time.Second))

	// HTTP Range offset=1 应被拒绝（encrypted file not support get offset）
	url := fmt.Sprintf("http://%s/%s", httpAddr, encryptedPath)
	req, err := http.NewRequest(http.MethodGet, url, nil)
	s.Nil(err)
	req.Header.Set("Image-Encrypt-Type", "AES_128_CFB")
	req.Header.Set("Image-Encrypt-Password", password)
	req.Header.Set("Range", "bytes=1-100")

	resp, err := http.DefaultClient.Do(req)
	s.Nil(err)
	defer resp.Body.Close()

	// 期望返回 500（GetOffset 内部错误 "encrypted file not support get offset"）
	if resp.StatusCode != http.StatusInternalServerError && resp.StatusCode != http.StatusBadRequest {
		body, _ := io.ReadAll(resp.Body)
		s.Failf("unexpected status for Range on encrypted file",
			"expected 500 or 400, got %d, body: %s", resp.StatusCode, string(body))
	} else {
		body, _ := io.ReadAll(resp.Body)
		s.T().Logf("Range offset=1 on .aes correctly rejected with status %d: %s", resp.StatusCode, string(body))
	}
}

func (s *EncryptTestSuite) TestEncryptRangeZeroOnAes() {
	s.setupSmbDrive()

	original := static.Pic1
	password := "range-zero-pw"

	// Legacy CFB 文件直接写入 share（CFB 上传已被拒绝，见 TestEncryptRoundTripSMB）。
	encryptedPath := s.seedLegacyCfbFile("pic1.jpg", password, original)

	s.Nil(waitfile(s.srv, encryptedPath, 5*time.Second))

	// HTTP Range offset=0 应成功（内部走 GetImg 解密路径）
	url := fmt.Sprintf("http://%s/%s", httpAddr, encryptedPath)
	req, err := http.NewRequest(http.MethodGet, url, nil)
	s.Nil(err)
	req.Header.Set("Image-Encrypt-Type", "AES_128_CFB")
	req.Header.Set("Image-Encrypt-Password", password)
	req.Header.Set("Range", "bytes=0-")

	resp, err := http.DefaultClient.Do(req)
	s.Nil(err)
	defer resp.Body.Close()

	s.Equalf(http.StatusPartialContent, resp.StatusCode,
		"Range offset=0 on .aes failed with status %d", resp.StatusCode)

	body, err := io.ReadAll(resp.Body)
	s.Nil(err)

	if !bytes.Equal(body, original) {
		s.Failf("Range offset=0 on .aes content mismatch", "got %d bytes, want %d", len(body), len(original))
	}
}

// =============================================================================
// T10 预留：加密上传 Live Video 到 SMB（已有框架，T10 补充实现）
// =============================================================================

func (s *EncryptTestSuite) TestEncryptUploadLiveVideoOnSMB() {
	s.setupSmbDrive()

	liveVideoData := []byte("test live video content for encryption verification")
	req, err := http.NewRequest(http.MethodPost,
		fmt.Sprintf("http://%s/live/test_video", httpAddr),
		bytes.NewReader(liveVideoData))
	s.Nilf(err, "new request failed: %v", err)
	req.Header.Set("Content-Type", "video/mp4")
	req.Header.Set("Image-Date", "2022:11:08 12:34:36")
	req.Header.Set("Image-Is-Live-Photo", "true")
	// CFB 加密上传已被拒绝（见 TestEncryptRoundTripSMB 的意图说明），
	// 本测试改用当前支持的 GCM 加密上传 Live Video。
	req.Header.Set("Image-Encrypt-Type", "AES_256_GCM")
	req.Header.Set("Image-Encrypt-Password", "testpw")
	resp, err := http.DefaultClient.Do(req)
	s.Nilf(err, "upload live video failed: %v", err)
	s.Equal(http.StatusOK, resp.StatusCode)

	liveDir := "storage/2022/11/08/live_20221108123436_test_video"
	s.waitSmbDir(liveDir, 5*time.Second)

	entries, err := s.share.ReadDir(liveDir)
	s.Nilf(err, "failed to read live dir: %v", err)
	s.NotEmptyf(entries, "live dir should have files")

	foundAes := false
	for _, entry := range entries {
		if !entry.IsDir() {
			foundAes = true
			encryptedPath := liveDir + "/" + entry.Name()
			fdata, err := s.share.ReadFile(encryptedPath)
			s.Nilf(err, "failed to read encrypted file: %v", err)
			s.NotEqualf(liveVideoData, fdata, "encrypted file content should differ from plaintext")
			s.NotEmptyf(fdata, "encrypted file should not be empty")
		}
	}
	s.True(foundAes)
}

// =============================================================================
// 测试辅助方法
// =============================================================================

// uploadEncrypted 通过 HTTP POST 加密上传文件，返回编码后的文件名路径。
func (s *EncryptTestSuite) uploadEncrypted(name, dateLayout, encType, password string) (string, error) {
	url := fmt.Sprintf("http://%s/%s", httpAddr, name)
	req, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(static.Pic1))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "image/jpeg")
	req.Header.Set("Image-Date", dateLayout)
	req.Header.Set("Image-Encrypt-Type", encType)
	req.Header.Set("Image-Encrypt-Password", password)

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return "", fmt.Errorf("upload HTTP %d: %s", resp.StatusCode, string(body))
	}
	io.Copy(io.Discard, resp.Body)

	// 服务器端使用 DSCF_DIRECTORY_TYPE_01（默认），路径格式为：
	// "YYYY/MM/DD/YYYYMMDDhhmmss_name.aes"
	// encodeName 输出是 "20221108123436_pic1.jpg"，但 genPath 直接用原始 name
	// 所以实际路径是 "2022/11/08/20221108123436_pic1.jpg.aes"
	return "2022/11/08/20221108123436_" + name + ".aes", nil
}

// seedLegacyCfbFile 直接在 SMB share 上写入 legacy CFB 格式文件
// （CFB 加密上传已弃用，无法经 HTTP 得到此类文件；旧文件解密仍受
// 支持），返回编码后的文件名路径。
func (s *EncryptTestSuite) seedLegacyCfbFile(name, password string, plaintext []byte) string {
	cfbBlob := legacyCfbEncrypt(password, plaintext)
	dir := "storage/2022/11/08"
	err := s.share.MkdirAll(dir, os.ModePerm)
	s.Nilf(err, "mkdir failed: %v", err)
	smbPath := dir + "/20221108123436_" + name + ".aes"
	err = s.share.WriteFile(smbPath, cfbBlob, os.ModePerm)
	s.Nilf(err, "write cfb file failed: %v", err)
	return "2022/11/08/20221108123436_" + name + ".aes"
}

// downloadEncrypted 通过 HTTP GET 下载并解密文件。
func (s *EncryptTestSuite) downloadEncrypted(path, password string) ([]byte, error) {
	url := fmt.Sprintf("http://%s/%s", httpAddr, path)
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Image-Encrypt-Type", "AES_128_CFB")
	req.Header.Set("Image-Encrypt-Password", password)

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("download HTTP %d: %s", resp.StatusCode, string(body))
	}

	return io.ReadAll(resp.Body)
}

func (s *EncryptTestSuite) waitSmbDir(path string, timeout time.Duration) {
	start := time.Now()
	for {
		entries, err := s.share.ReadDir(path)
		if err == nil && len(entries) > 0 {
			return
		}
		if time.Since(start) > timeout {
			s.FailNowf("wait file timeout", "wait dir %s timeout", path)
		}
		time.Sleep(200 * time.Millisecond)
	}
}

// =============================================================================
// GCM 加密文件 Range 下载（T1/T2：支持任意 offset，跨块 seek）
// =============================================================================

// TestEncryptRangeOnGcmSMB 验证 AES_256_GCM 加密文件支持任意 offset 的 Range 下载：
// 上传 ≥3MB 明文（跨至少 3 个 1MB GCM chunk），Range: bytes=<mid>-<end> -> 206 + 明文字节级正确。
func (s *EncryptTestSuite) TestEncryptRangeOnGcmSMB() {
	s.setupSmbDrive()

	// 构造 ≥3MB 可识别明文：重复 "GCMRANGE_" 模式拼接，跨至少 3 个 GCM chunk（1MB/块）
	const plainSize = 3*1024*1024 + 1234
	pattern := []byte("GCMRANGE_")
	plaintext := make([]byte, plainSize)
	for i := range plaintext {
		plaintext[i] = pattern[i%len(pattern)]
	}
	password := "gcm-range-pw"

	encPath, err := s.uploadEncryptedBytes("gcm_range.dat", "2022:11:08 12:34:36", "AES_256_GCM", password, plaintext)
	s.Nilf(err, "GCM encrypted upload failed: %v", err)
	s.Nil(waitfile(s.srv, encPath, 10*time.Second))

	mid := int64(plainSize / 2)
	end := int64(plainSize) - 1
	url := fmt.Sprintf("http://%s/%s", httpAddr, encPath)
	req, err := http.NewRequest(http.MethodGet, url, nil)
	s.Nil(err)
	req.Header.Set("Image-Encrypt-Type", "AES_256_GCM")
	req.Header.Set("Image-Encrypt-Password", password)
	req.Header.Set("Range", fmt.Sprintf("bytes=%d-%d", mid, end))

	resp, err := http.DefaultClient.Do(req)
	s.Nil(err)
	defer resp.Body.Close()

	s.Equalf(http.StatusPartialContent, resp.StatusCode,
		"GCM Range expected 206, got %d", resp.StatusCode)

	body, err := io.ReadAll(resp.Body)
	s.Nil(err)
	expected := plaintext[mid : end+1]
	if !bytes.Equal(body, expected) {
		s.Failf("GCM Range body mismatch", "got %d bytes, want %d bytes", len(body), len(expected))
	}

	// Content-Range total 应等于明文总长（DecryptedContentSize(storedSize, GCM) == plainSize）
	cr := resp.Header.Get("Content-Range")
	s.Truef(strings.HasPrefix(cr, fmt.Sprintf("bytes %d-%d/%d", mid, end, plainSize)),
		"Content-Range mismatch: got %q, want prefix \"bytes %d-%d/%d\"", cr, mid, end, plainSize)
}

// TestEncryptRangeGcmLiveVideoSMB 验证 AES_256_GCM 加密的 Live Video 支持 Range 下载。
//
// I-08 修复后，GetLiveVideoOffset 通过 util.IsVideo（剥离 .aes 后缀后判
// 断）能发现 .aes 加密视频，因此 /live/ GET 路径与常规 GET 路径均可
// Range 下载加密 Live Video；本测试验证两条路径。
func (s *EncryptTestSuite) TestEncryptRangeGcmLiveVideoSMB() {
	s.setupSmbDrive()

	// 1.5MB 可识别明文，跨 2 个 GCM chunk
	const plainSize = 1024*1024 + 500*1024
	pattern := []byte("GCMLIVE_")
	plaintext := make([]byte, plainSize)
	for i := range plaintext {
		plaintext[i] = pattern[i%len(pattern)]
	}
	password := "gcm-live-pw"

	// /live/ 路径上传加密 Live Video，header Image-Encrypt-Type: AES_256_GCM
	uploadURL := fmt.Sprintf("http://%s/live/test_video.mp4", httpAddr)
	uploadReq, err := http.NewRequest(http.MethodPost, uploadURL, bytes.NewReader(plaintext))
	s.Nilf(err, "new upload request failed: %v", err)
	uploadReq.Header.Set("Content-Type", "video/mp4")
	uploadReq.Header.Set("Image-Date", "2022:11:08 12:34:36")
	uploadReq.Header.Set("Image-Is-Live-Photo", "true")
	uploadReq.Header.Set("Image-Encrypt-Type", "AES_256_GCM")
	uploadReq.Header.Set("Image-Encrypt-Password", password)
	uploadResp, err := http.DefaultClient.Do(uploadReq)
	s.Nilf(err, "GCM live video upload failed: %v", err)
	s.Equalf(http.StatusOK, uploadResp.StatusCode, "upload status %d", uploadResp.StatusCode)
	io.Copy(io.Discard, uploadResp.Body)
	uploadResp.Body.Close()

	// genPath(IsLivePhoto=true, enc=GCM): 2022/11/08/live_20221108123436_test_video/20221108123436_test_video.mp4.aes
	liveSmbDir := "storage/2022/11/08/live_20221108123436_test_video"
	s.waitSmbDir(liveSmbDir, 10*time.Second)
	encPath := "2022/11/08/live_20221108123436_test_video/20221108123436_test_video.mp4.aes"
	s.Nil(waitfile(s.srv, encPath, 10*time.Second))

	// 常规 GET + Range: bytes=1000- -> GetOffset -> GCM 分支 -> 206 + 明文段
	downloadURL := fmt.Sprintf("http://%s/%s", httpAddr, encPath)
	getReq, err := http.NewRequest(http.MethodGet, downloadURL, nil)
	s.Nil(err)
	getReq.Header.Set("Image-Encrypt-Type", "AES_256_GCM")
	getReq.Header.Set("Image-Encrypt-Password", password)
	getReq.Header.Set("Range", "bytes=1000-")

	getResp, err := http.DefaultClient.Do(getReq)
	s.Nil(err)
	defer getResp.Body.Close()

	s.Equalf(http.StatusPartialContent, getResp.StatusCode,
		"GCM live video Range expected 206, got %d", getResp.StatusCode)

	body, err := io.ReadAll(getResp.Body)
	s.Nil(err)
	expected := plaintext[1000:]
	if !bytes.Equal(body, expected) {
		s.Failf("GCM live video Range body mismatch", "got %d bytes, want %d bytes", len(body), len(expected))
	}

	// Content-Range total 应等于明文总长
	cr := getResp.Header.Get("Content-Range")
	s.Truef(strings.HasPrefix(cr, fmt.Sprintf("bytes 1000-%d/%d", plainSize-1, plainSize)),
		"Content-Range mismatch: got %q", cr)

	// /live/ GET + Range: bytes=1000- -> GetLiveVideoOffset -> GCM 分支
	//（I-08：.aes 视频可被发现）-> 206 + 明文段。
	liveGetURL := fmt.Sprintf("http://%s/live/%s", httpAddr, encPath)
	liveGetReq, err := http.NewRequest(http.MethodGet, liveGetURL, nil)
	s.Nil(err)
	liveGetReq.Header.Set("Image-Encrypt-Type", "AES_256_GCM")
	liveGetReq.Header.Set("Image-Encrypt-Password", password)
	liveGetReq.Header.Set("Range", "bytes=1000-")
	liveGetResp, err := http.DefaultClient.Do(liveGetReq)
	s.Nil(err)
	defer liveGetResp.Body.Close()
	s.Equalf(http.StatusPartialContent, liveGetResp.StatusCode,
		"GCM live video /live/ Range expected 206, got %d", liveGetResp.StatusCode)
	liveBody, err := io.ReadAll(liveGetResp.Body)
	s.Nil(err)
	if !bytes.Equal(liveBody, expected) {
		s.Failf("GCM live video /live/ Range body mismatch", "got %d bytes, want %d bytes", len(liveBody), len(expected))
	}
}

// =============================================================================
// CFB 加密 Live Video Range 拒绝（回归保护）
// =============================================================================

// TestEncryptLiveVideoRejectsRangeOnCfb 验证 CFB 加密的 Live Video 拒绝 Range 下载。
//
// 背景：
//  1. CFB 加密入口已在 EncryptedReaderWraper 中弃用并拒绝（运行时返回
//     "CFB encryption is deprecated, use GCM"），因此无法通过 HTTP /live/ 上传 CFB 文件。
//  2. I-08 修复后，GetLiveVideoOffset 可发现 .aes 加密视频：/live/ GET +
//     Range 会到达 CFB 分支并被拒绝（"encrypted file (CFB) not support
//     get offset" -> 500/400），不再是旧的 "video not found"。
//
// 为覆盖 CFB 对 Range 的拒绝语义，本测试直接在 SMB share 上写入一个 legacy CFB 格式
// 的 .aes 文件（IV(16B) + AES-128-CFB 密文），然后从两条路径验证拒绝：
//   - /live/ GET + Range -> GetLiveVideoOffset -> CFB 分支 -> offset>0
//     -> "encrypted file (CFB) not support get offset" -> 500/400
//   - 常规 GET + Range -> GetOffset -> 非 PHO1 magic -> CFB 分支 -> offset>0
//     -> "encrypted file (CFB) not support get offset" -> 500/400
func (s *EncryptTestSuite) TestEncryptLiveVideoRejectsRangeOnCfb() {
	s.setupSmbDrive()

	password := "cfb-live-reject-pw"
	plaintext := bytes.Repeat([]byte("CFBLIVE_"), 1024) // 8KB
	cfbBlob := legacyCfbEncrypt(password, plaintext)    // IV(16) + AES-128-CFB 密文

	// 模拟 /live/ 上传后的存储路径：
	// 2022/11/08/live_20221108123436_cfb_video/20221108123436_cfb_video.mp4.aes
	liveSmbDir := "storage/2022/11/08/live_20221108123436_cfb_video"
	err := s.share.MkdirAll(liveSmbDir, os.ModePerm)
	s.Nilf(err, "mkdir live dir failed: %v", err)
	cfbSmbPath := liveSmbDir + "/20221108123436_cfb_video.mp4.aes"
	err = s.share.WriteFile(cfbSmbPath, cfbBlob, os.ModePerm)
	s.Nilf(err, "write cfb file failed: %v", err)

	encPath := "2022/11/08/live_20221108123436_cfb_video/20221108123436_cfb_video.mp4.aes"
	s.Nil(waitfile(s.srv, encPath, 10*time.Second))

	// 1) /live/ GET + Range: bytes=1- -> 期望拒绝（500/400，CFB 分支拒绝 offset>0）
	liveGetURL := fmt.Sprintf("http://%s/live/%s", httpAddr, encPath)
	liveReq, err := http.NewRequest(http.MethodGet, liveGetURL, nil)
	s.Nil(err)
	liveReq.Header.Set("Image-Encrypt-Type", "AES_128_CFB")
	liveReq.Header.Set("Image-Encrypt-Password", password)
	liveReq.Header.Set("Range", "bytes=1-")
	liveResp, err := http.DefaultClient.Do(liveReq)
	s.Nil(err)
	defer liveResp.Body.Close()
	if liveResp.StatusCode != http.StatusInternalServerError && liveResp.StatusCode != http.StatusBadRequest {
		body, _ := io.ReadAll(liveResp.Body)
		s.Failf("CFB live video /live/ Range expected 500/400",
			"got %d, body: %s", liveResp.StatusCode, string(body))
	} else {
		s.T().Logf("CFB live video /live/ Range correctly rejected with status %d", liveResp.StatusCode)
	}

	// 2) 常规 GET + Range: bytes=1- -> 期望拒绝（500 "encrypted file (CFB) not support get offset"）
	regularGetURL := fmt.Sprintf("http://%s/%s", httpAddr, encPath)
	regularReq, err := http.NewRequest(http.MethodGet, regularGetURL, nil)
	s.Nil(err)
	regularReq.Header.Set("Image-Encrypt-Type", "AES_128_CFB")
	regularReq.Header.Set("Image-Encrypt-Password", password)
	regularReq.Header.Set("Range", "bytes=1-")
	regularResp, err := http.DefaultClient.Do(regularReq)
	s.Nil(err)
	defer regularResp.Body.Close()
	if regularResp.StatusCode != http.StatusInternalServerError && regularResp.StatusCode != http.StatusBadRequest {
		body, _ := io.ReadAll(regularResp.Body)
		s.Failf("CFB regular Range expected 500/400",
			"got %d, body: %s", regularResp.StatusCode, string(body))
	} else {
		body, _ := io.ReadAll(regularResp.Body)
		s.T().Logf("CFB regular Range correctly rejected with status %d: %s",
			regularResp.StatusCode, string(body))
	}
}

// =============================================================================
// 测试辅助方法（新增）
// =============================================================================

// uploadEncryptedBytes 通过 HTTP POST 加密上传任意明文，返回 .aes 文件路径。
// 与 uploadEncrypted 不同，本助手支持自定义明文内容（用于构造 ≥3MB 等场景）。
func (s *EncryptTestSuite) uploadEncryptedBytes(name, dateLayout, encType, password string, content []byte) (string, error) {
	url := fmt.Sprintf("http://%s/%s", httpAddr, name)
	req, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(content))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "image/jpeg")
	req.Header.Set("Image-Date", dateLayout)
	req.Header.Set("Image-Encrypt-Type", encType)
	req.Header.Set("Image-Encrypt-Password", password)

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return "", fmt.Errorf("upload HTTP %d: %s", resp.StatusCode, string(body))
	}
	io.Copy(io.Discard, resp.Body)
	// DSCF_DIRECTORY_TYPE_01（默认）: YYYY/MM/DD/YYYYMMDDhhmmss_name.aes
	return "2022/11/08/20221108123436_" + name + ".aes", nil
}

// legacyCfbEncrypt 复刻 imgmanager.legacyKDF + AES-128-CFB 加密格式（IV(16B) + 密文）。
// 用于在测试中直接生成 legacy CFB 格式 .aes 文件——CFB 加密入口已在
// EncryptedReaderWraper 中弃用并拒绝，无法通过 HTTP 上传 CFB 文件。
func legacyCfbEncrypt(password string, plaintext []byte) []byte {
	// legacyKDF: 迭代 MD5 派生 16 字节密钥（与 server/imgmanager/encrypt.go legacyKDF 一致）
	const keyLen = 16
	var b, prev []byte
	h := md5.New()
	for len(b) < keyLen {
		h.Write(prev)
		h.Write([]byte(password))
		b = h.Sum(b)
		prev = b[len(b)-h.Size():]
		h.Reset()
	}
	key := b[:keyLen]

	block, err := aes.NewCipher(key)
	if err != nil {
		panic(fmt.Sprintf("aes new cipher: %v", err))
	}
	iv := make([]byte, block.BlockSize())
	if _, err := io.ReadFull(rand.Reader, iv); err != nil {
		panic(fmt.Sprintf("read iv: %v", err))
	}
	stream := cipher.NewCFBEncrypter(block, iv)
	ciphertext := make([]byte, len(plaintext))
	stream.XORKeyStream(ciphertext, plaintext)
	return append(iv, ciphertext...)
}
