// ignore_for_file: deprecated_member_use
import 'dart:convert';
import 'dart:io';
import 'package:date_format/date_format.dart';
import 'package:grpc/grpc.dart';
import 'package:flutter/material.dart';
import 'package:img_syncer/logger/logger.dart';
import 'package:img_syncer/util.dart';
import 'event_bus.dart';
import 'package:img_syncer/asset.dart';
import 'package:img_syncer/camera_album_classifier.dart';
import 'package:img_syncer/sync/upload_filter.dart';
import 'dart:async';
import 'package:photo_manager/photo_manager.dart';
import 'package:img_syncer/storage/storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/services.dart';
import 'package:mime/mime.dart';
import 'package:img_syncer/proto/img_syncer.pbgrpc.dart';
import 'package:img_syncer/global.dart';
import 'package:shared_preferences/shared_preferences.dart';

SettingModel settingModel = SettingModel();
AssetModel assetModel = AssetModel();
StateModel stateModel = StateModel();

enum Drive { smb, webDav, nfs }

Map<Drive, String> driveName = {
  Drive.smb: 'SMB',
  Drive.webDav: 'WebDAV',
  Drive.nfs: 'NFS',
};

enum EncryptionType { none, aesCfb, aesGcm }

class SettingModel extends ChangeNotifier {
  String localFolder = "";
  String? localFolderAbsPath;
  bool isRemoteStorageSetted = false;

  bool enableEncrypt = false;
  EncryptionType encryptionType = EncryptionType.none;
  String encryptionPassword = "";

  int galleryColumCount = 4;

  bool setGalleryColumCount(int count) {
    if (galleryColumCount == count) return false;
    galleryColumCount = count;
    notifyListeners();
    return true;
  }

  void setLocalFolder(String folder) {
    if (localFolder == folder && folder != "Recents") return;
    localFolder = folder;
    localFolderAbsPath = null;
    stateModel.setSyncedPhotos([]);
    notifyListeners();
  }

  void setRemoteStorageSetted(bool setted) {
    if (isRemoteStorageSetted == setted) return;
    isRemoteStorageSetted = setted;
    notifyListeners();
  }

  void setEncryptSwitch(bool enable) {
    if (enableEncrypt == enable) return;
    enableEncrypt = enable;
    notifyListeners();
  }

  void setEncryptionType(EncryptionType type) {
    if (encryptionType == type) return;
    encryptionType = type;
    notifyListeners();
  }

  void setEncryptionPassword(String password) {
    if (encryptionPassword == password) return;
    encryptionPassword = password;
    notifyListeners();
  }

  // --- iOS 自用功能：并行上传 / 自定义上传筛选 / 仅相机相册 ---
  // 持久化：设置页走显式保存（FilterSettingsRoute._save 写回
  // SharedPreferences）；下述筛选 setter 也会把新状态排队写入
  // SharedPreferences（串行化，避免并发写入互相覆盖）。加载点：
  // Global.init()（global.dart，runServer().then 内的移动端分支）
  // 与 backgroundSyncEntrypoint（background_sync_entrypoint.dart
  // 的最小 init 序列）。Android 侧不仅无设置 UI，fork 配置在加载时
  // 也不读入（global.dart 的 Platform.isIOS 门控），始终用默认值，
  // Android 行为不变。

  /// 并行上传数（1–4，默认 1 = 现有串行行为）。
  /// 实际并发上限还受 Go 侧 worker 池与各后端并发能力制约。
  int parallelUploadCount = 1;

  bool setParallelUploadCount(int count) {
    final clamped = count.clamp(1, 4);
    if (parallelUploadCount == clamped) return false;
    parallelUploadCount = clamped;
    notifyListeners();
    return true;
  }

