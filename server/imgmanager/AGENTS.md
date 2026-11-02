# IMGMANAGER — CORE ENGINE

**Rewritten:** 2026-11-02 (matches code after the fix-everything pass; earlier versions of this file contradicted the code and must not be trusted)

## OVERVIEW
`ImgManager` is the central orchestrator: it owns the active `StorageDrive`, routes all I/O through it, handles encryption/decryption transparently, and runs a channel-based worker pool for async delete operations. The remote filesystem IS the database — `RangeByDate()` walks date-based directory trees directly.

## STRUCTURE
```
imgmanager/
├── imgmanager.go   # ImgManager struct, upload/download/delete, RangeByDate, genPath, worker pool; DeleteImg returns []error; Close() idempotent + drains queue
├── interface.go    # StorageDrive interface (7 methods), Image struct, UnimplementedDrive (null-object), suffix constants
├── encrypt.go      # Dual-scheme: legacy AES-128-CFB decrypt-only + AES-256-GCM (PHO1 magic header, PBKDF2-SHA256 100k); GCM chunkSize validated (0 rejected, 16 MiB cap); .aes path suffix
└── metadata.go     # ImageMetadata struct only, embedded in Image (fields stay empty); EXIF extraction was removed — no callers
```

## WHERE TO LOOK
| Task | Location | Notes |
|------|----------|-------|
| Change file path layout | `imgmanager.go` `genPath()` | Single function controls YYYY/MM/DD vs YYYYMMDD, live_ prefix, .aes suffix; uses one effective date (`EffectiveFileDate`: zero/pre-1990 → now) for both directory and filename |
| Add a storage backend | `server/drive/<name>/` impl `StorageDrive` (defined in `interface.go`) | 7 methods: Upload, IsExist, Download, DownloadWithOffset, Delete, Range, Close. `IsExist` IS in the interface |
| Change upload flow | `imgmanager.go` `Upload()` | Encrypt if configured → genPath → dri.Upload; synchronous; negative contentSize rejected; `Upload`'s size param is advisory to the drive |
| Change download flow | `imgmanager.go` `GetImg()` | dri.Download → decrypt → set ContentType via `util.ContentTypeByExtension` on the name without `.aes` |
| Streaming/offset reads | `imgmanager.go` `GetOffset()` / `GetLiveVideoOffset()` | GCM Range supported (chunkSize validated; size math uses the header chunkSize); CFB rejects non-zero offsets; `.aes` videos are found via `util.IsVideo` (strips `.aes`) |
| Directory listing ("file-as-DB") | `imgmanager.go` `RangeByDate()` | Walks both dir formats descending by date, no database; uses normalized date `t` consistently (zero date → now); type-02 entries must be dirs; inner Range errors propagate; live_ early-stop propagates |
| Encryption | `encrypt.go` | GCM: PBKDF2-SHA256 (100k iterations), `PHO1` magic header, 1 MiB chunks. CFB: legacy MD5-based derivation, decryption of old files only; CFB encryption is rejected at upload. `DecryptedContentSize` never returns negative |
| Get current drive | `imgmanager.go` `Drive()` | Returns `StorageDrive` interface (callers type-assert to concrete drive for extended methods) |
| Worker pool | `imgmanager.go` `runWorker()` / `doAction` | Buffered channel, default 2 workers; handles ONLY `actDelete` (async deletes). Uploads are synchronous. `Close()` (sync.Once) drains pending deletes, waits for workers, is safe to call twice |

## CONVENTIONS
- **Single active drive**: `SetDrive(d)` hot-swaps. No multi-cloud. Before configured, `UnimplementedDrive` returns "no available drive" for all ops.
- **genPath centralization**: Every file operation routes path construction through `genPath(name, date, options)`. Two directory layouts: `YYYY/MM/DD/` (Type 01, default) or `YYYYMMDD/` (Type 02). Live Photos nested under `live_<name>/`. Encrypted files append `.aes`.
- **EncryptOption pattern**: `Options` struct + `OptionFunc` functional options (`WithEncrypt()`, `IsLivePhoto()`). Upload methods accept variadic `...OptionFunc`.
- **EncryptType enum**: `None | AES_128_CFB | AES_256_GCM`. GCM uses `PHO1` magic header; CFB uses random IV. GCM supports `GetOffset()` for HTTP Range / video streaming; CFB does not. GCM keys via PBKDF2-SHA256 (100k iterations); CFB decryption keeps the legacy MD5-based derivation. Encryption is transparent at the ImgManager layer — callers just pass `WithEncrypt(...)`. Scheme auto-detected from file header on read.
- **Image struct**: Universal file handle combining `Content` (io.ReadCloser stream), `Path`, `Size`, `ContentType`, and embedded `ImageMetadata` (fields stay empty; EXIF extraction removed). Returned by GetImg/GetThumbnail/GetOffset/GetLiveVideoOffset.
- **Thumbnail mirror**: `.thumbnail/` directory mirrors the source tree. `UploadThumbnail` prepends this prefix; `GetThumbnail` reads from it. Thumbnail generation is client-side (no server-side generation code).
- **Worker pool**: 2 workers (`defaultWorkerNum`) started in `NewImgManager`, buffered `actCh` (cap 10). Only `actDelete` is enqueued (`DeleteSingleImgAsync` is the sole enqueue entry point; its send is close-safe and drops after `Close()`). There is no upload/thumbnail worker.
- **Delete semantics**: `DeleteImg(paths []string) []error` — one error slot per path (nil = ok). `DeleteSingleImg` logs thumbnail/live-affiliate failures but returns the main-file result. The `Delete` RPC aggregates the per-path errors.
- **Content-Type resolution**: exactly one resolver, `util.ContentTypeByExtension` (explicit map first, system mime table fallback; `.heic`/`.heif`/`.dng` included). Do not reintroduce `mime.TypeByExtension` call sites in this package.
- **Concurrency**: same-name same-second concurrent uploads are last-writer-wins (covered by a unit test with the mock drive; real-drive behavior needs Docker). The worker pool does not serialize uploads.

## ANTI-PATTERNS (verified present; do not copy them into new code)
- **Custom legacy KDF for CFB**: iterative MD5 derivation, kept only so old CFB files can still be decrypted. Do not use it for new encryption (GCM + PBKDF2 is the only supported encrypt path).
- **Encrypted CFB files break streaming**: `GetOffset()` rejects CFB-encrypted paths (non-zero offset). GCM-encrypted files (PHO1 header) support streaming. Video streaming silently fails with CFB encryption.
- **Worker count is fixed at construction**: No runtime tuning of `WorkerNum`.
- **RangeByDate walks entire tree every call**: No caching. Every invocation re-lists all year/month/day directories, descending to find photos before the given date.
