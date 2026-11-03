import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:img_syncer/design_tokens.dart';
import 'package:img_syncer/proto/img_syncer.pb.dart';
import 'package:img_syncer/state_model.dart';
import 'package:img_syncer/sync/background_runner.dart';
import 'package:img_syncer/storage/storage.dart';
import 'package:img_syncer/util.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:img_syncer/gallery_viewer_route.dart';
import 'package:img_syncer/asset.dart';
import 'package:img_syncer/event_bus.dart';
import 'dart:async';
import 'package:rxdart/rxdart.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import 'package:img_syncer/global.dart';
import 'package:path_provider/path_provider.dart';
import 'package:gal/gal.dart';
import 'package:img_syncer/choose_album_route.dart';
import 'package:img_syncer/setting_storage_route.dart';
import 'package:img_syncer/widgets/thumbnail_skeleton.dart';
import 'package:shared_preferences/shared_preferences.dart';

class GalleryBody extends StatefulWidget {
  GalleryBody({
    Key? key,
    required this.useLocal,
    this.showAppBar = true,
    this.width,
  }) : super(key: key);
  final bool useLocal;
  bool showAppBar = true;
  double? width;

  @override
  GalleryBodyState createState() => GalleryBodyState();
}

enum LocateType { year, month, day }

class LocateInfo {
  LocateInfo({
    this.location = 0,
    this.count = 0,
  });
  double location;
  int count;
}

/// One bucket of the jump-to dialog (a month or a year): the bucket
/// key, the summed photo count of all days in it, and the scroll
/// location of its first day.
class DateLocateGroup {
  const DateLocateGroup({
    required this.key,
    required this.count,
    required this.location,
  });
  final DateTime key;
  final int count;
  final double location;
}

/// Group day entries into month/year buckets, preserving first-seen
/// order and summing counts. Every entry contributes to exactly one
/// bucket; the last bucket is emitted like any other (an earlier
/// implementation folded the last bucket's count into the previous
/// bucket and never emitted the last bucket itself).
List<DateLocateGroup> groupDateLocateEntries(
  Map<DateTime, LocateInfo> entries,
  DateTime Function(DateTime day) bucket,
) {
  final groups = <DateLocateGroup>[];
  final indexByBucket = <DateTime, int>{};
  for (final entry in entries.entries) {
    final key = bucket(entry.key);
    final index = indexByBucket[key];
    if (index == null) {
      indexByBucket[key] = groups.length;
      groups.add(DateLocateGroup(
        key: key,
        count: entry.value.count,
        location: entry.value.location,
      ));
    } else {
      final existing = groups[index];
      groups[index] = DateLocateGroup(
        key: existing.key,
        count: existing.count + entry.value.count,
        location: existing.location,
      );
    }
  }
  return groups;
}

/// Resolve a set of selected stable asset ids against the *current*
/// list, in list order. Ids absent from the list (removed, filtered
/// out, or never present) resolve to nothing — never to a different
/// asset at a stale position. This is the only way selection is
/// turned into assets for delete/share/download/upload.
List<Asset> resolveSelectedAssets(
    List<Asset> all, Set<String> selectedIds) {
  if (selectedIds.isEmpty || all.isEmpty) return <Asset>[];
  return all.where((asset) => selectedIds.contains(asset.stableKey())).toList();
}

/// Drop selected ids that no longer occur in the current list.
Set<String> pruneStaleSelectionIds(
    List<Asset> all, Set<String> selectedIds) {
  if (selectedIds.isEmpty) return selectedIds;
  final current = all.map((asset) => asset.stableKey()).toSet();
  return selectedIds.intersection(current);
}

/// Locater drag target: which month entry a drag offset lands on.
/// Returns -1 when there are no entries; otherwise the index clamped
/// to [0, count - 1] so dragging past either end cannot go out of
/// bounds. A non-positive or non-finite step height (empty list /
/// degenerate viewport) maps to the first entry.
int locaterIndexForOffset(
    double realOffset, double perMonthHeight, int count) {
  if (count <= 0) return -1;
  if (perMonthHeight <= 0 ||
      perMonthHeight.isNaN ||
      perMonthHeight.isInfinite) {
    return 0;
  }
  var index = (realOffset / perMonthHeight).floor();
  if (index < 0) index = 0;
  if (index > count - 1) index = count - 1;
  return index;
}