  /// 自定义上传筛选配置（默认全部允许 = 现有行为）。
  /// 判定语义见 lib/sync/upload_filter.dart。
  ///
  /// 规范 API 是本字段 + [setUploadFilter]：[setUploadFilter] 会
  /// **替换整个配置对象**，此前取出的 [uploadFilter] 引用与
  /// [filterTypeMap] 的 live map 随即失效（旧对象不再被同步判定
  /// 读取）。任何需要长期持有配置的代码都应在每次使用前重新从
  /// 本字段读取，不得缓存旧引用。
  ///
  /// 历史 Pro 风格的访问口（enableFilter / setFilterSwitch /
  /// setFilterNoVideo / setFilterNoImage / setFilterAfter /
  /// setFilterBefore / filterTypeMap）与本配置是同一份数据，由
  /// test/widget/sync_body_test.dart 锁定，不得删除：生产代码
  /// 没有调用方，测试通过它们构造筛选状态。它们只改内存中的
  /// 同一对象，并把新状态排队持久化（见 [_scheduleFilterPersist]）；
  /// 唯一不走这些 setter 的持久化路径是设置页 _save（显式
  /// await saveUploadFilterConfig）。
  UploadFilterConfig uploadFilter = UploadFilterConfig();

  /// 筛选写入的串行化链：setter 是同步的，无法 await 持久化；
  /// 每次变更都把当时的配置快照追加到链尾按序写入，避免多次
  /// 快速变更时后一次写入被前一次覆盖。
  Future<void> _filterSaveChain = Future.value();

  void _scheduleFilterPersist() {
    final snapshot = UploadFilterConfig.fromJson(uploadFilter.toJson());
    _filterSaveChain = _filterSaveChain.then(
      (_) => saveUploadFilterConfig(snapshot),
      onError: (_) => saveUploadFilterConfig(snapshot),
    );
  }

  bool get enableFilter => uploadFilter.enabled;

  /// [setFilterSwitch] 的别名，同一份数据、同一实现。
  set enableFilter(bool value) => setFilterSwitch(value);

  void setFilterSwitch(bool value) {
    if (uploadFilter.enabled == value) return;
    uploadFilter.enabled = value;
    notifyListeners();
    _scheduleFilterPersist();
  }

  void setFilterNoVideo(bool value) {
    if (uploadFilter.noVideo == value) return;
    uploadFilter.noVideo = value;
    notifyListeners();
    _scheduleFilterPersist();
  }

  void setFilterNoImage(bool value) {
    if (uploadFilter.noImage == value) return;
    uploadFilter.noImage = value;
    notifyListeners();
    _scheduleFilterPersist();
  }

  /// 直接存入原始 [date]，不做任何换算：allows() 用
  /// `date.isBefore(after)` 比较，测试锁定的正是原始边界语义。
  /// 设置页的日期选择器路径不走本 setter（它用
  /// UploadFilterConfig.exclusiveBeforeBound 构造配置后走
  /// setUploadFilter，见 FilterSettingsRoute._save）。
  void setFilterAfter(DateTime? date) {
    if (uploadFilter.after == date) return;
    uploadFilter.after = date;
    notifyListeners();
    _scheduleFilterPersist();
  }

  /// 直接存入原始 [date]，**不**应用 exclusiveBeforeBound 换算：
  /// allows() 用 `date.isAfter(before)` 比较，测试锁定了
  /// “同日通过、次日排除”的原始边界语义，换算会破坏它。
  /// 结束日次日 00:00 的上界约定只属于设置页路径（见
  /// FilterSettingsRoute._save 与 [setUploadFilter] 的归一化）。
  void setFilterBefore(DateTime? date) {
    if (uploadFilter.before == date) return;
    uploadFilter.before = date;
    notifyListeners();
    _scheduleFilterPersist();
  }

  /// 扩展名 -> 是否允许（key 形如 '.jpg' 小写；未出现即允许）。
  ///
  /// 有意返回配置内的 live map：test/widget/sync_body_test.dart
  /// 通过原地写 `filterTypeMap['.gif'] = false` 构造筛选状态，
  /// 返回副本会使该写法静默失效。代价是原地修改**不触发
  /// notifyListeners**（同步判定直接读同一对象，仍会生效），
  /// 且 [setUploadFilter] 替换配置后此前取出的 map 即失效。
  /// 需要通知监听者或需要稳定快照的生产代码应使用
  /// [setUploadFilter] / [filterTypeMapSnapshot]。
  Map<String, bool> get filterTypeMap => uploadFilter.extensionAllowed;

