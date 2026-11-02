BUILD_VERSION   := $(shell git describe --tags)
GIT_COMMIT_SHA1 := $(shell git rev-parse HEAD)
BUILD_TIME      := $(shell date "+%F %T")
BUILD_NAME      := img_syncer_server
VERSION_PACKAGE_NAME := github.com/fregie/PrintVersion

DESCRIBE := img_syncer grpc server

prebuild:
	go install google.golang.org/protobuf/cmd/protoc-gen-go@v1.27.1
	go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@v1.1.0
	dart pub global activate protoc_plugin 21.1.2

# 警告：protobuf 目标会重写已生成的代码文件（lib/proto/*.pb.dart、
# lib/proto/*.pbgrpc.dart、server 侧 Go 生成文件）。仅在 .proto
# 变更后跑，且跑完须检查 git diff 确认只有预期改动；不要把它当
# 作常规构建步骤。
# 本机已核实的插件版本（2026-11-02，~/go/bin）：
#   protoc-gen-go v1.27.1、protoc-gen-go-grpc 1.1.0（与 prebuild
#   的 pin 一致）；protoc 二进制与 Dart protoc_plugin（pin 21.1.2）
#   本 VM 未安装，`make protobuf` 无法在本机跑通，再生检查未验证。
protobuf:
	protoc -I. --go_out . --go_opt paths=source_relative \
		--go-grpc_out . --go-grpc_opt paths=source_relative \
		--dart_out=grpc:lib \
		proto/*.proto

.PHONY: server
server:
	CGO_ENABLED=0 go build -ldflags "\
		-X '${VERSION_PACKAGE_NAME}.Version=${BUILD_VERSION}' \
		-X '${VERSION_PACKAGE_NAME}.BuildTime=${BUILD_TIME}' \
		-X '${VERSION_PACKAGE_NAME}.GitCommitSHA1=${GIT_COMMIT_SHA1}' \
		-X '${VERSION_PACKAGE_NAME}.Describe=${DESCRIBE}' \
		-X '${VERSION_PACKAGE_NAME}.Name=${BUILD_NAME}' \
		" \
    -o server/output/${BUILD_NAME} ./server

server-aar: protobuf
	CGO_ENABLED=0 gomobile bind -target=android -androidapi 21 -ldflags "-s -w" -o android/app/libs/server.aar ./server/run

server-ios: protobuf
	CGO_ENABLED=0 gomobile bind -target=ios -ldflags "-s -w" -o ios/Frameworks/RUN.xcframework ./server/run

server-linux: protobuf
	CGO_ENABLED=1 GOOS=linux GOARCH=amd64 go build -o linux/lib/run.so -buildmode=c-shared ./server/clib

server-windows:
	# CGO_ENABLED=1 GOOS=windows GOARCH=amd64 go build -o windows/lib/run.lib -buildmode=c-shared ./server/clib
	go build -o windows/lib/run.dll -buildmode=c-shared ./server/clib
	sed -i '/#include <complex.h>/d' windows\lib\run.h
	sed -i '/typedef _Fcomplex GoComplex64;/d' windows\lib\run.h
	sed -i '/typedef _Dcomplex GoComplex128;/d' windows\lib\run.h
	dlltool -d windows/lib/run.def -l windows/lib/run.lib

server-macos: protobuf
	CGO_ENABLED=0 gomobile bind -target=macos -ldflags "-s -w" -o macos/Frameworks/RUN.xcframework ./server/run


apk:
	flutter build apk --release --obfuscate --split-debug-info=./debug-info

# FK-17：与 CHANGES-iOS.md §8 的个人侧载流程对齐——development
# 导出。flutter 会按 --export-method 自动生成 ExportOptions.plist；
# 仓库内不存在 ios/ExportOptions.plist 是预期的（签名 Team 在
# Xcode 工程 / 个人 Apple ID 登录后配置，见 §8 余项说明）。
ipa:
	flutter build ipa --export-method development --no-tree-shake-icons --obfuscate --split-debug-info=./debug-info

# Go 集成测试（需要 Docker + test/docker-compose.yml 的后端服务，
# 属 Area C 的 Docker 套件）。`make test` 是历史别名，见下。
.PHONY: test-go
test-go:
	docker compose -f test/docker-compose.yml up -d --build --wait
	go test -v ./server/api -p 1 -failfast
	go test -v ./server/drive -p 1 -failfast
	docker compose -f test/docker-compose.yml down

# 历史别名：仅跑 Go 集成测试，不跑 Dart 测试（FK-19）。
# Dart 套件用 `make test-flutter`。
.PHONY: test
test: test-go
	@echo "NOTE: 'make test' runs Go+docker integration tests only; run 'make test-flutter' for the Dart test suite."

# Dart/Flutter 测试套件（127+ 个用例，含 widget/golden；golden
# 像素比对仅 Linux 生效）。不需要 Docker。
.PHONY: test-flutter
test-flutter:
	flutter test