class GalleryBodyState extends State<GalleryBody>
    with AutomaticKeepAliveClientMixin {
  bool _showToTopBtn = false;
  @override
  bool get wantKeepAlive => true;
  final ScrollController _scrollController = ScrollController();
  final _scrollSubject = PublishSubject<double>();
  StreamSubscription<double>? _scrollDebounceSubscription;
  StreamSubscription<double>? _scrollPositionSubscription;
  int columCount = 4;
  double scrollOffset = 0;
  double maxScrollOffset = 0;
  bool dragging = false;

  /// Selection keyed by stable asset id (see Asset.stableKey), never
  /// by position index: displayLocalAssets is recomputed on every
  /// access and its membership shifts as titles load, the
  /// camera-excluded set refreshes, or the camera-only switch
  /// toggles, so a position index captured earlier can point at a
  /// different asset by action time.
  final Set<String> _selectedIds = {};

  final GlobalKey<RefreshIndicatorState> _refreshIndicatorKey =
      GlobalKey<RefreshIndicatorState>();
  PersistentBottomSheetController? _bottomSheetController;

  Map<DateTime, LocateInfo> _dateLocateMap = {};
  LocateType _locateType = LocateType.month;

  double locaterOffset = 0;

  @override
  void initState() {
    super.initState();
    _scrollDebounceSubscription = _scrollSubject.stream
        .debounceTime(const Duration(milliseconds: 150))
        .listen((scrollPosition) {
      if (!mounted) return;
      if (_scrollController.position.pixels >=
          _scrollController.position.maxScrollExtent - 4000) {
        // getPhotos();
      }
      setState(() {
        scrollOffset = scrollPosition;
      });
    });
    _scrollPositionSubscription = _scrollSubject.stream.listen((scrollPosition) {
      if (!mounted) return;
      if (dragging) {
        return;
      }
      if (maxScrollOffset == 0 || maxScrollOffset < scrollPosition) {
        return;
      }
      final totalHeight = MediaQuery.of(context).size.height;
      final paddingTop = MediaQuery.of(context).padding.top + 70;
      const paddingBottom = 130;
      // final paddingBottom = MediaQuery.of(context).padding.bottom + 67;
      final avaliabileHeight = totalHeight - paddingBottom - paddingTop;
      if ((locaterOffset -
                  (paddingTop +
                      (scrollPosition / maxScrollOffset) * avaliabileHeight))
              .abs() <
          5) {
        return;
      }
      setState(() {
        locaterOffset =
            paddingTop + (scrollPosition / maxScrollOffset) * avaliabileHeight;
      });
    });
    _scrollController.addListener(() {
      _scrollSubject.add(_scrollController.position.pixels);
      if (_scrollController.offset > 1000 && !_showToTopBtn) {
        setState(() {
          _showToTopBtn = true;
        });
      } else if (_scrollController.offset <= 1000 && _showToTopBtn) {
        setState(() {
          _showToTopBtn = false;
        });
      }
    });
    settingModel.addListener(_onSettingChanged);
  }

  void _onSettingChanged() {
    if (settingModel.galleryColumCount != columCount) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          0,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
        );
      }
      setState(() {
        columCount = settingModel.galleryColumCount;
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final paddingTop = MediaQuery.of(context).padding.top + 70;
    if (locaterOffset < paddingTop) {
      setState(() {
        locaterOffset = paddingTop;
      });
    }
  }

  @override
  void dispose() {
    // Dispose order: cancel our own subscriptions and controllers
    // before super.dispose(); disposing after super.dispose() leaves
    // the state torn down while its resources are still live.
    _scrollDebounceSubscription?.cancel();
    _scrollPositionSubscription?.cancel();
    settingModel.removeListener(_onSettingChanged);
    _scrollController.dispose();
    _scrollSubject.close();
    super.dispose();
  }

  void _scrollToTop() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
    );
  }

  bool _isRefreshing = false;
  Future<void> refresh() async {
    if (stateModel.isDownloading() || stateModel.isUploading()) {
      return;
    }
    if (_isRefreshing) {
      return;
    }
    _isRefreshing = true;
    try {
      // Await the refresh: without this the guard above was reset
      // immediately and concurrent refreshes (and a RefreshIndicator
      // that completes before any data arrived) were possible.
      if (widget.useLocal) {
        await assetModel.refreshLocal(false);
      } else {
        await assetModel.refreshRemote(false);
      }
    } finally {
      _isRefreshing = false;
    }
  }

  /// The list this tab currently displays, snapshotted once per call.
  /// Callers that act on selection must snapshot here at action time
  /// and resolve ids against that snapshot (see [selectedAssets]).
  List<Asset> get _currentAssets => widget.useLocal
      ? assetModel.displayLocalAssets
      : assetModel.remoteAssets;

  /// Drop ids whose asset is no longer in the current list.
  void _pruneStaleSelection() {
    if (_selectedIds.isEmpty) return;
    final pruned = pruneStaleSelectionIds(_currentAssets, _selectedIds);
    if (pruned.length != _selectedIds.length) {
      _selectedIds
        ..clear()
        ..addAll(pruned);
    }
  }

  /// Assets currently selected, resolved against the current list at
  /// call time. Stale ids resolve to nothing and are dropped.
  List<Asset> selectedAssets() {
    _pruneStaleSelection();
    return resolveSelectedAssets(_currentAssets, _selectedIds);
  }

  /// Number of selected assets that still exist in the current list.
  int get selectedCount => selectedAssets().length;

  bool isAssetSelected(Asset asset) => _selectedIds.contains(asset.stableKey());

  void toggleSelectionForAsset(Asset asset) {
    final key = asset.stableKey();
    if (!_selectedIds.remove(key)) {
      _selectedIds.add(key);
    }
    updateSelection();
  }

  void updateSelection() {
    _pruneStaleSelection();
    var hasSelected = _selectedIds.isNotEmpty;
    stateModel.setSelectionMode(hasSelected);
    setState(() {});

    if (!hasSelected && _bottomSheetController != null) {
      _bottomSheetController?.close(); // 关闭BottomSheet
      _bottomSheetController = null;
    } else {
      if (hasSelected && _bottomSheetController == null) {
        _showBottomSheet(context); // 显示BottomSheet
      }
    }
    setState(() {});
  }

  void clearSelection() {
    _selectedIds.clear();
    stateModel.setSelectionMode(false);
    if (_bottomSheetController != null) {
      _bottomSheetController?.close(); // 关闭BottomSheet
      _bottomSheetController = null;
    }
    setState(() {});
  }

  void _showDeleteDialog(BuildContext context) {
    showDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(l10n.deleteThisPhotos),
        content: Text(l10n.cantBeUndone),
        actions: <Widget>[
          TextButton(
            onPressed: () async {
              // Resolve against a fresh snapshot at confirm time:
              // the list may have shifted since the dialog opened.
              final toDelete = selectedAssets();
              var deletedCount = 0;
              try {
                if (toDelete.isNotEmpty) {
                  if (widget.useLocal) {
                    final byId = <String, Asset>{};
                    for (final asset in toDelete) {
                      final local = asset.local;
                      if (local != null) byId[local.id] = asset;
                    }
                    if (byId.isNotEmpty) {
                      final deletedIds = await PhotoManager.editor
                          .deleteWithIds(byId.keys.toList());
                      for (final id in deletedIds) {
                        final asset = byId[id];
                        if (asset != null) {
                          assetModel.removeLocalAsset(asset);
                          deletedCount++;
                        }
                      }
                    }
                  } else {
                    final byPath = <String, Asset>{};
                    for (final asset in toDelete) {
                      final remote = asset.remote;
                      if (remote != null) byPath[remote.path] = asset;
                    }
                    if (byPath.isNotEmpty) {
                      final rsp = await storage.cli.delete(DeleteRequest(
                        paths: byPath.keys.toList(),
                      ));
                      if (!rsp.success) {
                        throw Exception(
                            "delete failed: ${rsp.message}");
                      }
                      for (final asset in byPath.values) {
                        assetModel.removeRemoteAsset(asset);
                        final id = await findLocalIDByAsset(asset);
                        if (id != null) {
                          stateModel.removeSyncedPhotos([id]);
                        }
                        deletedCount++;
                      }
                      stateModel.saveSyncedIDs();
                    }
                  }
                }
              } catch (e) {
                SnackBarManager.showSnackBar(e.toString());
              }
              SnackBarManager.showSnackBar(
                  '${l10n.delete} $deletedCount ${l10n.photos}.');
              clearSelection();
              if (mounted) setState(() {});
              if (context.mounted) Navigator.of(context).pop();
            },
            child: Text(l10n.yes),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.cancel),
          ),
        ],
      ),
    );
  }

  void _shareAsset() async {
    if (!stateModel.isSelectionMode) {
      return;
    }
    // Resolve against the current list at action time (see FK-7).
    final assets = selectedAssets();
    if (assets.isEmpty) return;
    List<XFile> xfiles = [];
    try {
      for (var asset in assets) {
        final tempFilePath = await asset.downloadToTmpFilePath();
        xfiles.add(XFile(tempFilePath,
            name: await asset.originName(), mimeType: await asset.mimeType()));
      }
    } catch (e) {
      SnackBarManager.showSnackBar("Share failed: $e");
      return;
    }
    if (xfiles.isEmpty) return;
    Share.shareXFiles(xfiles);
  }

  void downloadSelected() async {
    if (widget.useLocal || !stateModel.isSelectionMode) {
      return;
    }
    if (!isDesktop() && settingModel.localFolderAbsPath == null) {
      SnackBarManager.showSnackBar(l10n.setLocalFirst);
      return;
    }
    // Resolve against the current list at action time (see FK-7).
    final assets = selectedAssets();
    clearSelection();
    int count = 0;
    await keepScreenOn(true);
    try {
      String? path;
      if (isDesktop()) {
        path = await FilePicker.platform.getDirectoryPath();
        if (path == null) {
          return;
        }
      }
      for (var asset in assets) {
        Uint8List data;
        if (!asset.isVideo()) {
          data = await asset.imageDataAsync(reportProgress: true);
        } else {
          final remote = asset.remote;
          if (remote == null) continue;
          data = await remote.imageData();
        }
        final name = await asset.originName();
        if (Platform.isAndroid) {
          String absPath = '${settingModel.localFolderAbsPath}/$name';
          final file = File(absPath);
          if (file.existsSync()) {
            throw Exception("$name already exists, skip download.");
          }
          await file.writeAsBytes(data);
          await file.setLastModified(asset.dateCreated());
          await scanFile(absPath);
        } else if (Platform.isIOS) {
          var appDocDir = await getTemporaryDirectory();
          String savePath = "${appDocDir.path}/$name";
          final file = File(savePath);
          // if (file.existsSync()) {
          //   throw Exception("$name already exists, skip download.");
          // }
          await file.writeAsBytes(data);
          await file.setLastModified(asset.dateCreated());
          await Gal.putImage(savePath);
        } else if (isDesktop()) {
          String absPath = '$path/$name';
          final file = File(absPath);
          await file.writeAsBytes(data);
        }
        count++;
      }
      SnackBarManager.showSnackBar(
          "${l10n.download} $count ${l10n.photos}${Platform.isIOS ? "\n${l10n.browseInRecents}" : ""}");
    } catch (e) {
      SnackBarManager.showSnackBar("${l10n.downloadFailed}: $e");
    } finally {
      await keepScreenOn(false);
    }
    eventBus.fire(LocalRefreshEvent(refreshUnSync: false));
  }

  void uploadSelected() async {
    if (!widget.useLocal || !stateModel.isSelectionMode) {
      return;
    }
    if (!settingModel.isRemoteStorageSetted) {
      SnackBarManager.showSnackBar(l10n.storageNotSetted);
      return;
    }
    await keepScreenOn(true);
    // Resolve against the current list at action time (see FK-7).
    final assets = selectedAssets();
    // 手动上传同样过同步筛选（FK-6）：被筛选排除/已上传的不上传。
    final uploadedIds = {
      for (final id in stateModel.syncedIDs) id: true,
    };
    var uploadedCount = 0;
    var skippedCount = 0;
    for (var asset in assets) {
      final entity = asset.local;
      if (entity == null) continue;
      if (!await shouldUploadManually(asset, uploadedIds)) {
        skippedCount++;
        continue;
      }
      try {
        await storage.uploadAssetEntityToDest(
            entity, settingModel.manualUploadDestDir);
        uploadedCount++;
      } catch (e) {
        SnackBarManager.showSnackBar("${l10n.uploadFailed}: $e");
      }
    }
    await keepScreenOn(false);
    SnackBarManager.showSnackBar(
        "${l10n.successfullyUpload} $uploadedCount ${l10n.photos}"
        "${skippedCount > 0 ? " ($skippedCount ${l10n.skippedByUploadFilter})" : ""}");
    eventBus.fire(RemoteRefreshEvent(refreshUnSync: false));

    clearSelection();
  }

  void _showBottomSheet(BuildContext context) {
    _bottomSheetController = Scaffold.of(context).showBottomSheet(
      (BuildContext context) {
        return SizedBox(
          height: 100,
          child: Column(
            children: [
              // 抓手
              Container(
                margin: const EdgeInsets.symmetric(
                    vertical: AppSpacing.sm, horizontal: 0),
                height: 4.0,
                width: 40.0,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(AppRadius.extraSmall),
                ),
              ),
              Consumer<StateModel>(
                  builder: (context, model, child) => SizedBox(
                        height: 80,
                        child: Row(
                          children: [
                            if (!isDesktop())
                              _bottomSheetIconButtun(Icons.share_outlined,
                                  l10n.share, _shareAsset),
                            _bottomSheetIconButtun(Icons.delete_outline,
                                l10n.delete, () => _showDeleteDialog(context)),
                            if (widget.useLocal)
                              _bottomSheetIconButtun(
                                  Icons.cloud_upload_outlined,
                                  l10n.upload,
                                  uploadSelected,
                                  isEnable: !model.isDownloading() &&
                                      !model.isUploading()),
                            if (!widget.useLocal)
                              _bottomSheetIconButtun(
                                  Icons.cloud_download_outlined,
                                  l10n.download,
                                  downloadSelected,
                                  isEnable: !model.isDownloading() &&
                                      !model.isUploading()),
                          ],
                        ),
                      )),
            ],
          ),
        );
      },
    );
    _bottomSheetController!.closed.then((value) => clearSelection());
  }

  Widget appBar() {
    return Consumer<StateModel>(
      builder: (context, model, child) {
        return SliverAppBar(
          pinned: false,
          snap: false,
          floating: true,
          expandedHeight: 70,
          toolbarHeight: 70,
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          leading: const Row(
            children: [],
          ),
          actions: [
            MenuAnchor(
              builder: (BuildContext context, MenuController controller,
                  Widget? child) {
                return IconButton(
                  icon: const Icon(Icons.more_vert),
                  onPressed: () {
                    if (controller.isOpen) {
                      controller.close();
                    } else {
                      controller.open();
                    }
                  },
                );
              },
              menuChildren: [
                widget.useLocal
                    ? MenuItemButton(
                        child: Text(l10n.chooseAlbum),
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (context) => const ChooseAlbumRoute()),
                          );
                        },
                      )
                    : MenuItemButton(
                        child: Text(l10n.storageSetting),
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (context) =>
                                    const SettingStorageRoute()),
                          );
                        },
                      ),
                MenuItemButton(
                  onPressed: settingModel.galleryColumCount > 2
                      ? () async {
                          settingModel.setGalleryColumCount(
                              settingModel.galleryColumCount - 1);
                          final prefs = await SharedPreferences.getInstance();
                          await prefs.setInt("galleryColumCount",
                              settingModel.galleryColumCount);
                        }
                      : null,
                  child: Text(l10n.zoomIn),
                ),
                MenuItemButton(
                  onPressed: settingModel.galleryColumCount < 10
                      ? () async {
                          settingModel.setGalleryColumCount(
                              settingModel.galleryColumCount + 1);
                          final prefs = await SharedPreferences.getInstance();
                          await prefs.setInt("galleryColumCount",
                              settingModel.galleryColumCount);
                        }
                      : null,
                  child: Text(l10n.zoomOut),
                ),
              ],
            ),
          ],
          flexibleSpace: FlexibleSpaceBar(
            centerTitle: true,
            title: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.only(right: AppSpacing.xs),
                  child: Image.asset(
                    'assets/icon/pho_icon.png',
                    width: 40,
                    height: 40,
                  ),
                ),
                const SizedBox(width: AppSpacing.xs),
                Text(
                  "Pho",
                  // logo 保留专用手写字体 Sriracha-Regular
                  style: Theme.of(context)
                      .textTheme
                      .headlineLarge!
                      .copyWith(fontFamily: "Sriracha-Regular"),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _bottomSheetIconButtun(IconData icon, String text, Function()? onTap,
      {bool isEnable = true}) {
    return Container(
      width: 80,
      height: 80,
      alignment: Alignment.center,
      // padding: const EdgeInsets.fromLTRB(15, 10, 15, 10),
      child: InkResponse(
        containedInkWell: true,
        radius: 40,
        onTap: isEnable ? onTap : null,
        borderRadius: BorderRadius.circular(AppRadius.extraLarge),
        child: Container(
          width: 80,
          height: 80,
          alignment: Alignment.center,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 24,
              ),
              Text(text, style: Theme.of(context).textTheme.labelMedium),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildDateLocateDialogChildrenDay() {
    List<Widget> children = [];
    _dateLocateMap.forEach(
      (key, value) {
        children.add(ListTile(
          title: Container(
            padding: const EdgeInsets.only(left: AppSpacing.md),
            child: Text(
              DateFormat('yyyy MMMM d${l10n.chineseday}',
                      Localizations.localeOf(context).languageCode)
                  .format(key),
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          trailing: Badge.count(
            count: value.count,
            backgroundColor: Theme.of(context).colorScheme.secondary,
            textStyle: Theme.of(context).textTheme.labelMedium,
          ),
          onTap: () {
            Navigator.pop(context);
            _scrollController.animateTo(
                value.location < 200 ? 0 : value.location - 200,
                duration: const Duration(milliseconds: 400),
                curve: Curves.easeInOut);
          },
        ));
      },
    );
    return children;
  }

  List<Widget> _buildDateLocateDialogChildrenGrouped(
    List<DateLocateGroup> groups,
    String datePattern,
  ) {
    List<Widget> children = [];
    for (final group in groups) {
      final loc = group.location < 200 ? 0.0 : group.location - 200;
      children.add(ListTile(
        title: Container(
          padding: const EdgeInsets.only(left: AppSpacing.md),
          child: Text(
            DateFormat(datePattern, Localizations.localeOf(context).languageCode)
                .format(group.key),
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        trailing: Badge.count(
          count: group.count,
          backgroundColor: Theme.of(context).colorScheme.secondary,
          textStyle: Theme.of(context).textTheme.labelMedium,
        ),
        onTap: () {
          Navigator.pop(context);
          if (_scrollController.hasClients) {
            _scrollController.animateTo(loc,
                duration: const Duration(milliseconds: 400),
                curve: Curves.easeInOut);
          }
        },
      ));
    }
    return children;
  }

  List<Widget> _buildDateLocateDialogChildrenMonth() {
    return _buildDateLocateDialogChildrenGrouped(
      groupDateLocateEntries(
          _dateLocateMap, (day) => DateTime(day.year, day.month)),
      'yyyy MMMM',
    );
  }

  List<Widget> _buildDateLocateDialogChildrenYear() {
    return _buildDateLocateDialogChildrenGrouped(
      groupDateLocateEntries(_dateLocateMap, (day) => DateTime(day.year)),
      'yyyy',
    );
  }

  void showDateLocateDialog() {
    showDialog(
        context: context,
        builder: (context) {
          return Dialog(
              child: FractionallySizedBox(
                  widthFactor: 0.9,
                  heightFactor: 0.7,
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(vertical: AppSpacing.md),
                    child: StatefulBuilder(
                      builder: (context, setState) {
                        late List<Widget> children;
                        switch (_locateType) {
                          case LocateType.day:
                            children = _buildDateLocateDialogChildrenDay();
                            break;
                          case LocateType.month:
                            children = _buildDateLocateDialogChildrenMonth();
                            break;
                          case LocateType.year:
                            children = _buildDateLocateDialogChildrenYear();
                            break;
                        }
                        return Column(
                          children: [
                            Container(
                                alignment: Alignment.center,
                                child: Text(l10n.jumpTo,
                                    style: Theme.of(context)
                                        .textTheme
                                        .headlineSmall)),
                            const Divider(height: 10),
                            Expanded(
                                child: ListView(
                              children: children,
                            )),
                            SegmentedButton<LocateType>(
                              segments: <ButtonSegment<LocateType>>[
                                ButtonSegment<LocateType>(
                                    value: LocateType.day,
                                    label: Text(l10n.day),
                                    icon: Icon(Icons.calendar_view_day)),
                                ButtonSegment<LocateType>(
                                    value: LocateType.month,
                                    label: Text(l10n.month),
                                    icon: Icon(Icons.calendar_view_month)),
                                ButtonSegment<LocateType>(
                                    value: LocateType.year,
                                    label: Text(l10n.year),
                                    icon: Icon(Icons.calendar_view_week)),
                              ],
                              selected: <LocateType>{_locateType},
                              onSelectionChanged: (Set<LocateType> value) {
                                setState(() {
                                  _locateType = value.first;
                                });
                              },
                            ),
                          ],
                        );
                      },
                    ),
                  )));
        });
  }

  Widget locater() {
    final totalHeight = MediaQuery.of(context).size.height;
    final paddingTop = MediaQuery.of(context).padding.top + 70;
    const paddingBottom = 130;
    final avaliabileHeight = totalHeight - paddingBottom - paddingTop;
    List<LocateInfo> mouthLocList = [];
    DateTime? lastDateTime;
    _dateLocateMap.forEach((key, value) {
      if (lastDateTime != null &&
          lastDateTime!.year == key.year &&
          lastDateTime!.month == key.month) {
        return;
      }
      mouthLocList.add(value);
      lastDateTime = key;
    });
    // Empty list guard: dividing by zero would yield an infinite
    // step height and mouthLocList[0] would go out of bounds on drag.
    // With no dated photos there is nothing to locate; keep the
    // handle inert instead of crashing.
    final perMonthHeight =
        mouthLocList.isEmpty ? 0.0 : avaliabileHeight / mouthLocList.length;
    return GestureDetector(
      onVerticalDragStart: (details) => setState(() {
        dragging = true;
      }),
      onVerticalDragEnd: (details) => setState(() {
        dragging = false;
      }),
      onVerticalDragUpdate: (details) {
        if (mouthLocList.isEmpty || !_scrollController.hasClients) {
          return;
        }
        final realOffset = locaterOffset - paddingTop;
        if (details.delta.dy < 0 && realOffset + details.delta.dy < 0) {
          return;
        }
        if (details.delta.dy > 0 &&
            locaterOffset + details.delta.dy > totalHeight - paddingBottom) {
          return;
        }
        final beforeIndex = locaterIndexForOffset(
            realOffset, perMonthHeight, mouthLocList.length);
        final afterIndex = locaterIndexForOffset(
            realOffset + details.delta.dy, perMonthHeight, mouthLocList.length);
        if (beforeIndex != afterIndex && afterIndex >= 0) {
          HapticFeedback.lightImpact();
          _scrollController.animateTo(
              mouthLocList[afterIndex].location,
              duration: const Duration(milliseconds: 50),
              curve: Curves.easeInOut);
        }
        setState(() {
          locaterOffset += details.delta.dy;
        });
      },
      child: Container(
        height: 50,
        width: 50,
        color: Colors.transparent,
        child: Stack(
          children: [
            ClipOval(
              clipper: CustomHalfCircleClipper(),
              child: Container(
                color: Theme.of(context).colorScheme.secondary.withAlpha(128),
              ),
            ),
            Container(
              alignment: Alignment.centerRight,
              child: Icon(
                Icons.height,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                size: 23,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget contentBuilder(BuildContext context, AssetModel model, Widget? child) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final localeCode = Localizations.localeOf(context).languageCode;
    Color textColor = colorScheme.onSurfaceVariant;
    _dateLocateMap = {};
    final all =
        widget.useLocal ? model.displayLocalAssets : model.remoteAssets;
    // The list was recomputed just now: drop ids whose asset is gone
    // so stale selection can never render as selected on a
    // different asset. (No setState here: this runs during build
    // and only shrinks the selection set used below.)
    if (_selectedIds.isNotEmpty) {
      final pruned = pruneStaleSelectionIds(all, _selectedIds);
      if (pruned.length != _selectedIds.length) {
        _selectedIds
          ..clear()
          ..addAll(pruned);
      }
    }
    var children = <Widget>[];
    double totalwidth;
    if (widget.width == null) {
      totalwidth = MediaQuery.of(context).size.width - columCount * 2;
    } else {
      totalwidth = widget.width! - columCount * 2;
    }
    final totalHeight = MediaQuery.of(context).size.height;
    final imgWidth = totalwidth / columCount;
    final imgHeight = imgWidth;

    var currentChildren = <Widget>[];
    // Assets of the day group currently being built, parallel to
    // currentChildren. Group select-all works on these ids, never
    // on position indices (see FK-7).
    var currentGroupAssets = <Asset>[];
    DateTime? currentDateTime;
    DateTime? preDateTime;
    double currentScrollOffset = 0;
    for (int i = 0; i < all.length; i++) {
      // Capture this build's asset for the tile's tap closures: the
      // closures must act on this asset, not on whatever asset later
      // occupies position i in a recomputed list.
      final asset = all[i];
      final date = asset.dateCreated();
      if (currentDateTime == null ||
          date.year != currentDateTime.year ||
          date.month != currentDateTime.month ||
          date.day != currentDateTime.day) {
        if (currentDateTime != null) {
          final groupAssets = List<Asset>.of(currentGroupAssets);
          bool selectedAll = groupAssets.isNotEmpty &&
              groupAssets.every((asset) => isAssetSelected(asset));
          DateFormat format = localeCode == 'zh'
              ? DateFormat('M月d日 EEE', 'zh')
              : DateFormat('EEE, MMM d', 'en');
          children.add(GestureDetector(
            child: Container(
              height: 55,
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md, AppSpacing.md, 0, AppSpacing.md),
              child: Row(
                children: [
                  Text(
                    format.format(currentDateTime),
                    style: textTheme.titleMedium?.copyWith(
                      color: textColor,
                    ),
                  ),
                  Expanded(
                      child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Transform.scale(
                        scale: 1.2,
                        child: Checkbox(
                            value: selectedAll,
                            shape: RoundedRectangleBorder(
                                borderRadius:
                                    BorderRadius.circular(AppRadius.small)),
                            onChanged: (isSelect) async {
                              if (isSelect == null) {
                                return;
                              }
                              if (isSelect) {
                                for (final asset in groupAssets) {
                                  _selectedIds.add(asset.stableKey());
                                }
                              } else {
                                for (final asset in groupAssets) {
                                  _selectedIds.remove(asset.stableKey());
                                }
                              }
                              HapticFeedback.lightImpact();
                              updateSelection();
                            }),
                      ),
                    ],
                  )),
                ],
              ),
            ),
            onTap: () => showDateLocateDialog(),
          ));
        }

        children.add(Wrap(
          spacing: 2, // 主轴(水平)方向间距
          runSpacing: 2.0, // 纵轴（垂直）方向间距
          alignment: WrapAlignment.start,
          children: currentChildren,
        ));
        final preDate = preDateTime;
        if (preDate != null) {
          final preInfo = _dateLocateMap[preDate];
          if (preInfo != null) preInfo.count = currentChildren.length;
        }
        currentScrollOffset -= 2;
        _dateLocateMap[date] = LocateInfo(location: currentScrollOffset);
        currentChildren = <Widget>[];
        currentGroupAssets = <Asset>[];
        preDateTime = date;
        if (currentDateTime == null || date.month != currentDateTime.month) {
          children.add(
            Container(
              height: 90,
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md, AppSpacing.xl, 0, AppSpacing.md),
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: localeCode == 'zh'
                          ? '${DateFormat('M', 'zh').format(date)}  '
                          : '${DateFormat('MMMM', 'en').format(date)} ',
                      style: textTheme.headlineLarge?.copyWith(
                        color: colorScheme.onSurface,
                      ),
                    ),
                    TextSpan(
                      text: DateFormat('yyyy').format(date),
                      style: textTheme.headlineLarge?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
          currentScrollOffset += 90;
        }
        currentScrollOffset += 55;
      }
      bool needLoadThumbnail = false;
      if (currentScrollOffset > scrollOffset - (2 * totalHeight) &&
          currentScrollOffset < scrollOffset + (3 * totalHeight)) {
        needLoadThumbnail = true;
        if (!all[i].loadThumbnailFinished()) {
          all[i].thumbnailDataAsync().then((value) {
            if (mounted) setState(() {});
          });
        }
      }
      var child = GestureDetector(
          onTap: () async {
            if (stateModel.isSelectionMode) {
              HapticFeedback.lightImpact();
              toggleSelectionForAsset(asset);
            } else {
              Navigator.push(
                context,
                PageRouteBuilder(
                  opaque: false,
                  transitionDuration: const Duration(milliseconds: 300),
                  reverseTransitionDuration: const Duration(milliseconds: 300),
                  transitionsBuilder: (BuildContext context,
                      Animation<double> animation,
                      Animation<double> secondaryAnimation,
                      Widget child) {
                    return FadeTransition(
                      opacity: animation,
                      child: child,
                    );
                  },
                  pageBuilder: (BuildContext context, _, __) =>
                      GalleryViewerRoute(
                    useLocal: widget.useLocal,
                    originIndex: i,
                  ),
                ),
              );
            }
          },
          onLongPress: () async {
            if (!stateModel.isSelectionMode) {
              HapticFeedback.lightImpact();
              toggleSelectionForAsset(asset);
            }
          },
          child: Stack(
            children: [
              // image
              Container(
                  width: imgWidth,
                  height: imgHeight,
                  padding: const EdgeInsets.all(0),
                  child: Hero(
                    tag: "asset_${asset.stableKey()}",
                    child: needLoadThumbnail && all[i].loadThumbnailFinished()
                        ? Image(
                            image: all[i].thumbnailProvider(),
                            fit: BoxFit.cover)
                        : ThumbnailSkeleton(),
                    flightShuttleBuilder: (BuildContext flightContext,
                        Animation<double> animation,
                        HeroFlightDirection flightDirection,
                        BuildContext fromHeroContext,
                        BuildContext toHeroContext) {
                      // 自定义过渡动画小部件
                      return AnimatedBuilder(
                        animation: animation,
                        builder: (BuildContext context, Widget? child) {
                          return Opacity(
                              opacity: animation.value,
                              child: all[i].loadThumbnailFinished()
                                  ? Image(
                                      image: all[i].thumbnailProvider(),
                                      fit: BoxFit.contain,
                                    )
                                  : ThumbnailSkeleton());
                        },
                      );
                    },
                  )),
              Consumer<StateModel>(builder: (context, stateModel, child) {
                return FutureBuilder<String>(
                  future: all[i].name(),
                  builder: (context, name) {
                    double percent = 0;
                    if (!widget.useLocal) {
                      percent = name.data == null
                          ? 0
                          : stateModel.getDownloadPercent(name.data as String);
                    } else {
                      final localId = all[i].local?.id;
                      percent = localId == null
                          ? 0
                          : stateModel.getUploadPercent(localId);
                    }
                    if (percent > 0) {
                      return Positioned(
                        bottom: 2,
                        right: 4,
                        width: 20,
                        height: 20,
                        child: Stack(
                          children: [
                            Center(
                              child: Icon(
                                  widget.useLocal
                                      ? Icons.arrow_upward_outlined
                                      : Icons.arrow_downward_outlined,
                                  color: colorScheme.onPrimary,
                                  size: 16),
                            ),
                            CircularProgressIndicator(
                              strokeWidth: 2,
                              color: colorScheme.onPrimary,
                              value: percent,
                            )
                          ],
                        ),
                      );
                    }
                    if (!widget.useLocal ||
                        !settingModel.isRemoteStorageSetted) {
                      return const SizedBox(width: 0, height: 0);
                    }
                    if (stateModel.lastRefreshUnsyncTime == null) {
                      return Positioned(
                          bottom: 2,
                          right: 4,
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: colorScheme.onPrimary,
                          ));
                    }
                    var icon = Icons.cloud_off_outlined;
                    final localId = all[i].local?.id;
                    if (localId != null &&
                        stateModel.syncedIDs.contains(localId)) {
                      icon = Icons.cloud_done_outlined;
                    }
                    return Positioned(
                      bottom: 2,
                      right: 4,
                      child: Icon(
                        icon,
                        color: Colors.white,
                        size: 16,
                      ),
                    );
                  },
                );
              }),
              if (all[i].isLivePhoto())
                Positioned(
                  top: 2,
                  right: 2,
                  child: SizedBox(
                    height: 18,
                    width: 18,
                    child: Image.asset("assets/icon/live_photos.png"),
                  ),
                ),
              // video icon
              if (needLoadThumbnail && all[i].isVideo()) ...[
                FutureBuilder(
                    future: all[i].videoDuration(),
                    builder: (context, snapshot) {
                      if (snapshot.data == null ||
                          snapshot.data == Duration.zero) {
                        return const SizedBox(width: 0, height: 0);
                      }
                      final duration = snapshot.data!;
                      return Positioned(
                        top: 4,
                        right: 28,
                        child: Text(
                          "${duration.inMinutes}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}",
                          style: textTheme.labelMedium
                              ?.copyWith(color: Colors.white),
                        ),
                      );
                    }),
                Positioned(
                  top: 4,
                  right: 4,
                  child: Icon(
                    Icons.play_circle_fill,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
              ],

              // selection
              if (stateModel.isSelectionMode) ...[
                if (isAssetSelected(asset))
                  Container(
                    width: imgWidth,
                    height: imgHeight,
                    color: colorScheme.scrim.withValues(alpha: 0.4),
                  ),
                Positioned(
                  top: 2,
                  left: 2,
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      color: Colors.transparent,
                      borderRadius: BorderRadius.circular(AppRadius.small),
                    ),
                    child: Center(
                      child: Checkbox(
                        value: isAssetSelected(asset),
                        onChanged: (value) async {
                          toggleSelectionForAsset(asset);
                        },
                        shape: RoundedRectangleBorder(
                            borderRadius:
                                BorderRadius.circular(AppRadius.small)),
                      ),
                    ),
                  ),
                ),
              ]
            ],
          ));
      currentChildren.add(child);
      currentGroupAssets.add(asset);
      if (currentChildren.length % columCount == 1) {
        currentScrollOffset += imgHeight + 2;
      }
      currentDateTime = date;

      if (i == all.length - 1) {
        final groupAssets = List<Asset>.of(currentGroupAssets);
        bool selectedAll = groupAssets.isNotEmpty &&
            groupAssets.every((a) => isAssetSelected(a));
        DateFormat format = localeCode == 'zh'
            ? DateFormat('M月d日 EEE', 'zh')
            : DateFormat('EEE, MMM d', 'en');
        children.add(GestureDetector(
          child: Container(
            height: 55,
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.md, AppSpacing.md, 0, AppSpacing.md),
            child: Row(
              children: [
                Text(
                  format.format(currentDateTime),
                  style: textTheme.titleMedium?.copyWith(
                    color: textColor,
                  ),
                ),
                Expanded(
                    child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Transform.scale(
                      scale: 1.2,
                      child: Checkbox(
                          value: selectedAll,
                          shape: RoundedRectangleBorder(
                              borderRadius:
                                  BorderRadius.circular(AppRadius.small)),
                          onChanged: (isSelect) async {
                            if (isSelect == null) {
                              return;
                            }
                            if (isSelect) {
                              for (final a in groupAssets) {
                                _selectedIds.add(a.stableKey());
                              }
                            } else {
                              for (final a in groupAssets) {
                                _selectedIds.remove(a.stableKey());
                              }
                            }
                            HapticFeedback.lightImpact();
                            updateSelection();
                          }),
                    ),
                  ],
                )),
              ],
            ),
          ),
          onTap: () => showDateLocateDialog(),
        ));
        children.add(Wrap(
          spacing: 2, // 主轴(水平)方向间距
          runSpacing: 2.0, // 纵轴（垂直）方向间距
          alignment: WrapAlignment.start,
          children: currentChildren,
        ));
      }
    }
    maxScrollOffset = currentScrollOffset;
    return SliverList.list(
      children: [
        if ((widget.useLocal &&
                assetModel.localAssets.isEmpty &&
                assetModel.localGetting != null) ||
            (!widget.useLocal &&
                assetModel.remoteAssets.isEmpty &&
                assetModel.remoteGetting != null))
          Container(
            height: 100,
            alignment: Alignment.center,
            child: Text(l10n.refreshing,
                style: textTheme.bodyMedium
                    ?.copyWith(color: colorScheme.onSurfaceVariant)),
          ),
        if (all.isEmpty &&
            ((widget.useLocal && assetModel.localGetting == null) ||
                (!widget.useLocal && assetModel.remoteGetting == null)))
          SizedBox(
            height: 300,
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    widget.useLocal
                        ? Icons.photo_library_outlined
                        : Icons.cloud_off_outlined,
                    size: 64,
                    color: colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    widget.useLocal
                        ? (settingModel.onlyCameraAlbum &&
                                assetModel.localAssets.isNotEmpty
                            ? l10n.noCameraPhotos
                            : l10n.noLocalPhotos)
                        : l10n.noCloudPhotos,
                    style: textTheme.bodyMedium
                        ?.copyWith(color: colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 16),
                  if (!widget.useLocal && !settingModel.isRemoteStorageSetted)
                    FilledButton(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (context) => const SettingStorageRoute()),
                      ),
                      child: Text(l10n.setRemoteStroage),
                    ),
                ],
              ),
            ),
          ),
        ...children
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return PopScope(
      // 多选模式下拦截系统返回：先退出多选，避免直接退出应用（issue #86）
      canPop: !stateModel.isSelectionMode,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (stateModel.isSelectionMode) {
          clearSelection();
        }
      },
      child: RefreshIndicator(
        key: _refreshIndicatorKey,
        onRefresh: refresh,
        child: Stack(
          children: [
            CustomScrollView(
                controller: _scrollController,
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  if (widget.showAppBar) appBar(),
                  Consumer<AssetModel>(builder: contentBuilder),
                ]),
            if (!isDesktop())
              Positioned(top: locaterOffset, right: 0, child: locater()),
            // 回到顶部按钮
            Positioned(
              bottom: 20,
              right: 20,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Offstage(
                    offstage: !_showToTopBtn,
                    child: Container(
                      margin: const EdgeInsets.only(left: 10),
                      child: FloatingActionButton.small(
                        onPressed: _scrollToTop,
                        heroTag: 'gallery_body_${widget.useLocal}_toTop',
                        child: const Icon(Icons.arrow_upward),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Widget chooseAlbumButtun(BuildContext context) {
  return Container(
    margin: const EdgeInsets.only(right: AppSpacing.xs),
    child: TextButton(
      child: Text(l10n.chooseAlbum),
      onPressed: () {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (context) => const ChooseAlbumRoute()),
        );
      },
    ),
  );
}

Widget setRemoteStorageButtun(BuildContext context) {
  return Container(
    margin: const EdgeInsets.only(right: AppSpacing.xs),
    child: IconButton.filledTonal(
      icon: const Icon(Icons.settings_outlined),
      color: Theme.of(context).iconTheme.color,
      tooltip: l10n.storageSetting,
      onPressed: () {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (context) => const SettingStorageRoute()),
        );
      },
    ),
  );
}

class CustomHalfCircleClipper extends CustomClipper<Rect> {
  @override
  Rect getClip(Size size) {
    return Rect.fromLTWH(size.width * 0.4, 0, size.width, size.height);
  }

  @override
  bool shouldReclip(CustomClipper<Rect> oldClipper) {
    return true;
  }
}

class _CustomScaleGestureRecognizer extends ScaleGestureRecognizer {}