  set filterTypeMap(Map<String, bool> value) {
    uploadFilter.extensionAllowed = value;
    notifyListeners();
    _scheduleFilterPersist();
  }

  /// [filterTypeMap] 的防御性副本：修改副本不影响配置，配置
  /// 变更也不影响已取出的副本。只读场景优先用它。
  Map<String, bool> get filterTypeMapSnapshot =>
      Map<String, bool>.of(uploadFilter.extensionAllowed);

  /// 用 [config] 整体替换当前筛选配置，并通知监听者。
  ///
  /// 引用失效：替换后，调用方此前持有的 [uploadFilter] 对象与
  /// [filterTypeMap] map 均不再是生效配置；应重新从本字段读取。
  ///
  /// 归一化（B2 显示语义）：非午夜的 `before`（旧 setter 或手写
  /// 配置可能存入带时间的边界）会被换算为其日历日的次日 00:00
  /// 上界，使回显的结束日正确；午夜值原样保留——午夜值无法
  /// 区分“原始边界”与“已换算的上界”，改动它会破坏锁定的
  /// allows() 边界语义。
  ///
  /// 本方法只改内存、不持久化：加载路径（配置本身即来自持久化）
  /// 与设置页 _save（显式 await 保存）都不需要它再写一次。
  void setUploadFilter(UploadFilterConfig config) {
    var normalized = config;
    final before = config.before;
    if (before != null) {
      final isMidnight = before.hour == 0 &&
          before.minute == 0 &&
          before.second == 0 &&
          before.millisecond == 0 &&
          before.microsecond == 0;
      if (!isMidnight) {
        normalized = config.copyWith(
          before: UploadFilterConfig.exclusiveBeforeBound(before),
        );
      }
    }
    uploadFilter = normalized;
    notifyListeners();
  }

  /// 仅相机相册（仅 iOS 展示层开关）：只显示相机拍摄的照片。
  /// 不影响同步选择（同步始终用 shouldSyncAsset），不改 localFolder
  ///（哨兵值会清空 syncedIDs，见 setLocalFolder）。
  bool onlyCameraAlbum = false;

  bool setOnlyCameraAlbum(bool value) {
    if (onlyCameraAlbum == value) return false;
    onlyCameraAlbum = value;
    notifyListeners();
    return true;
  }
}

class transmitState {
  int transmitted = 0;
  int total = 0;
}

class StateModel extends ChangeNotifier {
  bool _isSelectionMode = false;
  bool refreshingUnsynchronized = false;
  List<String> syncedIDs = [];
  DateTime? lastRefreshUnsyncTime;

  Map<String, transmitState> uploadProgress = {};
  Map<String, transmitState> downloadProgress = {};

  bool get isSelectionMode => _isSelectionMode;

  bool needStopSync = false;

  bool _isOnline = true;
  bool get isOnline => _isOnline;
  void setOnline(bool online) {
    if (_isOnline == online) return;
    _isOnline = online;
    notifyListeners();
  }

  int syncTotal = 0;
  int syncCompleted = 0;
  int syncFailed = 0;
  double get syncPercent => syncTotal == 0 ? 0 : syncCompleted / syncTotal;
  void setSyncProgress(int total, int completed, int failed) {
    syncTotal = total;
    syncCompleted = completed;
    syncFailed = failed;
    notifyListeners();
  }

  void updateLastRefreshUnsyncTime(DateTime? t) {
    lastRefreshUnsyncTime = t;
    notifyListeners();
  }

  void updateUploadProgress(String id, int transmitted, int total) {
    if (!uploadProgress.containsKey(id)) {
      uploadProgress[id] = transmitState();
    }
    uploadProgress[id]!.transmitted = transmitted;
    uploadProgress[id]!.total = total;
    notifyListeners();
  }

