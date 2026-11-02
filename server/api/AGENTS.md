# API PACKAGE KNOWLEDGE BASE

**Rewritten:** 2026-11-02 (matches code after the fix-everything pass; earlier versions of this file contradicted the code and must not be trusted)

## OVERVIEW
Package `api` — the gRPC+HTTP boundary of the Go backend. One `api` struct (`img.go`) embeds `pb.UnimplementedImgSyncerServer`, wraps an `*imgmanager.ImgManager`, and doubles as the HTTP handler. 13 gRPC RPCs split across 4 handler files (img core + 3 drive types) + 1 HTTP transport file. Tests: Docker integration suites (testify/suite, `package api_test`) plus unit tests in `package api` (`http_test.go`, `http_behavior_test.go`, `pathutil_test.go`) that run without Docker.

## WHERE TO LOOK
| Task | Location | Notes |
|------|----------|-------|
| Core RPCs: SetDirectoryType, ListByDate, Delete, FilterNotUploaded (bidir stream) | `img.go` | `SetDirectoryType` forwards to `im.SetDirectoryType`; `ListByDate` defaults MaxReturn=100, Offset=0, calls `im.RangeByDate`; `Delete` aggregates per-path errors from `DeleteImg` |
| HTTP dispatch, upload (3 variants), download (full + range) | `http.go` | `httpHandler()` dispatches GET/POST + path prefix; `downloadType` enum (Normal/Thumbnail/LiveVideo) resolved by prefix strip; unknown methods → 405 |
| Custom HTTP headers | `http.go` | `Image-Date`, `Image-Encrypt-Type` (`AES_128_CFB` / `AES_256_GCM` / empty→`None`), `Image-Encrypt-Password`, `Image-Is-Live-Photo` |
| File name encoding | `http.go` | `encodeName`: `"YYYYMMDDhhmmss_name"`. There is no `decodeName` (deleted 2026-11-02: zero callers) |
| SMB drive wiring: SetDriveSMB, ListDriveSMBShares, ListDriveSMBDir, SetDriveSMBShare | `smb.go` | Probe connection is closed (5s Dialer timeout); fully configures share/root BEFORE `im.SetDrive`; `SetDriveSMBShare` best-effort restores the old share if `SetRootPath` fails |
| WebDAV drive wiring: SetDriveWebdav, ListDriveWebdavDir | `webdav.go` | Fully configures root BEFORE `im.SetDrive` |
| NFS drive wiring: SetDriveNFS, ListDriveNFSDir | `nfs.go` | Fully configures root BEFORE `im.SetDrive`; closes the new drive on root-validation failure |
| Browsing-path sanitization | `{smb,webdav,nfs}.go`, `../util/path.go` | `Dir`/`Share` params go through `util.CleanDirPath`/`CleanShareName`; `..` is rejected, `.`/`/` root spellings preserved |
| Test constants + SMB helpers | `util_test.go` | `grpcAddr`, `httpAddr`, `smbSrvAddr`, `pic1ShouldPath`; `initSmbShare`, `cleanSmb`, `initSmbDir`, `getNFSTarget`, `waitfile` (200ms polling, 5s timeout) |
| Integration tests (gRPC + HTTP) | `img_test.go`, `smb_test.go`, `webdav_test.go`, `nfs_test.go`, `encrypt_test.go` | testify/suite; sequential (`-p 1 -failfast`); require Docker SMB/WebDAV/NFS containers |
| Unit tests (no Docker) | `http_test.go`, `http_behavior_test.go`, `pathutil_test.go` | `package api`; `mockDrive` in `http_test.go` implements `StorageDrive` with injectable `deleteErr`/`rangeErr` |
| Embedded test JPEG fixture | `../test/static/static.go` | `//go:embed test_pic_01.jpg` → `var Pic1 []byte` |

## CONVENTIONS
- **Response envelope**: Every gRPC response carries `bool Success` + `string Message`. Handlers construct `&pb.XxxResponse{Success: true}` upfront, then set fields. On error: set `Success = false`, set `Message`, return `nil` error. Exceptions that prove the rule: `FilterNotUploaded` on a `RangeByDate` error returns `Success=false` with NO ID lists (never a fabricated all-unuploaded list).
- **HTTP dispatch**: Single `http.HandlerFunc` in `httpHandler()`. Routes: GET → `httpDownload`, POST + `/thumbnail/` prefix → `httpUploadThumbnail`, POST + `/live/` prefix → `httpUploadLiveVideo`, POST + other → `httpUpload`. No third-party router. All three upload handlers apply one `EffectiveFileDate` (zero/pre-1990 dates → now) before `encodeName`, so directory date and filename timestamp never diverge.
- **Custom HTTP headers**: `Image-Date` (timestamp `"2006:01:02 15:04:05"`), `Image-Encrypt-Type` (`"AES_128_CFB"` or empty → `imgmanager.None`), `Image-Encrypt-Password`, `Image-Is-Live-Photo` (bool string parsed by `strconv.ParseBool`). Used by all upload and download handlers.
- **File naming**: `encodeName(time, name)` → `"YYYYMMDDhhmmss_name"`. `FilterNotUploaded` uses `encodeName` to match local photo names against the remote filesystem listing built by `RangeByDate`. It preserves request order in `NotUploadedIDs` and reports duplicate encoded names (same name, different IDs; last wins) in `Message`.
- **Drive setup pattern (configure-before-swap)**: Each `SetDrive*` handler constructs the drive via its package constructor, fully configures it (share/root validation, which involves network round trips), and only then calls `a.im.SetDrive(d)`. On failure the old drive stays active. No factory or registry. Only one active drive.
- **Drive type-assertion**: `ListDrive*Dir` and `ListDriveSMBShares` handlers call `a.im.Drive()`, type-assert to the concrete struct (e.g. `dri.(*smb.Smb)`), then call driver-specific methods. The `StorageDrive` interface has no `ListDir` or `ListShare` method.
- **Range downloads (http.go)**: Thumbnails reject Range with `400 Bad Request`. Normal and live video parse `Range: bytes=start-end`, call `GetOffset`/`GetLiveVideoOffset`, respond `206 Partial Content` with `Content-Range` header. Handles both `bytes=start-` and `bytes=start-end` forms. Malformed Range (bad end, wrong dash count) → 400. `start >= size` → 416 with `Content-Range: bytes */<size>`; `end < start` → 400. GCM-encrypted files support Range; CFB-encrypted files reject offset>0.
- **CFB intent (from the code, locked)**: CFB *encryption* is rejected at upload (`EncryptedReaderWraper`: "CFB encryption is deprecated, use GCM"); legacy CFB *decryption* of old files is still supported. `encrypt_test.go` seeds legacy CFB blobs directly on the share instead of uploading them.
- **Test execution**: Integration tests are in `package api_test` and require Docker containers from `test/docker-compose.yml`; run sequentially: `go test -v ./server/api/ -p 1 -failfast`. Unit tests are in `package api` and run without Docker: `go test ./server/api/ -run 'TestHTTP|TestDelete|TestFilter|TestSanitize'`.

## ANTI-PATTERNS (verified present; do not copy them into new code)
- **Polling-based assertions**: `waitfile` polls HTTP GET every 200ms with a timeout (default 5s). Flaky under load; no exponential backoff.
- **`FilterNotUploaded` walks the entire remote directory on every call**: `RangeByDate(time.Now(), ...)` with no early termination builds the full uploaded set before checking client names. Scales poorly with large photo sets.
- **SMB probe in `SetDriveSMB`**: dials the SMB port only to check reachability (5s timeout, connection closed immediately). It is a liveness probe, not an authentication check.
