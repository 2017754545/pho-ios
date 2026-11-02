import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:img_syncer/asset.dart';
import 'package:img_syncer/state_model.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:img_syncer/storage/storage.dart';
import 'package:img_syncer/global.dart';
import 'package:img_syncer/sync/background_runner.dart';
import 'package:img_syncer/sync/bg_task_scheduler.dart';

Timer? autoSyncTimer;

/// 后台定时同步是否正在跑：Timer 回调是 async 的，一轮跑得比 interval
/// 长时下一次 tick 会重叠进入；两轮 runSyncOnce 还会共享 needStopSync
/// 中断标志。running 时跳过 tick，finally 里清标志（抛错也清）。
bool _autoSyncRunning = false;

Future<void> reloadAutoSyncTimer() async {
  if (autoSyncTimer != null) {
    autoSyncTimer!.cancel();
  }
  // iOS 不使用 Timer.periodic：由系统 BGProcessingTask 调度后台同步。
  // 但仍需读 backgroundSyncEnabled：用户未开后台同步时不提交 BG task，
  // 与 Android 路径行为一致（避免每次启动都无条件 schedule）。
  // scheduleBgTaskViaChannel 内部已捕获异常，模拟器上的 .unavailable 不会冒泡。
  if (Platform.isIOS) {
    final prefs = await SharedPreferences.getInstance();
    final backgroundSyncEnable =
        prefs.getBool('backgroundSyncEnabled') ?? false;
    if (!backgroundSyncEnable) {
      // 关闭后台同步：撤回已提交的 BG task（此前只不提交新任务，
      // 已提交的仍会被系统唤醒）。Native handler 缺失时返回 false
      // 记日志，不抛错。
      await cancelBgTaskViaChannel();
      return;
    }
    await scheduleBgTaskViaChannel();
    return;
  }
  final prefs = await SharedPreferences.getInstance();
  final backgroundSyncEnable = prefs.getBool('backgroundSyncEnabled') ?? false;
  if (!backgroundSyncEnable) return;
  final backgroundSyncInterval =
      Duration(minutes: prefs.getInt('backgroundSyncInterval') ?? 60 * 12);
  print("backgroundSyncInterval: $backgroundSyncInterval");
  autoSyncTimer = Timer.periodic(backgroundSyncInterval, (timer) async {
    if (_autoSyncRunning) {
      print("auto sync skipped: previous run still in flight");
      return;
    }
    _autoSyncRunning = true;
    try {
      await _runAutoSyncTick(prefs);
    } finally {
      _autoSyncRunning = false;
    }
  });
}

/// 一次后台定时同步 tick 的本体（与 Timer 回调分离，便于 in-flight
/// 守卫与 finally 清理；抛错由守卫的 finally 消化标志位，不吞异常本身
/// 之外的状态）。
Future<void> _runAutoSyncTick(SharedPreferences prefs) async {
    print("start auto sync");
    if (settingModel.localFolder == "" || !settingModel.isRemoteStorageSetted) {
      return;
    }
    final wifiOnly = prefs.getBool('backgroundSyncWifiOnly') ?? true;
    if (wifiOnly) {
      final results = await Connectivity().checkConnectivity();
      if (!results.contains(ConnectivityResult.wifi)) {
        return;
      }
    }
    if (stateModel.isUploading() || stateModel.isDownloading()) return;
    await refreshUnsynchronizedPhotos();
    final Map<String, bool> uploadedIds = {};
    for (final id in stateModel.syncedIDs) {
      uploadedIds[id] = true;
    }
    final entities = await getPhotos();
    final all = entities.map((e) => Asset(local: e)).toList();
    // 重置中断标志：后台定时同步独立于手动 sync 的 stop 状态。
    stateModel.needStopSync = false;
    // 上传筛选统一由 runSyncOnce 内部的 shouldSyncAsset 执行：先查已上传
    // ID，再跑 settingModel.uploadFilter 的自定义筛选（类型 / 日期边界 /
    // 扩展名；筛选关闭时全部通过）。Android 后台任务保持串行
    //（parallelCount: 1）；iOS 后台入口读设置并封顶为 2。
    await runSyncOnce(
      storage: storageClient,
      assets: all,
      uploadedIds: uploadedIds,
      parallelCount: 1,
      shouldStop: () => stateModel.needStopSync,
      refreshUnSync: true,
    );
}

Future<List<AssetEntity>> getPhotos() async {
  List<AssetEntity> all = [];
  final re = await requestPermission();
  if (!re) return all;
  final List<AssetPathEntity> paths =
      await PhotoManager.getAssetPathList(type: RequestType.common);
  for (var path in paths) {
    if (path.name == settingModel.localFolder) {
      final newpath = await path.fetchPathProperties(
          filterOptionGroup: FilterOptionGroup(
        orders: [
          const OrderOption(
            type: OrderOptionType.createDate,
            asc: false,
          ),
        ],
      ));
      int assetOffset = 0;
      int assetPageSize = 100;
      while (true) {
        final List<AssetEntity> assets = await newpath!.getAssetListRange(
            start: assetOffset, end: assetOffset + assetPageSize);
        if (assets.isEmpty) {
          break;
        }
        all.addAll(assets);
        assetOffset += assetPageSize;
      }
      break;
    }
  }
  return all;
}