  void finishUpload(String id, bool success) {
    uploadProgress.remove(id);
    if (success) {
      syncedIDs.add(id);
      saveSyncedIDs();
    }
    notifyListeners();
  }

  void updateDownloadProgress(String id, int transmitted, int total) {
    if (!downloadProgress.containsKey(id)) {
      downloadProgress[id] = transmitState();
    }
    downloadProgress[id]!.transmitted = transmitted;
    downloadProgress[id]!.total = total;
    notifyListeners();
  }

  void finishDownload(String id, bool success) {
    downloadProgress.remove(id);
    notifyListeners();
  }

  double getUploadPercent(String id) {
    if (!uploadProgress.containsKey(id)) {
      return 0;
    }
    final state = uploadProgress[id]!;
    return state.transmitted / state.total;
  }

  double getDownloadPercent(String id) {
    if (!downloadProgress.containsKey(id)) {
      return 0;
    }
    final state = downloadProgress[id]!;
    return state.transmitted / state.total;
  }

  bool isUploading() {
    return uploadProgress.isNotEmpty;
  }

  bool isDownloading() {
    return downloadProgress.isNotEmpty;
  }

  void setSelectionMode(bool mode) {
    if (_isSelectionMode == mode) return;
    _isSelectionMode = mode;
    notifyListeners();
  }

  void removeSyncedPhotos(List<String> ids) {
    for (var id in ids) {
      syncedIDs.remove(id);
    }
    notifyListeners();
  }

  void setSyncedPhotos(List<String> ids) {
    syncedIDs = ids;
    notifyListeners();
  }

  void setRefreshingUnsynchronized(bool refreshing) {
    if (refreshingUnsynchronized == refreshing) return;
    refreshingUnsynchronized = refreshing;
    notifyListeners();
  }

  Future<void> saveSyncedIDs() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonString = jsonEncode(syncedIDs);
    await prefs.setString('synced_ids', jsonString);
    await prefs.setInt(
        'last_refersh_unsync', DateTime.now().millisecondsSinceEpoch);
  }
}

class AssetModel extends ChangeNotifier {
  /// eventBus 订阅：全局单例的生命周期与应用相同，正常情况下
  /// 不会 dispose；但测试会创建多个实例，订阅若不取消会在
  /// 全局 eventBus 上累积，故全部存下来由 [dispose] 取消。
  final List<StreamSubscription> _eventSubscriptions = [];

  AssetModel() {
    _eventSubscriptions.add(eventBus
        .on<LocalRefreshEvent>()
        .listen((event) => refreshLocal(event.refreshUnSync)));
    _eventSubscriptions.add(eventBus
        .on<RemoteRefreshEvent>()
        .listen((event) => refreshRemote(event.refreshUnSync)));
    _eventSubscriptions.add(eventBus.on<FinishGettingLocal>().listen((event) async {
      if (stateModel.lastRefreshUnsyncTime == null) {
        refreshUnsynchronizedPhotos();
      } else {
        if (DateTime.now().difference(stateModel.lastRefreshUnsyncTime!) >
                const Duration(days: 1) &&
            stateModel.syncedIDs.isEmpty) {
          refreshUnsynchronizedPhotos();
        }
      }
    }));
    _eventSubscriptions.add(eventBus.on<FinishGettingRemote>().listen((event) async {
      if (stateModel.lastRefreshUnsyncTime == null) {
        refreshUnsynchronizedPhotos();
      } else {
        if (DateTime.now().difference(stateModel.lastRefreshUnsyncTime!) >
                const Duration(days: 1) &&
            stateModel.syncedIDs.isEmpty) {
          refreshUnsynchronizedPhotos();
        }
      }
    }));
  }

  @override
  void dispose() {
    for (final subscription in _eventSubscriptions) {
      subscription.cancel();
    }
    _eventSubscriptions.clear();
    super.dispose();
  }
  List<Asset> localAssets = [];
  List<Asset> remoteAssets = [];

  /// 截图类相册内的资产 ID 集合（仅 iOS、仅相机模式开启时填充）。
  /// 与 localAssets 分离：只影响展示，永不影响同步选择。
  Set<String> cameraExcludedIds = {};

