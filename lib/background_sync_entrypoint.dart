// iOS 后台同步入口（headless FlutterEngine）。
//
// 由 AppDelegate 的 BGProcessingTask handle 创建 headless engine 后通过
// `@pragma('vm:entry-point')` 调起。复用与 UI 相同的 Dart 全局（setting /
// asset / state / storage 等），但仅做后台同步所需的最小初始化：
//   - 不调用顶层全局初始化流程（会触发 IAP / 周期定时器 / UI 副作用）
//   - 不跑自动同步定时器重载、退款检查、订阅状态检查、标题缓存加载
//   - 不调 stateModel.setSyncProgress（后台无 UI 监听）
//   - 不直接 invoke sendLocalNotification channel，用 LocalNotifier 封装
//   - 不调 keepScreenOn
//
// 完成语义（UP-7）：body 一律包在 try/finally 里，`complete` 与
// Step-11 的重新调度在 finally 里必定执行——中间任何一步抛错也不会
// 断掉 BG 链（此前只有三处 complete 调用，抛错即跳过）。成功标志
// 在 runSyncOnce 返回后置 true；其余提前返回路径按各自语义置标志后
// return，finally 统一完成。

import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:img_syncer/asset.dart';
import 'package:img_syncer/global.dart';
import 'package:img_syncer/l10n/app_localizations_en.dart';
import 'package:img_syncer/l10n/app_localizations_zh.dart';
import 'package:img_syncer/logger/logger.dart';
import 'package:img_syncer/notifications/local_notifier.dart';
import 'package:img_syncer/run_server.dart';
import 'package:img_syncer/state_model.dart';
import 'package:img_syncer/storage/storage.dart';
import 'package:img_syncer/sync/upload_filter.dart';
import 'package:img_syncer/sync/background_runner.dart';
import 'package:img_syncer/sync/bg_task_scheduler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 解析 runServer 返回的 "grpcPort,httpPort"：格式不对、端口非数字或
/// 超出 1–65535 时返回 null（此前 int.parse 直接抛错，且无 finally 兜底）。
class _ServerPorts {
  final int grpcPort;
  final int httpPort;
  const _ServerPorts(this.grpcPort, this.httpPort);
}

_ServerPorts? _parseServerPorts(String portsStr) {
  final parts = portsStr.split(',');
  if (parts.length != 2) return null;
  final grpcPort = int.tryParse(parts[0].trim());
  final httpPort = int.tryParse(parts[1].trim());
  if (grpcPort == null || httpPort == null) return null;
  if (grpcPort < 1 || grpcPort > 65535) return null;
  if (httpPort < 1 || httpPort > 65535) return null;
  return _ServerPorts(grpcPort, httpPort);
}

/// 解析 encryption_type prefs：越界/负数时返回 null（此前
/// EncryptionType.values[越界下标] 直接抛 RangeError）。
EncryptionType? _parseEncryptionType(int? raw) {
  if (raw == null) return null;
  if (raw < 0 || raw >= EncryptionType.values.length) return null;
  return EncryptionType.values[raw];
}

@pragma('vm:entry-point')
void backgroundSyncEntrypoint() async {
  // Step 1: 初始化 Flutter binding（headless engine 必须）
  WidgetsFlutterBinding.ensureInitialized();

  // Step 2: 注册 backgroundSync MethodChannel 接收 native 端的 cancel 命令
  bool cancelFlag = false;
  const bgChannel = MethodChannel('com.example.img_syncer/backgroundSync');
  bgChannel.setMethodCallHandler((call) async {
    if (call.method == 'cancel') {
      cancelFlag = true;
    }
  });

  // Headless isolate 没有 BuildContext，无法走 initI18n(context)；
  // 直接构造 localization 实例供 LocalNotifier.sendSyncCompleteNotification 使用，
  // 否则全局 `late AppLocalizations l10n` 会抛 LateInitializationError。
  l10n = Platform.localeName.toLowerCase().startsWith('zh')
      ? AppLocalizationsZh()
      : AppLocalizationsEn();

  // complete 的成功标志：默认 false；runSyncOnce 正常返回后置 true，
  // 无 drive / Wi-Fi 不符等“按预期提前结束”路径置 true 后 return。
  // finally 里必定调 schedule + complete 各一次（scheduleBgTaskViaChannel
  // 内部已捕获异常返回 bool；complete 本身的异常也在 finally 内消化）。
  bool success = false;
  try {
    success = await _runBackgroundSync(cancelFlagGetter: () => cancelFlag);
  } catch (e) {
    logger.addLog('bg sync failed: $e');
    success = false;
  } finally {
    try {
      await scheduleBgTaskViaChannel();
    } catch (e) {
      logger.addLog('bg sync: reschedule failed: $e');
    }
    try {
      await bgChannel.invokeMethod('complete', success);
    } catch (e) {
      logger.addLog('bg sync: complete failed: $e');
    }
  }
}

