# DRIVE BACKENDS

**Rewritten:** 2026-11-02 (matches code after the fix-everything pass; earlier versions of this file contradicted the code and must not be trusted)

## OVERVIEW
Three `StorageDrive` implementations (SMB, WebDAV, NFS) that read/write photos to remote filesystems. Each drive is constructed directly in `server/api/` handlers and injected via `im.SetDrive(d)` only after full configuration. Only one drive is active at a time. All three guard their connection handles with locks + in-flight refcounts so `SetDrive` swapping / `Close` cannot race in-flight I/O (verified with `go test -race`).

## STRUCTURE
```
server/drive/
├── smb/smb.go           # go-smb2, NTLM auth, lazy connect with 5min TTL; cfgMu/fsMu + fsRefs; downloadLock held until stream Close
├── webdav/webdav.go     # gowebdav fork, Basic Auth, InsecureSkipVerify only when insecure=true; immutable client; rootPath under mu
├── nfs/nfs.go           # go-nfs-client fork, AUTH_UNIX root, 90s TTL + FSInfo health probe; connMu/connRefs + reconnMu; SetRootPath calls checkConn + nil-guards cli

└── drive_test.go        # testify/suite, Docker-based integration tests
```

## WHERE TO LOOK

| Task | Location | Notes |
|------|----------|-------|
| Add a new storage backend | Create `server/drive/<name>/<name>.go` + constructor in `server/api/<name>.go` | Must implement `StorageDrive` (7 methods; see `server/imgmanager/interface.go`); `Upload`'s `size` param is advisory |
| Debug SMB connection issues | `smb/smb.go` `checkConn()` | 5min TTL; `Dial()` closes the TCP conn on SMB-dial failure; `Connect()` logs off the session on mount failure |
| Debug WebDAV auth/protocol | `webdav/webdav.go` `SetTransport()` | TLS verification disabled only when `insecure=true`; `mkdirLock` serializes MkdirAll; `Close()` is a documented no-op (stateless HTTP client) |
| Debug NFS reconnection | `nfs/nfs.go` `checkConn()` | 90s TTL, FSInfo() health probe, full remount on expiry (expensive); reconnects serialized by `reconnMu` |
| Add/change tests | `drive_test.go` `DriveTest` suite | `TestSMB()`/`TestWebdav()`/`TestNFS()` share `testDrive()` helper, needs Docker; per-package unit tests (`*_path_test.go`, reconnect/lock tests) run without Docker |
| Wire a new drive into the API | `server/api/<name>.go` | Construct drive, fully configure (share/root), type-assert for extras (ListShare, Cli, SetRootPath), then call `im.SetDrive(d)` |

## CONVENTIONS

- **No registry/factory**: each drive is constructed directly with a `New*` function. The `server/api/` handler holds the constructor call.
- **Hot-swap**: only ONE `StorageDrive` active at a time. `ImgManager.SetDrive()` replaces it. Swapping must not race in-flight I/O: SMB/NFS snapshot their handles under a lock and refcount in-flight users; `Close`/`Umount` waits (2s) for refs to drain.
- **Connection management**: SMB and NFS use lazy connect with TTL timestamps (SMB 5min, NFS 90s) via `checkConn()`; WebDAV is stateless HTTP (client immutable after construction).
- **Range direction**: all `Range()` methods sort `fs.FileInfo` descending by `ModTime()` (newest first).
- **Offset contract (unified)**: `DownloadWithOffset` with `offset == size` returns an empty stream plus the total size; `offset > size` is an error; negative offsets are rejected. WebDAV classifies the boundary with a single Stat only when the range read fails or the size is unknown, so the zero-Stat happy path is preserved.
- **Partial-file cleanup**: all three drives delete the partial file when an upload copy or close fails (SMB close-error branch, NFS close-error capture, WebDAV best-effort `Remove` on `WriteStream` error).
- **Path sanitization**: `SetRootPath` on all three backends runs `util.CleanDirPath` (rejects any `..` element, preserves `.`/`/` root spellings) before any network use; `SetShare` (SMB) runs `util.CleanShareName`. Browsing handlers sanitize `Dir`/`Share` the same way.
- **Extra methods**: each drive exposes capabilities beyond the `StorageDrive` interface (e.g. `ListShare()` on SMB, `Cli()` on NFS). Handlers use type-assertion to access them.
- **Path handling**: SMB uses `filepath.Join` natively; WebDAV and NFS normalize to `/`-separated with trailing slash on root. `normalizeRootPath` returns `/` for empty input.
- **Thumbnails**: not drive-level concern. Thumbnail paths are built by `ImgManager` using the same directory structure under `.thumbnail/`.

## ANTI-PATTERNS (verified present; do not copy them into new code)

- **NFS: AUTH_UNIX root (uid 0, gid 0)**. No real authentication. Acceptable for local network only.
- **WebDAV: `InsecureSkipVerify` when `insecure=true`**. TLS certificate verification is disabled only for drives explicitly configured insecure. Do NOT use over untrusted networks.
- **SMB: `downloadLock` mutex**. `DownloadWithOffset` holds it until the returned stream is closed (via a wrapper `ReadCloser`), so downloads are serialized and callers MUST close the stream. Parallel downloads WILL contend.
- **NFS: custom non-recursive `MkdirAll`**. The `MkdirAll()` method iterates path segments and calls `Mkdir` individually; errors are silently ignored (`continue`). This differs from standard library behavior.
