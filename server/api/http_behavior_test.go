package api

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	pb "github.com/fregie/img_syncer/proto"
	"github.com/fregie/img_syncer/server/imgmanager"
)

func newTestAPIWithDrive(d imgmanager.StorageDrive) *api {
	im := imgmanager.NewImgManager(imgmanager.Option{WorkerNum: 1})
	im.SetDrive(d)
	a := NewApi(im)
	a.SetHttpPort(0)
	return a
}

// =============================================================================
// I-16: 未知方法返回 405（此前隐式 200 空 body）
// =============================================================================

func TestHTTPUnknownMethod405(t *testing.T) {
	a := newTestAPI()
	req := httptest.NewRequest(http.MethodPut, "/test.jpg", nil)
	w := httptest.NewRecorder()
	a.httpHandler(w, req)
	if w.Code != http.StatusMethodNotAllowed {
		t.Fatalf("PUT: got %d, want 405", w.Code)
	}
	if allow := w.Header().Get("Allow"); allow != "GET, POST" {
		t.Errorf("Allow header: got %q, want %q", allow, "GET, POST")
	}
	req = httptest.NewRequest(http.MethodDelete, "/test.jpg", nil)
	w = httptest.NewRecorder()
	a.httpHandler(w, req)
	if w.Code != http.StatusMethodNotAllowed {
		t.Fatalf("DELETE: got %d, want 405", w.Code)
	}
}

// =============================================================================
// I-12/I-17: Range 边界（416 / end<start 400 / 畸形 end 400）
// =============================================================================

func TestHTTPDownloadRangeStartBeyondSize416(t *testing.T) {
	a := newTestAPI() // content "0123456789" (10 bytes)
	w := doRangeRequest(a, "bytes=10-")
	if w.Code != http.StatusRequestedRangeNotSatisfiable {
		t.Fatalf("bytes=10- on 10-byte file: got %d, want 416", w.Code)
	}
	if cr := w.Header().Get("Content-Range"); cr != "bytes */10" {
		t.Errorf("Content-Range: got %q, want %q", cr, "bytes */10")
	}
	// start 远超 size 时后端报越界错（500）：三个后端对 offset>size
	// 统一返回错误，只有 offset==size 走 HTTP 层 416；此处只锁定
	// “不返回 206/负 Content-Length”。
	w = doRangeRequest(a, "bytes=100-200")
	if w.Code == http.StatusPartialContent {
		t.Fatalf("bytes=100-200: got 206, must not succeed")
	}
	if cl := w.Header().Get("Content-Length"); strings.HasPrefix(cl, "-") {
		t.Fatalf("bytes=100-200: negative Content-Length %q", cl)
	}
}

func TestHTTPDownloadRangeEndBeforeStart400(t *testing.T) {
	a := newTestAPI()
	w := doRangeRequest(a, "bytes=8-5")
	if w.Code != http.StatusBadRequest {
		t.Fatalf("bytes=8-5: got %d, want 400", w.Code)
	}
}

func TestHTTPDownloadRangeMalformedEnd400(t *testing.T) {
	a := newTestAPI()
	for _, h := range []string{"bytes=0-abc", "bytes=0-1x", "bytes=0--1"} {
		w := doRangeRequest(a, h)
		if w.Code != http.StatusBadRequest {
			t.Errorf("%s: got %d, want 400 (was 500 before fix)", h, w.Code)
		}
	}
}

// =============================================================================
// I-30: chunked 上传（ContentLength==-1）返回 411
// =============================================================================

func TestHTTPUploadChunkedLength411(t *testing.T) {
	a := newTestAPI()
	for _, path := range []string{"/pic.jpg", "/thumbnail/pic.jpg", "/live/pic.mp4"} {
		req := httptest.NewRequest(http.MethodPost, path, strings.NewReader("data"))
		req.ContentLength = -1
		w := httptest.NewRecorder()
		a.httpHandler(w, req)
		if w.Code != http.StatusLengthRequired {
			t.Errorf("POST %s with ContentLength -1: got %d, want 411", path, w.Code)
		}
	}
}

// =============================================================================
// I-04: Delete 聚合后端错误
// =============================================================================