/// 后台同步本体。返回 true 表示“按预期完成”（含无 drive / Wi-Fi 不符
/// 的提前结束）；抛错表示失败，由调用方 finally 以 complete(false) 收尾。
/// 注意：本函数内部不再调用 schedule/complete，那是 finally 的职责。
Future<bool> _runBackgroundSync({
  required bool Function() cancelFlagGetter,
}) async {
  final prefs = await SharedPreferences.getInstance();

  // Step 4: 启动 Go server + 重建 RemoteStorage
  final portsStr = await runServer();
  final ports = _parseServerPorts(portsStr);
  if (ports == null) {
    logger.addLog('bg sync: grpc server start failed');
    // 抛错由外层 catch 记日志并置 success=false；finally 仍会重调度
    // 并以 complete(false) 收尾。
    throw Exception('bg sync: invalid server ports: $portsStr');
  }
  final grpcP = ports.grpcPort;
  final httpP = ports.httpPort;
  httpBaseUrl = 'http://127.0.0.1:$httpP';
  setGlobalStorage(RemoteStorage('127.0.0.1', grpcP));

  // Step 3（后移）：只有 server 真正起来后才写 last_bg_sync_time。
  // 此前在 server 启动前就写，server 起不来也留下一条“跑过”的记录。
  await prefs.setString('last_bg_sync_time', DateTime.now().toIso8601String());

  // Step 5: 最小 init 序列 — 应用 prefs 到 settingModel（参考 global.dart 的 init 模式）
  final localFolder = prefs.getString('localFolder');
  if (localFolder != null && localFolder.isNotEmpty) {
    settingModel.setLocalFolder(localFolder);
  }

  final enableEncrypt = prefs.getBool('enable_encrypt');
  if (enableEncrypt != null) {
    settingModel.setEncryptSwitch(enableEncrypt);
  }
  final encryptionType = _parseEncryptionType(prefs.getInt('encryption_type'));
  if (encryptionType != null) {
    settingModel.setEncryptionType(encryptionType);
  }
  final encPassword = prefs.getString('encryption_password');
  if (encPassword != null) {
    settingModel.setEncryptionPassword(encPassword);
  }

  // iOS 自用功能：并行上传数与自定义筛选配置（后台同步与前台一致，
  // 否则同一张照片在前台/后台的同步判定会不一致）。本入口只在 iOS
  // 运行，仍显式 gate，与 global.dart 的加载门保持同一语义（FK-5）。
  if (Platform.isIOS) {
    final parallelCountPref = prefs.getInt('parallel_upload_count');
    if (parallelCountPref != null) {
      settingModel.setParallelUploadCount(parallelCountPref);
    }
    settingModel.setUploadFilter(await loadUploadFilterConfig());
  }

  // Step 6: 初始化 drive（依赖 Step 4 设置的 storage）
  await initDrive();

  // Step 6b (UP-8)：未配置 drive 时提前结束——不要继续 refresh/sync。
  // refreshUnsynchronizedPhotos 会先清空 syncedIDs，之后每张资产都
  // 失败直到 breaker 跳闸；无 drive 时同步本就不可能成功。
  if (!settingModel.isRemoteStorageSetted) {
    logger.addLog('bg sync: no drive configured, skipping sync');
    return true;
  }

  // Step 9 前移 (UP-9)：Wi-Fi 门在 server 刷新之前。原顺序先跑 Step 8
  // 的 refreshUnsynchronizedPhotos（一次 server round-trip）再查 Wi-Fi，
  // 蜂窝唤醒时白白浪费一次往返。
  final wifiOnly = prefs.getBool('backgroundSyncWifiOnly') ?? true;
  if (wifiOnly) {
    final connectivityResults = await Connectivity().checkConnectivity();
    if (!connectivityResults.contains(ConnectivityResult.wifi)) {
      logger.addLog('bg sync: wifi required but not connected, rescheduling');
      return true;
    }
  }

  // Step 7: 填充 assetModel.localAssets
  // 预置 titleCache（Asset 构造器会访问 assetModel.titleCache），后台不读持久化缓存
  assetModel.titleCache = {};
  final re = await requestPermission();
  if (re) {
    final List<AssetPathEntity> paths =
        await PhotoManager.getAssetPathList(type: RequestType.common);
    for (var path in paths) {
      if (path.name == settingModel.localFolder) {
        int assetOffset = 0;
        const int assetPageSize = 100;
        while (true) {
          final List<AssetEntity> entities = await path.getAssetListRange(
              start: assetOffset, end: assetOffset + assetPageSize,);
          if (entities.isEmpty) break;
          for (final entity in entities) {
            final asset = Asset(local: entity);
            assetModel.localAssets.add(asset);
          }
          assetOffset += assetPageSize;
        }
        break;
      }
    }
  }

  // Step 8: 刷新未同步照片（建立 uploadedIds 基线）
  await refreshUnsynchronizedPhotos();

  // Step 10: 执行同步
  final Map<String, bool> uploadedIds = {};
  for (final id in stateModel.syncedIDs) {
    uploadedIds[id] = true;
  }
  final result = await runSyncOnce(
    storage: storageClient,
    assets: assetModel.localAssets,
    uploadedIds: uploadedIds,
    // BGProcessingTask 有时长限制，并行数封顶为 2，避免后台任务
    // 超时被系统杀掉；前台同步不受此封顶限制。
    parallelCount: settingModel.parallelUploadCount < 2
        ? settingModel.parallelUploadCount
        : 2,
    shouldStop: cancelFlagGetter,
    refreshUnSync: true,
  );

  // Step 11: 完成后处理。记账/日志/通知失败不翻转同步结果：
  // runSyncOnce 已返回即视为同步完成，complete(true) 由调用方 finally 发出。
  try {
    await prefs.setInt('last_bg_sync_success_count', result.succeeded);
    await prefs.setInt('last_bg_sync_fail_count', result.failed);

    final docDir = await getApplicationDocumentsDirectory();
    final logFile = File('${docDir.path}/bg_sync.log');
    await logFile.writeAsString(
      '${DateTime.now().toIso8601String()} | succeeded: ${result.succeeded}, failed: ${result.failed}, duration: ${result.duration.inSeconds}s\n',
      mode: FileMode.append,
    );

    // 发送同步完成通知（封装在 LocalNotifier，succeeded == 0 时静默不发）
    await LocalNotifier.sendSyncCompleteNotification(
      succeeded: result.succeeded,
      failed: result.failed,
    );
  } catch (e) {
    logger.addLog('bg sync: post-sync bookkeeping failed: $e');
  }

  return true;
}