  /// 相册展示用列表：仅相机模式开启时（iOS），排除截图相册内的资产与
  /// 分类器判定的截图/录屏文件；信号不足判为 unknown 的默认保留显示。
  /// 同步路径（sync_body / background_runner / sync_timer）始终使用
  /// [localAssets]，不受本开关影响。
  ///
  /// 注意：每次访问都重新计算并返回一个新列表，调用方不得用
  /// “位置索引”跨访问标识资产（列表成员随标题加载 / 排除集合
  /// 刷新而变化）；应以资产稳定 ID（local id / remote path）为键，
  /// 在操作时重新解析当前列表。分类器收到的 albumName 是当前
  /// 查看的相册名（对列表内全部资产相同），不是每张资产各自
  /// 所属的相册；逐资产的可靠排除信号是 [cameraExcludedIds]。
  List<Asset> get displayLocalAssets {
    if (!Platform.isIOS || !settingModel.onlyCameraAlbum) return localAssets;
    return localAssets.where((asset) {
      final local = asset.local;
      if (local != null && cameraExcludedIds.contains(local.id)) return false;
      return classifyCameraAsset(
            albumName: settingModel.localFolder,
            title: asset.localTitle ?? local?.title,
          ) !=
          CameraClassification.excluded;
    }).toList();
  }

  /// 枚举截图类相册（Screenshots / 截屏等），收集其中全部资产 ID。
  /// 仅在 iOS 且仅相机模式开启时填充；关闭时清空。失败时记日志，
  /// 不阻塞相册展示（分类器按文件名启发继续工作）。
  ///
  /// [onlyCameraAlbum] 允许调用方传入“即将生效”的开关值：设置页
  /// 切换开关时，先用新值刷新排除集合、再翻转
  /// SettingModel.onlyCameraAlbum（翻转会立即通知相册重建），
  /// 避免重建时集合还是旧值导致截图短暂闪现。默认读取
  /// settingModel 的当前值（refreshLocal 等内部调用方）。
  Future<void> refreshCameraExcludedIds({bool? onlyCameraAlbum}) async {
    cameraExcludedIds = {};
    final onlyCamera = onlyCameraAlbum ?? settingModel.onlyCameraAlbum;
    if (Platform.isIOS && onlyCamera) {
      try {
        final paths = await PhotoManager.getAssetPathList(
          type: RequestType.common,
          hasAll: true,
        );
        for (final path in paths) {
          if (!isScreenshotAlbumName(path.name)) continue;
          const pageSize = 500;
          var page = 0;
          while (true) {
            final entities =
                await path.getAssetListPaged(page: page, size: pageSize);
            if (entities.isEmpty) break;
            cameraExcludedIds.addAll(entities.map((e) => e.id));
            if (entities.length < pageSize) break;
            page++;
          }
        }
      } catch (e) {
        logger.addLog('refreshCameraExcludedIds failed: $e');
      }
    }
    notifyListeners();
  }
  int columCount = 4;
  int pageSize = 500;
  bool localHasMore = true;
  bool remoteHasMore = true;
  Completer<bool>? localGetting;
  bool localGettingNeedBreak = false;
  Completer<bool>? remoteGetting;
  bool remoteGettingNeedBreak = false;
  bool refreshUnsynchronizedNeedBreak = false;

  Map<String, String> titleCache = {};
  int cacheLastSaveLen = 0;

  String? remoteLastError;

  void addTitleCache(String id, String title) {
    titleCache[id] = title;
    if (titleCache.length - cacheLastSaveLen > 50) {
      cacheLastSaveLen = titleCache.length;
      saveTitleCache();
    }
  }

