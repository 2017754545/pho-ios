import 'package:flutter/material.dart';
import 'package:img_syncer/asset.dart';
import 'package:img_syncer/files_tree.dart';
import 'package:img_syncer/gallery_viewer_route.dart';
import 'package:img_syncer/l10n/app_localizations.dart';
import 'package:img_syncer/setting_storage_route.dart';
import 'package:img_syncer/state_model.dart';
import 'package:img_syncer/widgets/thumbnail_skeleton.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

/// Files tab: browse the remote drive by folder, next to the Cloud tab.
///
/// The tree is built client-side from the same remote asset list the
/// Cloud tab loads ([AssetModel.remoteAssets]), so no server or protocol
/// change is needed. Tapping a file opens the same viewer the Cloud tab
/// uses; tapping a folder drills into it.
class FilesBody extends StatefulWidget {
  const FilesBody({super.key});

  @override
  State<FilesBody> createState() => FilesBodyState();
}

class FilesBodyState extends State<FilesBody> {
  final List<String> _segments = [];
  bool _loadRequested = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeLoad());
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
        if (_segments.isNotEmpty) {
          setState(() => _segments.removeLast());
        }
      },
      child: Consumer2<AssetModel, SettingModel>(
        builder: (context, assetModel, settingModel, child) {
          final assets = assetModel.remoteAssets;
          final view = folderView<Asset>(
            items: assets,
            pathOf: (asset) => asset.remote?.path ?? '',
            prefix: _segments,
          );
          final title =
              _segments.isEmpty ? l10n.files : _segments.join(' / ');
          return Column(
            children: [
              Row(
                children: [
                  if (_segments.isNotEmpty)
                    IconButton(
                      icon: const Icon(Icons.arrow_back),
                      onPressed: () =>
                          setState(() => _segments.removeLast()),
                    ),
                  Expanded(
                    child: Text(
                      title,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.titleMedium,
                    ),
                  ),
                  if (assetModel.remoteGetting != null)
                    const Padding(
                      padding: EdgeInsets.only(right: 16),
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                ],
              ),
              Expanded(
                child: _buildBody(
                  context,
                  l10n,
                  colorScheme,
                  textTheme,
                  assetModel,
                  settingModel,
                  assets,
                  view,
                ),
              ),
            ],
          );
        },
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
    List<Asset> assets,
    FolderView<Asset> view,
  ) {
    if (assetModel.remoteGetting != null && assets.isEmpty) {
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
    if (assets.isEmpty) {
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
              l10n.noFiles,
              style: textTheme.bodyMedium
                  ?.copyWith(color: colorScheme.onSurfaceVariant),
            ),
            if (assetModel.remoteLastError != null) ...[
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  assetModel.remoteLastError!,
                  textAlign: TextAlign.center,
                  style: textTheme.bodySmall
                      ?.copyWith(color: colorScheme.onSurfaceVariant),
                ),
              ),
            ],
            const SizedBox(height: 16),
            if (!settingModel.isRemoteStorageSetted)
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
    final itemCount = view.folders.length + view.files.length;
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: itemCount,
        itemBuilder: (context, index) {
          if (index < view.folders.length) {
            final folder = view.folders[index];
            return ListTile(
              leading: const Icon(Icons.folder),
              title: Text(folder.name),
              subtitle: Text(l10n.folderFileCount(folder.fileCount)),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => setState(() => _segments.add(folder.name)),
            );
          }
          final asset = view.files[index - view.folders.length];
          final name = p.basename(asset.remote?.path ?? '');
          return ListTile(
            leading: SizedBox(
              width: 48,
              height: 48,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    asset.loadThumbnailFinished()
                        ? Image(
                            image: asset.thumbnailProvider(),
                            fit: BoxFit.cover,
                          )
                        : const ThumbnailSkeleton(),
                    if (asset.isVideo())
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
              name,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(_formatSize(asset.remote?.size)),
            onTap: () => _openViewer(context, asset, assets),
          );
        },
      ),
    );
  }
}
