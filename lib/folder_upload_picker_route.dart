import 'package:flutter/material.dart';
import 'package:img_syncer/asset.dart';
import 'package:img_syncer/files_data_source.dart';
import 'package:img_syncer/global.dart';
import 'package:img_syncer/l10n/app_localizations.dart';
import 'package:img_syncer/state_model.dart';
import 'package:img_syncer/sync/background_runner.dart';
import 'package:img_syncer/util.dart';
import 'package:img_syncer/widgets/thumbnail_skeleton.dart';
import 'package:provider/provider.dart';

/// Folder upload picker: opened from the Files tab's upload action.
/// Lists local photos in a selectable grid; confirming uploads each
/// selected photo to the current folder via the exact-dir mode
/// ([FilesDataSource.uploadToExactDir]), so files land directly in
/// that folder instead of the typed video/image split.
///
/// Feedback mirrors the gallery manual upload: the same upload-filter
/// / already-uploaded skipping ([shouldUploadManually]), a per-failure
/// `uploadFailed` snackbar, a final counts snackbar, and popping with
/// `true` when anything was uploaded (the Files tab then refreshes
/// its listing and the remote list).
class FolderUploadPickerRoute extends StatefulWidget {
  const FolderUploadPickerRoute({
    super.key,
    required this.dir,
    required this.dataSource,
  });

  /// Target folder, relative to the drive root ("" = root).
  final String dir;
  final FilesDataSource dataSource;

  @override
  State<FolderUploadPickerRoute> createState() =>
      FolderUploadPickerRouteState();
}

class FolderUploadPickerRouteState extends State<FolderUploadPickerRoute> {
  final Set<String> _selectedIds = {};
  bool _uploading = false;
  bool _loadRequested = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeLoadLocal());
  }

  void _maybeLoadLocal() {
    if (_loadRequested || !mounted) return;
    final assetModel = context.read<AssetModel>();
    if (assetModel.localAssets.isNotEmpty ||
        assetModel.localGetting != null) {
      return;
    }
    _loadRequested = true;
    assetModel.getLocalPhotos();
  }

  bool _isSelected(Asset asset) => _selectedIds.contains(asset.stableKey());

  void _toggle(Asset asset) {
    setState(() {
      final key = asset.stableKey();
      if (_selectedIds.contains(key)) {
        _selectedIds.remove(key);
      } else {
        _selectedIds.add(key);
      }
    });
  }

  List<Asset> _selectedAssets(List<Asset> displayed) => displayed
      .where((asset) => _selectedIds.contains(asset.stableKey()))
      .toList();

  Future<void> _uploadSelected(List<Asset> displayed) async {
    final l10n = AppLocalizations.of(context)!;
    if (!context.read<SettingModel>().isRemoteStorageSetted) {
      SnackBarManager.showSnackBar(l10n.storageNotSetted);
      return;
    }
    final assets = _selectedAssets(displayed);
    if (assets.isEmpty) return;
    setState(() => _uploading = true);
    // Same skipping as the gallery manual upload (FK-6): filter-excluded
    // or already-uploaded assets are skipped, not re-uploaded.
    final uploadedIds = {
      for (final id in stateModel.syncedIDs) id: true,
    };
    var uploadedCount = 0;
    var skippedCount = 0;
    await keepScreenOn(true);
    try {
      for (var asset in assets) {
        final entity = asset.local;
        if (entity == null) continue;
        if (!await shouldUploadManually(asset, uploadedIds)) {
          skippedCount++;
          continue;
        }
        try {
          await widget.dataSource.uploadToExactDir(entity, widget.dir);
          uploadedCount++;
        } catch (e) {
          SnackBarManager.showSnackBar('${l10n.uploadFailed}: $e');
        }
      }
    } finally {
      await keepScreenOn(false);
    }
    if (!mounted) return;
    setState(() => _uploading = false);
    SnackBarManager.showSnackBar(
        '${l10n.successfullyUpload} $uploadedCount ${l10n.photos}'
        '${skippedCount > 0 ? ' ($skippedCount ${l10n.skippedByUploadFilter})' : ''}');
    Navigator.of(context).pop(uploadedCount > 0);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.dir.isEmpty ? l10n.files : widget.dir),
        actions: [
          Consumer<AssetModel>(
            builder: (context, assetModel, _) {
              final count = _selectedAssets(assetModel.displayLocalAssets)
                  .length;
              return TextButton(
                onPressed: count == 0 || _uploading
                    ? null
                    : () => _uploadSelected(assetModel.displayLocalAssets),
                child: Text(
                  '${l10n.upload}${count > 0 ? ' ($count)' : ''}',
                ),
              );
            },
          ),
        ],
      ),
      body: Consumer<AssetModel>(
        builder: (context, assetModel, _) {
          final displayed = assetModel.displayLocalAssets;
          if (displayed.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (assetModel.localGetting != null)
                    const CircularProgressIndicator()
                  else ...[
                    Icon(
                      Icons.photo_library_outlined,
                      size: 64,
                      color: colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(height: 16),
                    Text(l10n.noFiles),
                  ],
                ],
              ),
            );
          }
          return GridView.builder(
            padding: const EdgeInsets.all(2),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 2,
              mainAxisSpacing: 2,
            ),
            itemCount: displayed.length,
            itemBuilder: (context, index) {
              final asset = displayed[index];
              final selected = _isSelected(asset);
              return GestureDetector(
                onTap: () => _toggle(asset),
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
                    if (selected)
                      Container(
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: colorScheme.primary,
                            width: 3,
                          ),
                        ),
                      ),
                    if (selected)
                      Align(
                        alignment: Alignment.topRight,
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Icon(
                            Icons.check_circle,
                            color: colorScheme.primary,
                          ),
                        ),
                      ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}
