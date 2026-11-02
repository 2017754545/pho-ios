import 'dart:io';
import 'package:flutter/material.dart';
import 'package:img_syncer/asset.dart';
import 'package:img_syncer/logger/logger.dart';
import 'package:img_syncer/storage/storage.dart';
import 'package:img_syncer/util.dart';
import 'package:path/path.dart';
import 'package:img_syncer/state_model.dart';
import 'package:provider/provider.dart';
import 'package:rxdart/rxdart.dart';
import 'package:img_syncer/choose_album_route.dart';
import 'package:img_syncer/setting_storage_route.dart';
import 'package:img_syncer/global.dart';
import 'package:img_syncer/settings_route.dart';
import 'package:img_syncer/background_sync_route.dart';
import 'package:img_syncer/design_tokens.dart';
import 'package:img_syncer/widgets/thumbnail_skeleton.dart';
import 'package:img_syncer/sync/background_runner.dart';

export 'package:img_syncer/sync/background_runner.dart'
    show shouldSyncAsset;

class SyncBody extends StatefulWidget {
  const SyncBody({
    Key? key,
    required this.localFolder,
  }) : super(key: key);

  final String localFolder;

  @override
  SyncBodyState createState() => SyncBodyState();
}

class SyncBodyState extends State<SyncBody> {
  final ScrollController _scrollController = ScrollController();
  final _scrollSubject = PublishSubject<double>();

  @protected
  int pageSize = 20;
  Map<String, String> uploadFailedMap = {};
  bool syncing = false;
  double scrollOffset = 0;

  /// 计数用扩展名缓存（assetId -> extension(await asset.name()) 的结果，
  /// 含前导点或空串）。columnBuilder 是同步函数，不能 await；标题尚未
  /// 加载时先按空串计入，解析完成后写缓存并 setState 重建，届时扩展名
  /// 筛选生效（FK-1：与 background_runner 的异步路径共用同一解析结果，
  /// 不再长期用 localTitle 的同步快照）。标题加载失败时缓存空串，
  /// 等效于跳过扩展名检查，与原行为一致。
  final Map<String, String> _countingExtensionCache = {};
  final Set<String> _countingExtensionResolving = {};

  /// 计数路径的扩展名：已缓存/本地标题已知的同步返回；否则触发一次
  /// 异步解析（每资产一次），本次返回空串（ transient：资产在标题
  /// 解析完成前的重建里暂按“不过滤”计入，解析完成后重建纠正）。
  String _extensionForCounting(Asset asset) {
    final local = asset.local;
    if (local == null) return '';
    final cached = _countingExtensionCache[local.id];
    if (cached != null) return cached;
    if (asset.localTitle != null && asset.localTitle!.isNotEmpty) {
      final ext = extension(asset.localTitle!);
      _countingExtensionCache[local.id] = ext;
      return ext;
    }
    if (_countingExtensionResolving.add(local.id)) {
      _resolveCountingExtension(asset, local.id);
    }
    return '';
  }

  Future<void> _resolveCountingExtension(Asset asset, String id) async {
    String ext = '';
    try {
      ext = extension(await asset.name());
    } catch (e) {
      logger.addLog('counting extension resolve failed: $e');
    }
    _countingExtensionResolving.remove(id);
    if (_countingExtensionCache[id] != ext) {
      _countingExtensionCache[id] = ext;
      if (mounted) setState(() {});
    }
  }

  @override
  void initState() {
    super.initState();
    _scrollSubject.stream
        .debounceTime(const Duration(milliseconds: 150))
        .listen((scrollPosition) {
      if (_scrollController.position.pixels >=
          _scrollController.position.maxScrollExtent - 1500) {
        // loadMore();
      }
      setState(() {
        scrollOffset = scrollPosition;
      });
    });
    _scrollController.addListener(() {
      _scrollSubject.add(_scrollController.position.pixels);
    });
  }

  @override
  void didUpdateWidget(SyncBody oldWidget) {
    super.didUpdateWidget(oldWidget);
  }

