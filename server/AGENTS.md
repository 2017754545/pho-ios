# server/ — Go Backend Knowledge Base

**Module:** github.com/fregie/img_syncer (Go 1.25)
**Rewritten:** 2026-11-02 (matches code after the fix-everything pass; earlier versions of this file contradicted the code and must not be trusted)

## OVERVIEW
Go gRPC backend implementing ImgSyncerServer (13 RPCs) with a companion HTTP file handler, orchestrating upload/download/thumbnail generation across 3 storage backends. Unauthenticated: the standalone entry binds loopback by default (see Security below); anyone who can connect can list/download/delete photos and change drives.

## STRUCTURE
```
server/
├── main.go            # Standalone entry: flags grpcAddr/httpAddr default 127.0.0.1:50051 / 127.0.0.1:8000, -d (pprof 127.0.0.1:6060, reflection on)
├── log.go             # Package-level loggers: Info(stdout), Error(stderr+Lshortfile), Debug(discard unless -d)
├── api/               # gRPC service impl + HTTP handler
│   ├── img.go         # api struct embeds pb.UnimplementedImgSyncerServer; core RPCs + FilterNotUploaded bidir stream
│   ├── http.go        # net/http single-handler mux by method+path; custom Image-* headers; encodeName
│   ├── {smb,webdav,nfs}.go  # Per-drive config/setup/login RPCs (configure fully BEFORE im.SetDrive)
│   └── *_test.go      # testify/suite Docker integration tests + package-api unit tests (http_test.go, http_behavior_test.go, pathutil_test.go)
├── imgmanager/        # Core orchestrator
│   ├── imgmanager.go  # ImgManager: StorageDrive holder, channel-based worker pool (default 2, async deletes only), Close() idempotent
│   ├── interface.go   # StorageDrive interface: 7 methods (Upload, IsExist, Download, DownloadWithOffset, Delete, Range, Close); Image struct; UnimplementedDrive
│   ├── encrypt.go     # Dual-scheme: legacy AES-128-CFB decrypt-only + AES-256-GCM (PHO1 header, PBKDF2-SHA256 100k iterations); CFB encryption is rejected at upload
│   └── metadata.go    # ImageMetadata struct only (embedded in Image, fields stay empty; EXIF extraction was removed — no callers)
├── drive/             # 3 StorageDrive impls (smb/webdav/nfs) + drive_test.go integration test
├── run/run.go         # Embedded entry for gomobile: loopback-only, auto-port scan 10000-20000, returns "grpcPort,httpPort"; Shutdown() closes servers AND the drive
├── clib/clib.go       # CGo //export RunGrpcServer wrapping run.RunGrpcServer for c-shared .so/.dll builds
└── util/              # util.go (IsVideo strips .aes; ContentTypeByExtension is the single resolver, explicit map first), path.go (CleanDirPath/CleanShareName traversal guards)
```

## WHERE TO LOOK
| Task | Location | Notes |
|------|----------|-------|
| Add a gRPC RPC | `proto/img_syncer.proto` → `make protobuf` → impl in `server/api/` | api embeds pb.UnimplementedImgSyncerServer; 13 RPCs as of 2026-11-02 |
| Add an HTTP endpoint | `server/api/http.go` `httpHandler()` | Dispatch by method + path prefix; unknown methods return 405; no router lib |
| Add a storage backend | `server/drive/<name>/` impl StorageDrive + `server/api/<name>.go` | Construct + fully configure BEFORE `im.SetDrive(d)`; old drive stays on failure |
| Change upload logic | `server/imgmanager/imgmanager.go` `Upload()` | Uploads are synchronous; the worker pool handles async deletes only |
| Change file path format | `server/imgmanager/imgmanager.go` `genPath()` | Builds {year}/{month}/{day}/{timestamp}_{name}[.aes]; one effective date via `EffectiveFileDate` |
| Add encryption scheme | `server/imgmanager/encrypt.go` | Do not change the GCM/CFB design without a security review; GCM chunkSize is validated (0 rejected, 16 MiB cap) |
| Change sync filtering | `server/api/img.go` `FilterNotUploaded()` | Bidir stream; request order preserved; RangeByDate errors return Success=false with no fabricated list; duplicate encoded names reported in Message |
| Add MIME type mapping | `server/util/util.go` `ContentTypeByExtension` | The single resolver; explicit `defaultMimeMap` first, system mime table fallback; includes .heic/.heif/.dng |
| Sanitize a browsing path | `server/util/path.go` `CleanDirPath` / `CleanShareName` | Rejects any `..` element (even ones path.Clean would fold back inside); preserves `.` and `/` root spellings |

