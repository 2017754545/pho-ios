package main

import (
	"context"
	"flag"
	"net"
	"os"
	"os/signal"
	"syscall"
	"time"

	"net/http"
	_ "net/http/pprof"

	version "github.com/fregie/PrintVersion"
	pb "github.com/fregie/img_syncer/proto"
	"github.com/fregie/img_syncer/server/api"
	"github.com/fregie/img_syncer/server/imgmanager"
	"google.golang.org/grpc"
	"google.golang.org/grpc/reflection"
)

// 安全默认：独立服务端默认只绑定 loopback。本服务没有任何认证：
// 任何能连上 gRPC/HTTP 端口的人都能列出、下载、删除照片并改换存储
// 驱动。此前默认绑定 0.0.0.0，同一局域网内的任何设备都可直接操作。
// 如需局域网访问，必须显式传 -grpcAddr/-httpAddr 覆盖为 0.0.0.0，
// 并自行保证网络可信（防火墙/隔离 VLAN）；不要在不受信网络上暴露。
// 嵌入式路径（server/run）同样只绑定 127.0.0.1，见 run.go 的威胁模型注释。
var (
	grpcAddr    = flag.String("grpcAddr", "127.0.0.1:50051", "grpc addr example: 127.0.0.1:50051 (loopback by default; pass 0.0.0.0:50051 explicitly to expose on LAN)")
	httpAddr    = flag.String("httpAddr", "127.0.0.1:8000", "http addr example: 127.0.0.1:8000 (loopback by default; pass 0.0.0.0:8000 explicitly to expose on LAN)")
	showVersion = flag.Bool("version", false, "Displays version and exit.")
	debug       = flag.Bool("d", false, "debug mode")
)

var (
	imgManager *imgmanager.ImgManager
)

func main() {
	flag.Parse()
	if *showVersion {
		version.PrintVersion()
		return
	}
	if *debug {
		Debug.SetOutput(os.Stdout)
		Debug.Printf("pprof listen at 127.0.0.1:6060")
		go func() {
			if err := http.ListenAndServe("127.0.0.1:6060", nil); err != nil {
				Error.Fatalf("pprof server: %v", err)
			}
		}()
	}
	imgManager = imgmanager.NewImgManager(imgmanager.Option{})

	lis, err := net.Listen("tcp", *grpcAddr)
	if err != nil {
		Error.Fatalf("failed to listen: %v", err)
	}

	apiServer := api.NewApi(imgManager)
	httpServer := &http.Server{
		Addr:    *httpAddr,
		Handler: apiServer.HttpHandler(),
	}
	Info.Printf("Listening http on %s", *httpAddr)
	go func() {
		if err := httpServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			Error.Fatalf("http server: %v", err)
		}
	}()

	grpcServer := grpc.NewServer()
	pb.RegisterImgSyncerServer(grpcServer, apiServer)
	// gRPC reflection 会向任何连上者暴露全部服务定义：仅调试模式启用。
	if *debug {
		reflection.Register(grpcServer)
	}
	Info.Printf("Listening grpc on %s", lis.Addr().String())

	// Wait for interrupt signal
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		Error.Fatal(grpcServer.Serve(lis))
	}()
	<-quit
	Info.Printf("Shutting down...")

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	grpcServer.GracefulStop()
	if err := httpServer.Shutdown(ctx); err != nil {
		Error.Printf("http server shutdown error: %v", err)
	}
}
