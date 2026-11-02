import 'dart:async';

import 'package:async_locks/async_locks.dart';
import 'package:img_syncer/asset.dart';
import 'package:img_syncer/event_bus.dart';
import 'package:img_syncer/logger/logger.dart';
import 'package:img_syncer/state_model.dart';
import 'package:img_syncer/storage/storage_interface.dart';
import 'package:img_syncer/util.dart';
import 'package:path/path.dart';

/// 一次同步的汇总结果。
class SyncResult {
  final int succeeded;
  final int failed;
  final int total;
  final Duration duration;

  /// key = assetId, value = error.toString()
  final Map<String, String> failures;

  const SyncResult({
    required this.succeeded,
    required this.failed,
    required this.total,
    required this.duration,
    required this.failures,
  });
}

/// UI 副作用回调（可选）。background_runner 本身不触碰 UI；
/// 调用方（sync_body / sync_timer）通过此回调驱动 UI / 状态更新。
class SyncCallbacks {
  /// 进度回调：(completed, total, failed)。
  final void Function(int completed, int total, int failed)? onProgress;

  /// 单张资产上传失败回调：(assetId, error)。
  final void Function(String assetId, String error)? onAssetFailed;

  const SyncCallbacks({this.onProgress, this.onAssetFailed});
}

/// 统一的同步判定：同步的三个位置（计数、上传、展示）必须使用相同逻辑。
/// 提取为顶层函数以便测试与跨调用方复用（sync_body / sync_timer / background_runner）。
///
/// 顺序固定，不可反：先查已上传 ID（增量去重），再跑用户自定义筛选
/// （settingModel.uploadFilter，默认关闭 = 全部通过）。
/// 日期取法：local 非空时用 [effectiveCreateDate]（1990 前的无效
/// createDateTime 回退到 modifiedDateTime）；local 为空时回退到
/// [Asset.dateCreated]（既无 local 又无 remote 的资产返回 DateTime.now()，
/// 该路径在 runSyncOnce 边界已被跳过，见下）。筛选谓词本身只读 Asset 的
/// 虚方法（isVideo()/dateCreated()）与调用方传入的扩展名。
bool shouldSyncAsset(
    Asset asset, String id, Map<String, bool> uploadedIds, String extensionStr) {
  if (uploadedIds[id] == true) {
    return false;
  }
  final filter = settingModel.uploadFilter;
  if (!filter.enabled) {
    return true;
  }
  final local = asset.local;
  final date = local != null
      ? effectiveCreateDate(local.createDateTime, local.modifiedDateTime)
      : asset.dateCreated();
  return filter.allows(
    isVideo: asset.isVideo(),
    date: date,
    extensionStr: extensionStr,
  );
}

/// 手动上传守卫：供 gallery 手动上传路径（uploadSelected / 单张上传）在
/// 调用 storage 之前复用与自动同步同一套判定（已上传去重 + 自定义筛选）。
/// 返回 true 才允许上传；false 表示该资产已被筛选排除或已上传，调用方
/// 应跳过上传（并可自行提示用户）。filter 关闭时与历史行为一致：除已
/// 上传外全部允许。注意：本函数只做判定，不执行上传；调用方接线见
/// 协调员待办（gallery_body.dart / gallery_viewer_route.dart）。
Future<bool> shouldUploadManually(
    Asset asset, Map<String, bool> uploadedIds) async {
  final local = asset.local;
  if (local == null) {
    return false;
  }
  return shouldSyncAsset(asset, local.id, uploadedIds,
      extension(await asset.name()));
}

/// 待上传项：第一遍解析出的资产 + 扩展名 + local id（扩展名只解析一次）。
class _PendingAsset {
  final Asset asset;
  final String extensionStr;
  final String localId;
  const _PendingAsset(this.asset, this.extensionStr, this.localId);
}