  @override
  void dispose() {
    super.dispose();
    _scrollController.dispose();
    _scrollSubject.close();
  }

  Widget settingRows() {
    final ButtonStyle style = FilledButton.styleFrom(
        shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppRadius.buttonFull),
    ));
    return LayoutBuilder(
      builder: (context, constraints) {
        return Column(
          children: [
            Row(
              children: [
                Container(
                  height: 60,
                  width: constraints.maxWidth * 0.5,
                  padding: const EdgeInsets.fromLTRB(
                      AppSpacing.paddingStandard,
                      AppSpacing.sm,
                      AppSpacing.paddingSmall,
                      AppSpacing.sm),
                  child: FilledButton.tonal(
                    style: style,
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (context) => const ChooseAlbumRoute()),
                      );
                    },
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(
                          Icons.folder_outlined,
                        ),
                        const SizedBox(width: 10),
                        Text(l10n.localFolder),
                      ],
                    ),
                  ),
                ),
                Container(
                  height: 60,
                  width: constraints.maxWidth * 0.5,
                  padding: const EdgeInsets.fromLTRB(
                      AppSpacing.paddingSmall,
                      AppSpacing.sm,
                      AppSpacing.paddingStandard,
                      AppSpacing.sm),
                  child: FilledButton.tonal(
                    style: style,
                    onPressed: () {
                      Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => const SettingStorageRoute(),
                          ));
                    },
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(
                          Icons.cloud_outlined,
                        ),
                        const SizedBox(width: 10),
                        Text(l10n.cloudStorage),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            (Platform.isIOS ||
                    Platform.isAndroid ||
                    isDebug
                ? Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          if (Platform.isAndroid || Platform.isIOS)
                            Container(
                              height: 60,
                              width: constraints.maxWidth * 0.5,
                              padding: const EdgeInsets.fromLTRB(
                                  AppSpacing.paddingStandard,
                                  AppSpacing.sm,
                                  AppSpacing.paddingSmall,
                                  AppSpacing.sm),
                              child: FilledButton.tonal(
                                style: style,
                                onPressed: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                        builder: (context) =>
                                            const BackgroundSyncSettingRoute()),
                                  );
                                },
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    const Icon(
                                      Icons.cloud_sync_outlined,
                                    ),
                                    const SizedBox(width: 10),
                                    Text(l10n.backgroundSync),
                                  ],
                                ),
                              ),
                            ),
                          Container(
                            height: 60,
                            width: constraints.maxWidth * 0.5,
                            padding: const EdgeInsets.fromLTRB(
                                AppSpacing.paddingSmall,
                                AppSpacing.sm,
                                AppSpacing.paddingStandard,
                                AppSpacing.sm),
                            child: FilledButton.tonal(
                              style: FilledButton.styleFrom(
                                  shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(
                                    AppRadius.buttonFull),
                              )),
                              onPressed: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (context) =>
                                          const SettingsRoute()),
                                );
                              },
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(Icons.settings_outlined),
                                  const SizedBox(width: 10),
                                  Text(l10n.settings),
                                ],
                              ),
                            ),
                          ),
                        ],
                      )
                    : const SizedBox(height: 0, width: 0)),
          ],
        );
      },
    );
  }

  void syncPhotos() async {
    stateModel.needStopSync = false;
    if (syncing) {
      return;
    }
    setState(() {
      syncing = true;
    });
    uploadFailedMap.clear();
    final Map<String, bool> uploadedIds = {};
    for (final id in stateModel.syncedIDs) {
      uploadedIds[id] = true;
    }
    final all = assetModel.localAssets;
    try {
      await keepScreenOn(true);
      await runSyncOnce(
        storage: storageClient,
        assets: all,
        uploadedIds: uploadedIds,
        // 并行上传数来自设置（默认 1 = 现有串行行为）；iOS 后台入口
        // 另有 min(setting, 2) 的封顶，见 background_sync_entrypoint.dart。
        parallelCount: settingModel.parallelUploadCount,
        callbacks: SyncCallbacks(
          onProgress: (completed, total, failed) {
            if (mounted) {
              stateModel.setSyncProgress(total, completed, failed);
            }
          },
          onAssetFailed: (assetId, error) {
            if (mounted) {
              uploadFailedMap[assetId] = error;
            }
          },
        ),
        shouldStop: () => stateModel.needStopSync,
      );
    } catch (e) {
      // runSyncOnce 抛错（如标题解析失败）时也要恢复 UI 状态并让用户
      // 看见错误：此前 keepScreenOn(false)/syncing=false 被跳过，界面
      // 永久卡在同步中。
      logger.addLog('syncPhotos failed: $e');
      SnackBarManager.showSnackBar('${l10n.uploadFailed}: $e');
    } finally {
      await keepScreenOn(false);
      if (mounted) {
        setState(() {
          syncing = false;
        });
      }
      stateModel.setSyncProgress(0, 0, 0);
    }
  }

  void stopSync() {
    stateModel.needStopSync = true;
  }

  Widget columnBuilder(BuildContext context, StateModel model, Widget? child) {
    final Map<String, bool> uploadedIds = {};
    for (final id in stateModel.syncedIDs) {
      uploadedIds[id] = true;
    }
    final all = assetModel.localAssets;
    List<Widget> listChildren = [];
    double currentScrollOffset = 0;
    for (var asset in all) {
      // 扩展名走 _extensionForCounting：与上传路径一样解析
      // extension(await asset.name())，结果按资产缓存；标题未加载时
      // 本次按空串（跳过扩展名检查），解析完成后重建纠正计数。
      final ext = _extensionForCounting(asset);
      if (!shouldSyncAsset(asset, asset.local!.id, uploadedIds, ext)) {
        continue;
      }
      final totalHeight = MediaQuery.of(context).size.height;
      bool needLoadThumbnail = false;
      if (currentScrollOffset > scrollOffset - (2 * totalHeight) &&
          currentScrollOffset < scrollOffset + (3 * totalHeight)) {
        needLoadThumbnail = true;
        if (!asset.loadThumbnailFinished()) {
          asset.thumbnailDataAsync().then((value) {
            if (mounted) setState(() {});
          });
        }
        if (!asset.hasGotTitle()) {
          asset.getLocalFile().then((value) {
            if (mounted) setState(() {});
          });
        }
      }
      Widget child = ListTile(
        leading: SizedBox(
          width: 60,
          height: 60,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.small),
            child: needLoadThumbnail && asset.loadThumbnailFinished()
                ? Image(image: asset.thumbnailProvider(), fit: BoxFit.cover)
                : ThumbnailSkeleton(width: 60, height: 60),
          ),
        ),
        title: needLoadThumbnail
            ? FutureBuilder(
                future: asset.name(),
                builder: (context, name) => Text(
                  name.data ?? "",
                  overflow: TextOverflow.ellipsis,
                ),
              )
            : null,
        subtitle: needLoadThumbnail
            ? Consumer<StateModel>(
                builder: (context, stateModel, child) {
                  final percent = stateModel.getUploadPercent(asset.local!.id);
                  if (percent > 0) {
                    return Container(
                      padding: const EdgeInsets.fromLTRB(0, 0, 10, 0),
                      child: LinearProgressIndicator(value: percent),
                    );
                  }
                  if (!stateModel.syncedIDs.contains(asset.local!.id)) {
                    if (uploadFailedMap.containsKey(asset.local!.id)) {
                      return Text(
                        "${l10n.uploadFailed}: ${uploadFailedMap[asset.local!.id]}",
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error),
                      );
                    }
                    return Text(l10n.notUploaded,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.secondary));
                  }
                  return Text(
                    l10n.uploaded,
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.primary),
                  );
                },
              )
            : Container(),
      );
      listChildren.add(child);
      currentScrollOffset += 72; // ListTile's height
    }
    return Scaffold(
      appBar: AppBar(
        title: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            l10n.cloudSync,
            style: Theme.of(context).textTheme.headlineMedium,
          ),
        ),
        actions: [
          Container(
            padding: const EdgeInsets.fromLTRB(0, 0, AppSpacing.xs, AppSpacing.xs),
            alignment: Alignment.bottomRight,
            constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.5),
            child: Text(
              syncing
                  ? "${stateModel.syncCompleted}/${stateModel.syncTotal} (${(stateModel.syncPercent * 100).toInt()}%)"
                  : "${listChildren.length} ${l10n.notSync}",
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
              style: TextStyle(
                  color:
                      Theme.of(context).colorScheme.secondary.withAlpha(172)),
            ),
          ),
        ],
      ),
      floatingActionButton: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          FloatingActionButton(
            heroTag: "refresh",
            tooltip: l10n.refreshUnsynchronizedPhotos,
            elevation: 2,
            onPressed: () => syncing ||
                    model.refreshingUnsynchronized ||
                    model.isDownloading() ||
                    model.isUploading()
                ? null
                : refreshUnsynchronized(),
            child: model.refreshingUnsynchronized
                ? CircularProgress()
                : const Icon(Icons.refresh),
          ),
          Container(
            padding: const EdgeInsets.only(left: AppSpacing.md),
            child: FloatingActionButton.extended(
                heroTag: "sync",
                elevation: 2,
                onPressed: () {
                  if (!settingModel.isRemoteStorageSetted) {
                    Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const SettingStorageRoute(),
                        ));
                    return;
                  }
                  if (syncing ||
                      model.refreshingUnsynchronized ||
                      model.isDownloading() ||
                      model.isUploading()) {
                    stopSync();
                  } else {
                    syncPhotos();
                  }
                },
                icon: syncing ? CircularProgress() : const Icon(Icons.sync),
                label: Text(syncing ? l10n.stop : l10n.sync)),
          ),
        ],
      ),
      body: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          settingRows(),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.sm, 0),
                child: Text(
                  l10n.unsynchronizedPhotos,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              const Flexible(
                child: Divider(
                  height: 10,
                  thickness: 1,
                  indent: 0,
                  endIndent: AppSpacing.md,
                ),
              ),
            ],
          ),
          if (!settingModel.isRemoteStorageSetted)
            Container(
              height: 250,
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
              child: Center(
                heightFactor: 10,
                child: Text(l10n.setRemoteStroage,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ),
            ),
          // 筛选排除了全部内容时提示（FK-3 同步页一半；设置页一半在
          // FilterSettingsRoute 的 _excludesEverything 横幅）。
          if (settingModel.uploadFilter.enabled &&
              settingModel.uploadFilter.noVideo &&
              settingModel.uploadFilter.noImage)
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md, vertical: AppSpacing.sm),
              child: Text(l10n.filterExcludesAll,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.error)),
            ),
          model.refreshingUnsynchronized && listChildren.isEmpty
              ? Container(
                  height: 250,
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
                  child: Center(
                    heightFactor: 10,
                    child: Text(l10n.refreshingPleaseWait,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant)),
                  ),
                )
              : Flexible(
                  child: ListView(
                  controller: _scrollController,
                  children: listChildren,
                )),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<StateModel>(
      builder: columnBuilder,
    );
  }

  Widget CircularProgress() {
    final cs = Theme.of(this.context).colorScheme;
    return SizedBox(
      height: 20,
      width: 20,
      child: CircularProgressIndicator(
        valueColor: AlwaysStoppedAnimation<Color>(cs.onPrimary),
        strokeWidth: 2,
      ),
    );
  }

  Future<void> refreshUnsynchronized() async {
    if (!settingModel.isRemoteStorageSetted) {
      stateModel.setSyncedPhotos([]);
      return;
    }
    uploadFailedMap.clear();
    await refreshUnsynchronizedPhotos();
  }
}
