package api

import (
	"context"
	"fmt"
	"net"
	"strings"
	"time"

	pb "github.com/fregie/img_syncer/proto"
	"github.com/fregie/img_syncer/server/drive/smb"
	"github.com/fregie/img_syncer/server/util"
)

func (a *api) SetDriveSMB(ctx context.Context, req *pb.SetDriveSMBRequest) (rsp *pb.SetDriveSMBResponse, err error) {
	rsp = &pb.SetDriveSMBResponse{Success: true}
	if req.Addr == "" {
		rsp.Success, rsp.Message = false, "param error: addr is empty"
		return
	}
	if strings.Index(req.Addr, ":") < 0 {
		req.Addr = req.Addr + ":445"
	}
	// 连通性探测：带超时，探测连接必须关闭（此前 Dial 成功后连接泄漏）。
	dialer := &net.Dialer{Timeout: 5 * time.Second}
	probe, e := dialer.DialContext(ctx, "tcp", req.Addr)
	if e != nil {
		rsp.Success, rsp.Message = false, fmt.Sprintf("connect to %s failed: %s", req.Addr, e.Error())
		return
	}
	probe.Close()
	s := smb.NewSmbDrive(req.Addr, req.Username, req.Password)
	// 先完整配置（share/root 校验含网络往返），全部成功后再替换当前
	// 驱动：此前 SetDrive 在校验之前，失败会留下一个未配置的驱动。
	if req.Share != "" {
		e := s.SetShare(req.Share)
		if e != nil {
			rsp.Success, rsp.Message = false, fmt.Sprintf("set share failed: %s", e.Error())
			return
		}
		if req.Root != "" {
			e := s.SetRootPath(req.Root)
			if e != nil {
				rsp.Success, rsp.Message = false, fmt.Sprintf("set root path failed: %s", e.Error())
				return
			}
		}
	}
	a.im.SetDrive(s)
	return
}

func (a *api) ListDriveSMBShares(ctx context.Context, req *pb.ListDriveSMBSharesRequest) (rsp *pb.ListDriveSMBSharesResponse, err error) {
	rsp = &pb.ListDriveSMBSharesResponse{Success: true}
	dri := a.im.Drive()
	if dri == nil {
		rsp.Success, rsp.Message = false, "drive is not set"
		return
	}
	smb, ok := dri.(*smb.Smb)
	if !ok {
		rsp.Success, rsp.Message = false, "drive is not smb"
		return
	}
	shares, e := smb.ListShare()
	if e != nil {
		rsp.Success, rsp.Message = false, fmt.Sprintf("list share failed: %s", e.Error())
		return
	}
	rsp.Shares = shares

	return
}

func (a *api) ListDriveSMBDir(ctx context.Context, req *pb.ListDriveSMBDirRequest) (rsp *pb.ListDriveSMBDirResponse, err error) {
	rsp = &pb.ListDriveSMBDirResponse{Success: true}
	dri := a.im.Drive()
	if dri == nil {
		rsp.Success, rsp.Message = false, "drive is not set"
		return
	}
	smb, ok := dri.(*smb.Smb)
	if !ok {
		rsp.Success, rsp.Message = false, "drive is not smb"
		return
	}
	if req.Dir == "" {
		req.Dir = "."
	}
	cleanedDir, e := util.CleanDirPath(req.Dir)
	if e != nil {
		rsp.Success, rsp.Message = false, fmt.Sprintf("invalid dir: %s", e.Error())
		return
	}
	if _, e := util.CleanShareName(req.Share); e != nil {
		rsp.Success, rsp.Message = false, fmt.Sprintf("invalid share: %s", e.Error())
		return
	}
	sess, e := smb.Dial()
	if e != nil {
		rsp.Success, rsp.Message = false, fmt.Sprintf("dial failed: %s", e.Error())
		return
	}
	defer sess.Logoff()
	share, e := sess.Mount(req.Share)
	if e != nil {
		rsp.Success, rsp.Message = false, fmt.Sprintf("mount share failed: %s", e.Error())
		return
	}
	defer share.Umount()
	infos, e := share.ReadDir(cleanedDir)
	if e != nil {
		rsp.Success, rsp.Message = false, fmt.Sprintf("read dir failed: %s", e.Error())
		return
	}
	rsp.Dirs = make([]string, 0)
	for _, info := range infos {
		if info.IsDir() {
			rsp.Dirs = append(rsp.Dirs, info.Name())
		}
	}

	return
}

func (a *api) SetDriveSMBShare(ctx context.Context, req *pb.SetDriveSMBShareRequest) (rsp *pb.SetDriveSMBShareResponse, err error) {
	rsp = &pb.SetDriveSMBShareResponse{Success: true}
	dri := a.im.Drive()
	if dri == nil {
		rsp.Success, rsp.Message = false, "drive is not set"
		return
	}
	smb, ok := dri.(*smb.Smb)
	if !ok {
		rsp.Success, rsp.Message = false, "drive is not smb"
		return
	}
	// 先记下旧配置：SetRootPath 失败时尽力恢复旧 share，避免驱动
	// 停在“新 share + 旧 root”的半配置状态（SetRootPath 只在成功时
	// 改 root，失败不改动 root；旧 share 为空时无可恢复，保持新 share）。
	oldShare := smb.ShareName()
	e := smb.SetShare(req.Share)
	if e != nil {
		rsp.Success, rsp.Message = false, fmt.Sprintf("set share failed: %s", e.Error())
		return
	}
	e = smb.SetRootPath(req.Root)
	if e != nil {
		if oldShare != "" {
			_ = smb.SetShare(oldShare)
		}
		rsp.Success, rsp.Message = false, fmt.Sprintf("set root path failed: %s", e.Error())
		return
	}
	return
}