func TestDeleteAggregatesBackendErrors(t *testing.T) {
	drv := &mockDrive{content: []byte("x"), deleteErr: errors.New("drive delete boom")}
	a := newTestAPIWithDrive(drv)
	rsp, err := a.Delete(context.Background(), &pb.DeleteRequest{Paths: []string{"2023/01/01/x.jpg"}})
	if err != nil {
		t.Fatalf("Delete RPC error: %v", err)
	}
	if rsp.Success {
		t.Fatal("Delete must report Success=false when backend delete fails")
	}
	if !strings.Contains(rsp.Message, "drive delete boom") {
		t.Errorf("Message must carry backend error, got %q", rsp.Message)
	}

	// 对照：后端成功时仍报告成功。
	a2 := newTestAPIWithDrive(&mockDrive{content: []byte("x")})
	rsp2, err := a2.Delete(context.Background(), &pb.DeleteRequest{Paths: []string{"2023/01/01/x.jpg"}})
	if err != nil {
		t.Fatalf("Delete RPC error: %v", err)
	}
	if !rsp2.Success {
		t.Errorf("Delete must succeed when backend succeeds, message=%q", rsp2.Message)
	}
}

// =============================================================================
// I-03/I-24: FilterNotUploaded 错误传播 + 请求顺序 + 重名上报
// =============================================================================

type fakeFilterStream struct {
	pb.ImgSyncer_FilterNotUploadedServer
	reqs []*pb.FilterNotUploadedRequest
	idx  int
	sent []*pb.FilterNotUploadedResponse
}

func (f *fakeFilterStream) Recv() (*pb.FilterNotUploadedRequest, error) {
	if f.idx >= len(f.reqs) {
		return nil, io.EOF
	}
	r := f.reqs[f.idx]
	f.idx++
	return r, nil
}

func (f *fakeFilterStream) Send(r *pb.FilterNotUploadedResponse) error {
	f.sent = append(f.sent, r)
	return nil
}

func TestFilterNotUploadedRangeErrorReturnsFailureWithoutFabricatedList(t *testing.T) {
	drv := &mockDrive{content: []byte("x"), rangeErr: errors.New("drive list boom")}
	a := newTestAPIWithDrive(drv)
	stream := &fakeFilterStream{reqs: []*pb.FilterNotUploadedRequest{{
		Photos: []*pb.FilterNotUploadedRequestInfo{
			{Id: "id1", Name: "pic.jpg", Date: "2023:01:01 10:00:00"},
		},
		IsFinished: true,
	}}}
	if err := a.FilterNotUploaded(stream); err != nil {
		t.Fatalf("FilterNotUploaded stream error: %v", err)
	}
	if len(stream.sent) != 1 {
		t.Fatalf("expected 1 response, got %d", len(stream.sent))
	}
	rsp := stream.sent[0]
	if rsp.Success {
		t.Fatal("FilterNotUploaded must return Success=false on RangeByDate error")
	}
	if len(rsp.NotUploadedIDs) != 0 || len(rsp.NotUploaedIDs) != 0 {
		t.Errorf("must NOT send fabricated not-uploaded list on error, got %v", rsp.NotUploadedIDs)
	}
}

func TestFilterNotUploadedPreservesRequestOrderAndReportsDuplicates(t *testing.T) {
	a := newTestAPIWithDrive(&mockDrive{content: []byte("x")})
	stream := &fakeFilterStream{reqs: []*pb.FilterNotUploadedRequest{{
		Photos: []*pb.FilterNotUploadedRequestInfo{
			{Id: "id3", Name: "c.jpg", Date: "2023:01:03 10:00:00"},
			{Id: "id1", Name: "a.jpg", Date: "2023:01:01 10:00:00"},
			{Id: "id2", Name: "b.jpg", Date: "2023:01:02 10:00:00"},
			// 同名同日期、不同 ID：编码名冲突。
			{Id: "id1-dup", Name: "a.jpg", Date: "2023:01:01 10:00:00"},
		},
		IsFinished: true,
	}}}
	if err := a.FilterNotUploaded(stream); err != nil {
		t.Fatalf("FilterNotUploaded stream error: %v", err)
	}
	if len(stream.sent) != 1 {
		t.Fatalf("expected 1 response, got %d", len(stream.sent))
	}
	rsp := stream.sent[0]
	if !rsp.Success {
		t.Fatalf("expected success, message=%q", rsp.Message)
	}
	want := []string{"id3", "id1", "id2", "id1-dup"}
	if len(rsp.NotUploadedIDs) != len(want) {
		t.Fatalf("NotUploadedIDs = %v, want %v", rsp.NotUploadedIDs, want)
	}
	for i, id := range want {
		if rsp.NotUploadedIDs[i] != id {
			t.Fatalf("NotUploadedIDs = %v, want request order %v", rsp.NotUploadedIDs, want)
		}
	}
	if !strings.Contains(rsp.Message, "duplicate") {
		t.Errorf("duplicate encoded names must be reported in Message, got %q", rsp.Message)
	}
}
