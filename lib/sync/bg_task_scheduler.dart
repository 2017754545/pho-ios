import 'package:flutter/services.dart';
import 'package:img_syncer/logger/logger.dart';

/// 通过 platform channel 调度 / 取消 iOS BGProcessingTask。
///
/// 在 headless entrypoint 与 UI 层共用：iOS 上 `reloadAutoSyncTimer()` 不再创建
/// `Timer.periodic`，而是调用本函数向系统提交 `BGProcessingTaskRequest`，由系统
/// 在合适的时机唤醒应用执行后台同步。
///
/// Android 端不走此路径，仍使用 `Timer.periodic` 轮询。
///
/// 两个函数都返回是否成功，失败只记日志、不抛异常：
/// - iOS 模拟器上 BGTaskScheduler 恒抛 `unavailable`，平台限制
/// - 真机上 backgroundRefreshStatus 受限或系统调度失败也属于非致命情形
/// 避免启动期 reloadAutoSyncTimer 的 unhandled exception 打断应用初始化。
/// 调用方需要知道成败时读返回值；历史的“抛 MissingPluginException”
/// 契约已随本改动废弃（bg_task_scheduler_test 由 Area D 同步更新）。
Future<bool> scheduleBgTaskViaChannel() async {
  try {
    await const MethodChannel('com.example.img_syncer/notifications')
        .invokeMethod('scheduleBgTask');
    return true;
  } catch (e) {
    logger.addLog('[bgTaskScheduler] scheduleBgTask failed: $e');
    return false;
  }
}

/// 撤回已提交的 BGProcessingTask（关闭后台同步时调用，避免已提交的任务
/// 在用户关闭后仍被系统唤醒执行）。
///
/// Native 侧尚无 `cancelBgTask` handler（AppDelegate.swift 需新增
/// `BGTaskScheduler.shared.cancel(taskWithIdentifier:)` 分支，见协调员
/// 待办）：在 handler 落地前本调用返回 false 并记日志，不抛异常。
Future<bool> cancelBgTaskViaChannel() async {
  try {
    await const MethodChannel('com.example.img_syncer/notifications')
        .invokeMethod('cancelBgTask');
    return true;
  } catch (e) {
    logger.addLog('[bgTaskScheduler] cancelBgTask failed: $e');
    return false;
  }
}