/// 执行一次同步。纯逻辑，无 UI 副作用（无 setState / keepScreenOn / SnackBar / mounted 检查）。
///
/// [storage] 上传客户端（测试可注入 mock，通过 storageClient getter 注入）。
/// [assets] 待同步的本地资产列表；local 为 null 的资产在边界跳过并记日志，
///   不计入总数（此前直接 `asset.local!` 抛错，中断整轮同步）。
/// [uploadedIds] 已上传 ID 集合（O(1) 查重），不会被本函数原地修改。
/// [parallelCount] 并发上传数；<=0 时按 1 处理（此前 Semaphore(0) 死锁 / 抛错）。
/// [callbacks] 可选的 UI 回调（进度 / 单张失败）；回调抛错只记日志，
///   不影响上传结果、不泄漏信号量许可。
/// [shouldStop] 中断检查回调，返回 true 时尽快停止当前同步轮。
/// [refreshUnSync] 结束时 fire 的 RemoteRefreshEvent.refreshUnSync 标志，
///   sync_body 传 false（仅刷新远端列表），sync_timer 传 true（还刷新未同步集合）。
///
/// 完成时调用 stateModel.saveSyncedIDs() 持久化并通过 eventBus 广播刷新事件。
Future<SyncResult> runSyncOnce({
  required RemoteStorageClient storage,
  required List<Asset> assets,
  required Map<String, bool> uploadedIds,
  required int parallelCount,
  SyncCallbacks? callbacks,
  required bool Function() shouldStop,
  bool refreshUnSync = false,
}) async {
  final startTime = DateTime.now();
  final Map<String, String> failures = {};
  int failedTimes = 0;
  int completed = 0;
  int failed = 0;

  // 并发数钳制：<=0 视为 1，避免 Semaphore(0) 死锁。
  final effectiveParallelCount = parallelCount <= 0 ? 1 : parallelCount;

  // 第一遍：计算待同步集合。扩展名只解析一次（此前计数遍与上传遍
  // 各调一次 asset.name()），结果复用到上传遍；local 为 null 的跳过。
  final pending = <_PendingAsset>[];
  for (var asset in assets) {
    final local = asset.local;
    if (local == null) {
      logger.addLog('runSyncOnce: skipping asset with null local');
      continue;
    }
    final ext = extension(await asset.name());
    if (shouldSyncAsset(asset, local.id, uploadedIds, ext)) {
      pending.add(_PendingAsset(asset, ext, local.id));
    }
  }
  final total = pending.length;

  callbacks?.onProgress?.call(completed, total, failed);

  final sem = Semaphore(effectiveParallelCount);
  for (var item in pending) {
    // 先拿许可再检查中断/断连：拿许可的过程会等待在途任务完成，
    // 检查时 failedTimes 已包含它们的最新结果。原实现在检查与拿许可
    // 之间还有一次 await asset.name() 起同样的“等待”作用；本实现把
    // name() 提前到第一遍后，检查若留在 acquire 之前会系统性地落后
    // 一个任务（串行时第 12 张也会被尝试，违背锁定的 >10 语义）。
    await sem.acquire();
    // failedTimes 是净失败计数：失败 +1、成功 -1（下限 0），不是连续
    // 失败次数；净失败超阈值即中止（原 SnackBar 通知由调用方负责，此处仅 break）。
    // 阈值 >10 由测试锁定，勿改。
    if (shouldStop() || failedTimes > 10) {
      sem.release();
      break;
    }
    final localId = item.localId;
    final local = item.asset.local!;
    unawaited(() async {
      Object? uploadError;
      try {
        await storage.uploadAssetEntity(local);
      } catch (e) {
        uploadError = e;
      }
      try {
        if (uploadError == null) {
          if (failedTimes > 0) {
            failedTimes--;
          }
          completed++;
          callbacks?.onProgress?.call(completed, total, failed);
        } else {
          failedTimes++;
          completed++;
          failed++;
          failures[localId] = uploadError.toString();
          callbacks?.onAssetFailed?.call(localId, uploadError.toString());
          callbacks?.onProgress?.call(completed, total, failed);
          logger.addLog('uploadAssetEntity failed: $uploadError');
        }
      } catch (e) {
        // 回调抛错只记日志：不把回调错误记为上传失败，更不泄漏许可。
        logger.addLog('sync callback failed: $e');
      } finally {
        // 许可必须在 finally 里释放：回调抛错也不能让 drain 循环永远等待。
        sem.release();
      }
    }());
  }
  // 等待所有在途任务完成：获取全部permit（sem 为局部对象，随后GC，无需release）。
  for (var i = 0; i < effectiveParallelCount; i++) {
    await sem.acquire();
  }

  await stateModel.saveSyncedIDs();
  eventBus.fire(RemoteRefreshEvent(refreshUnSync: refreshUnSync));

  return SyncResult(
    succeeded: completed - failed,
    failed: failed,
    total: total,
    duration: DateTime.now().difference(startTime),
    failures: failures,
  );
}