  Future<void> saveTitleCache() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonString = jsonEncode(titleCache);
    prefs.setString('title_cache', jsonString);
  }

  Future<void> loadTitleCache() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonString = prefs.getString('title_cache');
    if (jsonString != null) {
      final cache = jsonDecode(jsonString);
      for (var key in cache.keys) {
        titleCache[key] = cache[key];
      }
    }
  }

  Future<void> refreshLocal(bool refreshSync) async {
    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      return;
    }
    logger.addLog("refresh local");
    if (localGetting != null) {
      if (localGettingNeedBreak == true) {
        return;
      }
      localGettingNeedBreak = true;
      await localGetting!.future;
    }
    if (stateModel.refreshingUnsynchronized) {
      refreshUnsynchronizedNeedBreak = true;
    }
    if (refreshSync) {
      stateModel.setSyncedPhotos([]);
    }
    localHasMore = true;
    localAssets = [];
    localGettingNeedBreak = false;
    notifyListeners();
    final finished = await getLocalPhotos();
    if (finished) {
      // 仅相机模式：本地照片取回后，再枚举截图相册建立排除集合，
      // 展示层（displayLocalAssets）据此过滤；同步不受影响。
      await refreshCameraExcludedIds();
    }
    if (finished && refreshSync) {
      await refreshUnsynchronizedPhotos();
    }
  }

  Future<void> refreshRemote(bool refreshSync) async {
    logger.addLog("refresh remote");
    if (remoteGetting != null) {
      if (remoteGettingNeedBreak == true) {
        return;
      }
      remoteGettingNeedBreak = true;
      await remoteGetting!.future;
    }
    if (stateModel.refreshingUnsynchronized) {
      refreshUnsynchronizedNeedBreak = true;
    }
    remoteHasMore = true;
    remoteAssets = [];
    if (refreshSync) {
      stateModel.setSyncedPhotos([]);
    }
    notifyListeners();
    remoteGetting = null;
    remoteGettingNeedBreak = false;
    final finished = await getRemotePhotos();
    if (finished && refreshSync) {
      await refreshUnsynchronizedPhotos();
    }
  }

  Future<bool> getLocalPhotos() async {
    if (localGetting != null) {
      await localGetting?.future;
    }
    logger.addLog("get local photos");
    final re = await requestPermission();
    if (!re) return false;
    localGetting = Completer<bool>();
    notifyListeners();
    final List<AssetPathEntity> paths = await PhotoManager.getAssetPathList(
      type: RequestType.common,
      hasAll: true,
    );

    // choose the folder has most photos
    if (settingModel.localFolder == "") {
      int max = 0;
      for (var path in paths) {
        final count = await path.assetCountAsync;
        if (count > max) {
          max = count;
          settingModel.localFolder = path.name;
        }
      }
    }

    for (var path in paths) {
      if (settingModel.localFolder == path.name) {
        var opt = const FilterOption(needTitle: true);
        final newpath = await path.fetchPathProperties(
            filterOptionGroup: FilterOptionGroup(
          imageOption: opt,
          videoOption: opt,
          orders: [
            const OrderOption(
              type: OrderOptionType.createDate,
              asc: false,
            ),
          ],
        ));
        // fetchPathProperties 可能返回 null（相册不可用时）：
        // 跳过该相册而不是对 null 解包崩溃。
        if (newpath == null) continue;
        int offset = 0;
        while (localHasMore) {
          if (localGettingNeedBreak) {
            localGettingNeedBreak = false;
            localGetting?.complete(true);
            localGetting = null;
            notifyListeners();
            return false;
          }
          final List<AssetEntity> entities = await newpath
              .getAssetListRange(start: offset, end: offset + pageSize);
          if (entities.length < pageSize) {
            localHasMore = false;
          }
          offset += entities.length;
          for (var i = 0; i < entities.length; i++) {
            if (localGettingNeedBreak) {
              localGettingNeedBreak = false;
              localGetting?.complete(true);
              localGetting = null;
              notifyListeners();
              return false;
            }
            final asset = Asset(local: entities[i]);
            if (settingModel.localFolderAbsPath == null) {
              final file = await entities[i].originFile;
              if (file != null) {
                settingModel.localFolderAbsPath = file.parent.path;
              }
            }
            // asset.getLocalFile();
            localAssets.add(asset);
            // asset.thumbnailDataAsync().then((value) => notifyListeners());
            if (i % 50 == 0) {
              notifyListeners();
            }
          }
          notifyListeners();
          if (!localHasMore) {
            eventBus.fire(FinishGettingLocal());
            break;
          }
        }
      }
    }

    // 按拍摄日期降序重排，规避 Android 上 photo_manager 按 DATE_ADDED 枚举
    // 与 dateCreated()（DATE_TAKEN）不一致导致的年份穿插（issue #84）
    localAssets = sortByDateDesc(localAssets, (a) => a.dateCreated());

    localGetting?.complete(true);
    localGetting = null;
    notifyListeners();
    return true;
  }

  Future<bool> getRemotePhotos() async {
    await checkServer();
    if (remoteGetting != null) {
      await remoteGetting!.future;
      return false;
    }
    remoteGetting = Completer<bool>();
    notifyListeners();
    logger.addLog("start getting remote assets");
    try {
      while (remoteHasMore) {
        if (remoteGettingNeedBreak) {
          remoteGettingNeedBreak = false;
          remoteGetting?.complete(true);
          remoteGetting = null;
          notifyListeners();
          return false;
        }
        final offset = remoteAssets.length;
        final List<RemoteImage> images =
            await storageClient.listImages("", offset, pageSize);
        if (images.length < pageSize) {
          remoteHasMore = false;
        }
        for (var i = 0; i < images.length; i++) {
          try {
            final asset = Asset(remote: images[i]);
            remoteAssets.add(asset);
            if (i % 50 == 0) {
              notifyListeners();
            }
            // asset.thumbnailDataAsync().then((value) => notifyListeners());
          } catch (e) {
            logger.addLog(e.toString());
          }
        }
        notifyListeners();
      }
    } catch (e) {
      remoteLastError = e.toString();
    }
    if (!remoteHasMore) {
      eventBus.fire(FinishGettingRemote());
    }
    remoteGetting?.complete(true);
    remoteGetting = null;
    remoteGettingNeedBreak = false;
    notifyListeners();
    return true;
  }

  void removeLocalAsset(Asset asset) {
    localAssets.remove(asset);
    notifyListeners();
  }

  void removeLocalAssetsByIDs(List<String> ids) {
    localAssets.removeWhere((element) => ids.contains(element.local?.id));
    notifyListeners();
  }

  void removeRemoteAsset(Asset asset) {
    remoteAssets.remove(asset);
    notifyListeners();
  }
}