## CONVENTIONS
- **Dual-entry wiring**: Both main.go and run/run.go wire `api.NewApi(imgManager)` + `pb.RegisterImgSyncerServer`. Both bind loopback only.
- **Security / threat model**: No authentication anywhere. Standalone defaults to loopback; exposing on LAN requires explicit `-grpcAddr`/`-httpAddr` overrides on a trusted network. gRPC reflection is registered only in debug mode (`-d`). The embedded path (run/run.go) is loopback-only with reflection enabled; its trust boundary is same-device processes. Never rebind to 0.0.0.0 casually.
- **HTTP routing**: Single `http.HandlerFunc` in api/http.go. Dispatch by `r.Method` (GET/POST) and `strings.HasPrefix(r.URL.Path, ...)`. Unknown methods → 405 with `Allow: GET, POST`. Custom headers: `Image-Date`, `Image-Encrypt-Type`, `Image-Encrypt-Password`, `Image-Is-Live-Photo`. Chunked uploads (`ContentLength < 0`) → 411; `ContentLength == 0` → 400. Malformed Range → 400; `start >= size` → 416 with `Content-Range: bytes */<size>`.
- **Logging**: Custom `log.Logger` instances (Info/Error/Debug). Debug → discard unless `-d`. run/run.go duplicates its own logger init(). No slog/logrus/zap.
- **Worker pattern**: ImgManager holds a buffered channel (`actCh`, cap 10) and N workers (default 2). The pool handles ONLY async deletes (`actDelete`); uploads and thumbnail generation are synchronous. `Close()` is idempotent (sync.Once) and drains the pending-delete queue; deletes enqueued after Close are dropped.
- **Drive hot-swap**: Single `StorageDrive` field (`dri`) on ImgManager. `SetDrive()` replaces it. Default is `UnimplementedDrive` (returns "no available drive"). API `SetDrive*` handlers configure the new drive fully (including network validation of share/root) before swapping, so a failed setup keeps the old drive.
- **Name encoding**: `encodeName(time, name)` produces `"20060102030405_name"`. There is no decodeName (deleted: zero callers). Used in FilterNotUploaded and HTTP upload handlers.
- **Encryption**: Dual-scheme — legacy AES-128-CFB (decryption of old files only; encryption rejected at upload with "CFB encryption is deprecated, use GCM") + AES-256-GCM (`PHO1` magic header, PBKDF2-SHA256 100k iterations, 1 MiB chunks). GCM supports `GetOffset()` for HTTP Range / video streaming; CFB rejects non-zero offsets. Scheme auto-detected from file header on read. `DecryptedContentSize` never returns negative; GCM size math uses the header chunkSize (`DecryptedContentSizeWithChunkSize`).
- **Offset contract**: `DownloadWithOffset` with `offset == size` returns an empty stream plus the total size; `offset > size` is an error. The HTTP layer turns `start >= size` into 416.
- **Upload size**: `StorageDrive.Upload`'s `size` parameter is advisory only (SMB/NFS ignore it and stream to EOF; WebDAV uses it for Content-Length). Length enforcement is the caller's `sizeCheckReader`. Negative sizes are rejected in `Upload`/`UploadThumbnail`/`UploadLiveVideo`.
- **Delete errors**: `ImgManager.DeleteImg(paths)` returns per-path `[]error`; the `Delete` RPC aggregates them into `Success=false` + a message instead of always reporting success.
- **Testing**: testify/suite Docker integration tests (SMB/WebDAV/NFS via `make test` / `test/docker-compose.yml`) plus unit tests that run without Docker (`go test ./server/...` for `server`, `server/imgmanager`, `server/util`, unit tests in `server/api`, `server/drive/*`). Test-fixture credentials (`fregie`/`password`) exist only in test files and Docker fixtures; production code has no hardcoded credentials (only the `Image-Encrypt-Password` header-name constant).
- **Build modes**: `CGO_ENABLED=0` for gomobile binds (run/run.go imports `golang.org/x/mobile/bind`). `CGO_ENABLED=1` for c-shared .so/.dll (clib/clib.go uses `//export RunGrpcServer`).
- **Forked deps**: `go.mod` has replace directives for `fregie/gowebdav` and `fregie/go-nfs-client`.

## ANTI-PATTERNS (verified present; do not copy them into new code)
- NFS drive uses AUTH_UNIX root (uid 0): no real authentication.
- WebDAV drive disables TLS verification only when the `insecure` flag is true (`InsecureSkipVerify: insecure`); it is NOT globally disabled.
- Encrypted `.aes` files with CFB scheme reject range download: `GetOffset()` returns error. GCM scheme (PHO1 header) supports it. Video streaming works with GCM encryption only.
- Windows c-shared build requires manual `sed`/`dlltool` post-processing (documented in `build.md`).
- CI test/lint/analyze steps have `continue-on-error: true` (non-blocking).
