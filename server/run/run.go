package run

import (
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"

	"github.com/fregie/img_syncer/server/api"
	"github.com/fregie/img_syncer/server/imgmanager"
	_ "golang.org/x/mobile/bind"
	"google.golang.org/grpc"
	"google.golang.org/grpc/reflection"

	pb "github.com/fregie/img_syncer/proto"
)

var (
	imgManager *imgmanager.ImgManager
	grpcServer *grpc.Server
	grpcLis    net.Listener
	httpLis    net.Listener
)

// 威胁模型（嵌入式模式）：本服务无任何认证，gRPC reflection 保持启用，
// 但两个监听器都只绑定 127.0.0.1，信任边界是同一设备上的进程：
// 唯一预期客户端是宿主 App（同一进程/设备）。任何能访问 loopback 的
// 本地进程理论上都能操作照片与驱动——这在移动设备上与 App 自身的
// 权限等价，因而可接受。绝不要把这里的绑定改成 0.0.0.0；独立
// 服务端（server/main.go）默认同样只绑定 loopback，暴露局域网
// 必须显式传参并自行保证网络可信。
func RunGrpcServer() (string, error) {
	imgManager = imgmanager.NewImgManager(imgmanager.Option{})
	var err error
	var grpcPort, httpPort int
	for start := 10000; start < 20000; start++ {
		grpcLis, err = net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", start))
		if err != nil {
			Info.Printf("Listen on %d failed, try next port", start)
			continue
		} else {
			grpcPort = start
			break
		}
	}
	if err != nil {
		Error.Printf("Listen on all port failed, err: %v", err)
		return "", err
	}

	for start := 10000; start < 20000; start++ {
		httpLis, err = net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", start))
		if err != nil {
			Info.Printf("Listen on %d failed, try next port", start)
			continue
		} else {
			httpPort = start
			break
		}
	}
	if err != nil {
		Error.Printf("Listen on all port failed, err: %v", err)
		// HTTP 监听失败时 gRPC 监听器已建立：必须关闭，否则泄漏一个
		// 无人服务的监听端口（此前直接 return，grpcLis 保持打开）。
		if grpcLis != nil {
			grpcLis.Close()
			grpcLis = nil
		}
		return "", err
	}

	api := api.NewApi(imgManager)
	api.SetHttpPort(httpPort)
	grpcServer = grpc.NewServer()
	pb.RegisterImgSyncerServer(grpcServer, api)
	reflection.Register(grpcServer)

	Info.Printf("Listening grpc on %s", grpcLis.Addr().String())
	go grpcServer.Serve(grpcLis)
	Info.Printf("Listening http on %s", httpLis.Addr().String())
	go http.Serve(httpLis, api.HttpHandler())

	return fmt.Sprintf("%d,%d", grpcPort, httpPort), nil
}

func Shutdown() {
	if grpcServer != nil {
		grpcServer.GracefulStop()
		grpcServer = nil
	}
	if grpcLis != nil {
		grpcLis.Close()
		grpcLis = nil
	}
	if httpLis != nil {
		httpLis.Close()
		httpLis = nil
	}
	// 关闭驱动：此前 Shutdown 只停了服务器，驱动连接（SMB/NFS 会话）
	// 保持打开，SetDrive 换出的旧驱动也得不到关闭。
	if imgManager != nil {
		imgManager.Close()
	}
}

var (
	//Debug print debug informantion
	Debug *log.Logger
	//Info print Info informantion
	Info *log.Logger
	//Error print Error informantion
	Error *log.Logger
)

func init() {
	Info = log.New(os.Stdout, "[INFO] ", log.Ldate|log.Ltime)
	Error = log.New(os.Stderr, "[ERROR] ", log.Ldate|log.Ltime|log.Lshortfile)
	Debug = log.New(io.Discard, "[DEBUG] ", log.Ldate|log.Ltime|log.Lshortfile)
}
