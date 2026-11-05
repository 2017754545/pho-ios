import 'package:flutter/material.dart';
import 'package:img_syncer/asset.dart';
import 'package:img_syncer/event_bus.dart';
import 'package:img_syncer/files_data_source.dart';
import 'package:img_syncer/folder_upload_picker_route.dart';
import 'package:img_syncer/gallery_viewer_route.dart';
import 'package:img_syncer/global.dart';
import 'package:img_syncer/l10n/app_localizations.dart';
import 'package:img_syncer/setting_storage_route.dart';
import 'package:img_syncer/state_model.dart';
import 'package:img_syncer/storage/storage.dart';
import 'package:img_syncer/util.dart';
import 'package:img_syncer/widgets/thumbnail_skeleton.dart';
import 'package:provider/provider.dart';

/// Files tab: browse the remote drive by folder, next to the Cloud tab.
///
/// v2: the listing comes from the server (POST /__dir/list), so folders
/// created here (POST /__dir/mkdir) and files uploaded here (exact-dir
/// upload) show up immediately, including empty folders. The tree is no
/// longer derived from the Cloud tab's remote asset list; that list is
/// only used to match photo/video entries to thumbnails and the viewer.
///
/// Navigation up is a breadcrumb bar (root "文件" + each segment, tap
/// jumps to that level) plus the back arrow plus system-back handling
/// (PopScope). The header sits inside a SafeArea: without it the top
/// row sat under the status bar / Dynamic Island on a real iPhone and
/// the back affordance was unreachable (v1 user report).
class FilesBody extends StatefulWidget {
  const FilesBody({
    super.key,
    this.dataSource = const StorageFilesDataSource(),
  });

  /// Injectable for widget tests; production uses the storage-backed default.
  final FilesDataSource dataSource;

  @override
  State<FilesBody> createState() => FilesBodyState();
}

class FilesBodyState extends State<FilesBody> {
  final List<String> _segments = [];
  List<DirEntry>? _entries;
  bool _loading = false;
  String? _error;
  int _loadToken = 0;
  bool _loadRequested = false;