Future<String?> findLocalIDByAsset(Asset a) async {
  // hasLocal 为真只说明构造时传入了 local 字段的意图；local 本身
  // 仍可能为 null（测试替身），先判空再取值。
  if (a.hasLocal && a.local != null) {
    return a.local!.id;
  }
  final oName = await a.originName();
  for (var asset in assetModel.localAssets) {
    final localId = asset.local?.id;
    if (localId == null) continue;
    final name = await asset.originName();
    if (name == oName) {
      return localId;
    }
  }
  return null;
}

Future<void> scanFile(String filePath) async {
  if (Platform.isAndroid) {
    try {
      final directory = await getExternalStorageDirectory();
      final path = directory?.path ?? '';
      final mimeType = lookupMimeType(filePath);
      final Map<String, dynamic> params = {
        'path': filePath,
        'volumeName': 'external_primary',
        'relativePath': filePath.replaceFirst('$path/', ''),
        'mimeType': mimeType,
      };

      await const MethodChannel('com.example.img_syncer/RunGrpcServer')
          .invokeMethod('scanFile', params);
    } on PlatformException catch (e) {
      logger.addLog('Failed to scan file $filePath: ${e.message}');
    }
  }
}

Future<void> refreshUnsynchronizedPhotos() async {
  if (assetModel.localGetting != null) {
    await assetModel.localGetting!.future;
  }
  await checkServer();
  if (!settingModel.isRemoteStorageSetted) {
    stateModel.setSyncedPhotos([]);
    return;
  }
  final re = await requestPermission();
  if (!re) return;
  if (stateModel.refreshingUnsynchronized) {
    return;
  }
  logger.addLog("refresh unsynchronized photos");
  stateModel.setRefreshingUnsynchronized(true);
  stateModel.updateLastRefreshUnsyncTime(null);
  final requests = StreamController<FilterNotUploadedRequest>();
  final responses = storageClient.cli.filterNotUploaded(requests.stream);
  // W7-T1: 两阶段提交 - 先积累新ID，成功后一次性替换，避免中断时丢失
  final List<String> newSyncedIDs = [];
  await Future.wait([
    sendFilterNotUploadedRequests(requests),
    receiveResponses(responses, accumulatedIDs: newSyncedIDs),
  ]);

  // 未被中断
  if (!assetModel.refreshUnsynchronizedNeedBreak) {
    // W7-T2: Set 去重后再写入
    stateModel.setSyncedPhotos(newSyncedIDs.toSet().toList());
    await stateModel.saveSyncedIDs();
    stateModel.updateLastRefreshUnsyncTime(DateTime.now());
  }
  assetModel.refreshUnsynchronizedNeedBreak = false;
  stateModel.setRefreshingUnsynchronized(false);
}