  /// Current folder, relative to the drive root ("" = root).
  String get _dir => _segments.join('/');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeLoad();
      _loadDir();
    });
  }

  void _maybeLoad() {
    if (_loadRequested || !mounted) return;
    final assetModel = context.read<AssetModel>();
    final settingModel = context.read<SettingModel>();
    if (!settingModel.isRemoteStorageSetted) return;
    if (assetModel.remoteAssets.isNotEmpty ||
        assetModel.remoteGetting != null) {
      return;
    }
    _loadRequested = true;
    assetModel.getRemotePhotos();
  }

  Future<void> _refresh() async {
    await context.read<AssetModel>().refreshRemote(false);
    await _loadDir();
  }

  /// Loads the current folder's listing. A generation token drops
  /// stale results when the user navigates faster than the server
  /// answers, so an old folder's entries never overwrite the new one.
  Future<void> _loadDir() async {
    if (!mounted) return;
    if (!context.read<SettingModel>().isRemoteStorageSetted) {
      setState(() {
        _entries = null;
        _loading = false;
        _error = null;
      });
      return;
    }
    final token = ++_loadToken;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await widget.dataSource.listDir(_dir);
      if (!mounted || token != _loadToken) return;
      entries.sort(_compareEntries);
      setState(() {
        _entries = entries;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || token != _loadToken) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  /// Folders first, then files; each group name-descending (v1 order).
  static int _compareEntries(DirEntry a, DirEntry b) {
    if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
    return b.name.compareTo(a.name);
  }

  void _goTo(List<String> segments) {
    setState(() {
      _segments
        ..clear()
        ..addAll(segments);
    });
    _loadDir();
  }

  void _goUp() {
    if (_segments.isEmpty) return;
    setState(() => _segments.removeLast());
    _loadDir();
  }

  String _formatSize(int? size) {
    if (size == null) return '';
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) {
      return '${(size / 1024).toStringAsFixed(1)} KB';
    }
    if (size < 1024 * 1024 * 1024) {
      return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(size / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  void _openViewer(BuildContext context, Asset asset, List<Asset> all) {
    final index = all.indexOf(asset);
    if (index < 0) return;
    Navigator.push(
      context,
      PageRouteBuilder(
        opaque: false,
        transitionDuration: const Duration(milliseconds: 300),
        reverseTransitionDuration: const Duration(milliseconds: 300),
        transitionsBuilder: (BuildContext context, Animation<double> animation,
            Animation<double> secondaryAnimation, Widget child) {
          return FadeTransition(
            opacity: animation,
            child: child,
          );
        },
        pageBuilder: (BuildContext context, _, __) => GalleryViewerRoute(
          useLocal: false,
          originIndex: index,
        ),
      ),
    );
  }

  /// Matches a listing entry to a remote asset by full relative path,
  /// for thumbnails and viewer opening. Returns null when the file is
  /// not in the Cloud tab's list (e.g. deeper than RangeByDate walks).
  Asset? _matchAsset(List<Asset> assets, String name) {
    final want = _dir.isEmpty ? name : '$_dir/$name';
    for (final asset in assets) {
      final path = asset.remote?.path;
      if (path == null) continue;
      if (_normalizeRemotePath(path) == want) return asset;
    }
    return null;
  }

  String _normalizeRemotePath(String path) =>
      path.replaceAll('\\', '/').replaceAll(RegExp(r'^/+'), '');

  /// Only photos/videos can be previewed (same rule the viewer uses:
  /// [isVideoByPath] plus the common image extensions).
  bool _isPreviewable(String name) {
    if (isVideoByPath(name)) return true;
    final dot = name.lastIndexOf('.');
    if (dot < 0) return false;
    const imageExts = {
      'jpg',
      'jpeg',
      'png',
      'gif',
      'heic',
      'heif',
      'dng',
      'webp',
      'bmp',
      'tif',
      'tiff',
    };
    return imageExts.contains(name.substring(dot + 1).toLowerCase());
  }

  Future<void> _showCreateFolderDialog() async {
    final l10n = AppLocalizations.of(context)!;
    var name = '';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final trimmed = name.trim();
          // Single-segment rules mirroring the server's SanitizeBrowseDir
          // (non-empty, no separators, no "." / "..", not ".thumbnail").
          final invalid = trimmed.isNotEmpty && _isInvalidFolderName(trimmed);
          final canCreate = trimmed.isNotEmpty && !invalid;
          return AlertDialog(
            title: Text(l10n.createFolderTitle),
            content: TextField(
              autofocus: true,
              decoration: InputDecoration(
                hintText: l10n.createFolderHint,
                errorText: invalid ? l10n.createFolderInvalid : null,
              ),
              onChanged: (value) => setDialogState(() => name = value),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: Text(l10n.cancel),
              ),
              TextButton(
                onPressed: canCreate
                    ? () => Navigator.of(dialogContext).pop(true)
                    : null,
                child: Text(l10n.createFolder),
              ),
            ],
          );
        },
      ),
    );
    if (confirmed != true || !mounted) return;
    final target =
        _dir.isEmpty ? name.trim() : '$_dir/${name.trim()}';
    try {
      await widget.dataSource.createDir(target);
    } catch (e) {
      if (!mounted) return;
      SnackBarManager.showSnackBar('${l10n.createFolder}: $e');
      return;
    }
    await _loadDir();
  }

  bool _isInvalidFolderName(String name) {
    if (name.contains('/') || name.contains('\\')) return true;
    if (name == '.' || name == '..') return true;
    if (name == '.thumbnail') return true;
    return false;
  }

  Future<void> _openUploadPicker() async {
    final uploaded = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => FolderUploadPickerRoute(
          dir: _dir,
          dataSource: widget.dataSource,
        ),
      ),
    );
    if (uploaded != true || !mounted) return;
    // New files must appear in the Cloud tab too: same event the
    // gallery manual upload fires, plus a local refresh of both lists.
    eventBus.fire(RemoteRefreshEvent(refreshUnSync: false));
    await _loadDir();
    if (!mounted) return;
    await context.read<AssetModel>().refreshRemote(false);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return PopScope(
      // In a subfolder, system back goes up one folder first.
      canPop: _segments.isEmpty,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _goUp();
      },
      child: Consumer2<AssetModel, SettingModel>(
        builder: (context, assetModel, settingModel, child) {
          final storageSetted = settingModel.isRemoteStorageSetted;
          return SafeArea(
            top: true,
            bottom: false,
            left: false,
            right: false,
            child: Column(
              children: [
                Row(
                  children: [
                    if (_segments.isNotEmpty)
                      IconButton(
                        icon: const Icon(Icons.arrow_back),
                        onPressed: _goUp,
                      ),
                    Expanded(child: _buildBreadcrumb(l10n)),
                    if (_loading)
                      const Padding(
                        padding: EdgeInsets.only(right: 8),
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    IconButton(
                      icon: const Icon(Icons.create_new_folder),
                      tooltip: l10n.createFolder,
                      onPressed:
                          storageSetted ? _showCreateFolderDialog : null,
                    ),
                    IconButton(
                      icon: const Icon(Icons.upload),
                      tooltip: l10n.uploadToFolder,
                      onPressed: storageSetted ? _openUploadPicker : null,
                    ),
                  ],
                ),
                const Divider(height: 1),
                Expanded(
                  child: _buildBody(
                    context,
                    l10n,
                    colorScheme,
                    textTheme,
                    assetModel,
                    settingModel,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// Tappable breadcrumb: root "文件" + each path segment; tapping a
  /// segment jumps straight to that level.
  Widget _buildBreadcrumb(AppLocalizations l10n) {
    final crumbs = <Widget>[
      _crumb(
        l10n.files,
        () => _goTo([]),
        isCurrent: _segments.isEmpty,
      ),
    ];
    for (var i = 0; i < _segments.length; i++) {
      crumbs.add(
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 2),
          child: Text('/'),
        ),
      );
      crumbs.add(
        _crumb(
          _segments[i],
          () => _goTo(_segments.sublist(0, i + 1)),
          isCurrent: i == _segments.length - 1,
        ),
      );
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: crumbs),
    );
  }

  Widget _crumb(String label, VoidCallback onTap,
      {required bool isCurrent}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        child: Text(
          label,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: isCurrent ? null : Theme.of(context).colorScheme.primary,
            fontWeight: isCurrent ? FontWeight.bold : null,
          ),
        ),
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    AppLocalizations l10n,
    ColorScheme colorScheme,
    TextTheme textTheme,
    AssetModel assetModel,
    SettingModel settingModel,
  ) {
    if (!settingModel.isRemoteStorageSetted) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.folder_open,
              size: 64,
              color: colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const SettingStorageRoute(),
                ),
              ),
              child: Text(l10n.setRemoteStroage),
            ),
          ],
        ),
      );
    }
    if (_loading && _entries == null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              l10n.refreshing,
              style: textTheme.bodyMedium
                  ?.copyWith(color: colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }
    if (_error != null && _entries == null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.error_outline,
              size: 64,
              color: colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                _error!,
                textAlign: TextAlign.center,
                style: textTheme.bodyMedium
                    ?.copyWith(color: colorScheme.onSurfaceVariant),
              ),
            ),
            const SizedBox(height: 16),
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _loadDir,
            ),
          ],
        ),
      );
    }
    final entries = _entries ?? const <DirEntry>[];
    if (entries.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.folder_open,
              size: 64,
              color: colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              l10n.emptyFolder,
              style: textTheme.bodyMedium
                  ?.copyWith(color: colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }
    final assets = assetModel.remoteAssets;
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: entries.length,
        itemBuilder: (context, index) {
          final entry = entries[index];
          if (entry.isDir) {
            return ListTile(
              leading: const Icon(Icons.folder),
              title: Text(
                entry.name,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                setState(() => _segments.add(entry.name));
                _loadDir();
              },
            );
          }
          final matched = _matchAsset(assets, entry.name);
          if (matched != null) {
            return ListTile(
              leading: SizedBox(
                width: 48,
                height: 48,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      matched.loadThumbnailFinished()
                          ? Image(
                              image: matched.thumbnailProvider(),
                              fit: BoxFit.cover,
                            )
                          : const ThumbnailSkeleton(),
                      if (matched.isVideo())
                        const Center(
                          child: Icon(
                            Icons.play_circle_filled,
                            color: Colors.white,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              title: Text(
                entry.name,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(_formatSize(entry.size)),
              onTap: () => _openViewer(context, matched, assets),
            );
          }
          // Non-media entries, and media files the Cloud tab's list
          // does not know (no thumbnail/viewer source): generic icon,
          // tap explains only photos/videos can be previewed.
          return ListTile(
            leading: Icon(
              entry.name.isNotEmpty && isVideoByPath(entry.name)
                  ? Icons.videocam
                  : _isPreviewable(entry.name)
                      ? Icons.image
                      : Icons.insert_drive_file,
            ),
            title: Text(
              entry.name,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(_formatSize(entry.size)),
            onTap: () => SnackBarManager.showSnackBar(
              l10n.previewNotSupported,
            ),
          );
        },
      ),
    );
  }
}