Future<void> sendFilterNotUploadedRequests(
    StreamController<FilterNotUploadedRequest> requests) async {
  var photos = List<FilterNotUploadedRequestInfo>.empty(growable: true);
  for (var asset in assetModel.localAssets) {
    if (assetModel.refreshUnsynchronizedNeedBreak) {
      await requests.close();
      return;
    }
    final local = asset.local;
    if (local == null) continue;
    var date = effectiveCreateDate(
        local.createDateTime, local.modifiedDateTime);
    late String name;
    name = await asset.name();
    final dateStr =
        formatDate(date, [yyyy, ':', mm, ':', dd, ' ', HH, ':', nn, ':', ss]);
    photos.add(FilterNotUploadedRequestInfo(
      id: local.id,
      name: name,
      date: dateStr,
    ));
    if (photos.length >= 100) {
      requests.add(FilterNotUploadedRequest(photos: photos));
      photos.clear();
    }
  }
  if (photos.isNotEmpty) {
    requests.add(FilterNotUploadedRequest(photos: photos));
  }
  await requests.close();
}

Future<void> receiveResponses(
    Stream<FilterNotUploadedResponse> responses,
    {List<String>? accumulatedIDs}) async {
  await for (var response in responses) {
    if (!response.success) {
      logger.addLog('Error: ${response.message}');
      SnackBarManager.showSnackBar("Error: ${response.message}");
      continue;
    }
    if (accumulatedIDs != null) {
      // W7-T1: 两阶段提交 - 仅积累，不立即写入
      accumulatedIDs.addAll(response.uploadedIDs);
    } else {
      // W7-T2: Set 去重
      final merged = {...stateModel.syncedIDs, ...response.uploadedIDs}.toList();
      stateModel.setSyncedPhotos(merged);
    }
    // 使用新字段名，兼容旧字段名
    final ids = response.notUploadedIDs.isEmpty
        ? response.notUploaedIDs
        : response.notUploadedIDs;
    logger.addLog('filter: ${ids.length} not uploaded');
  }
}

Future<void> loadUnsynchronizedPhotos() async {
  final prefs = await SharedPreferences.getInstance();
  final jsonString = prefs.getString('synced_ids');
  if (jsonString != null) {
    final cache = jsonDecode(jsonString);
    List<String> newList = [];
    for (var id in cache) {
      newList.add(id);
    }
    stateModel.setSyncedPhotos(newList);
  }
}

Future<FilterNotUploadedRequestInfo> _createFilterNotUploadedRequestInfo(
    asset) async {
  var date = effectiveCreateDate(asset.createDateTime, asset.modifiedDateTime);
  final dateStr =
      formatDate(date, [yyyy, ':', mm, ':', dd, ' ', HH, ':', nn, ':', ss]);
  var name = await asset.titleAsync;
  return FilterNotUploadedRequestInfo(
    id: asset.id,
    name: name,
    date: dateStr,
  );
}
