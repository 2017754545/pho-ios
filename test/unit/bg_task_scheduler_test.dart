// 单测：锁住 lib/sync/bg_task_scheduler.dart 的 channel 契约。
//
// 契约判定（U1）：生产侧“吞错 + 返回 bool”是 intended 行为，测试侧
// “抛 MissingPluginException”的期望是错的，理由：
//  1. 生产注释（bg_task_scheduler.dart）明确写明失败仅记日志、不抛异常，
//     因为 iOS 模拟器上 BGTaskScheduler 恒抛 unavailable，且启动期
//     reloadAutoSyncTimer 的未处理异常会打断应用初始化；
//  2. 生产已进一步把返回值从 Future<void> 改为 Future<bool>，让调用方
//     能读到成败而不靠异常——“抛异常”契约已被生产侧明确废弃
//     （见该文件注释“历史的‘抛 MissingPluginException’契约已随本改动废弃”）；
//  3. 调用方（sync_timer.dart iOS 分支、background_sync_entrypoint）
//     均按“不抛”编写，测试若坚持抛异常，与全部调用方矛盾。
// 因此修正测试：无 handler / handler 抛错时返回 false 且不抛异常；
// handler 正常返回时返回 true。本文件不再断言任何抛错行为。
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:img_syncer/sync/bg_task_scheduler.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.example.img_syncer/notifications');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('scheduleBgTaskViaChannel 调用 scheduleBgTask 方法且无参数，返回 true',
      () async {
    String? capturedMethod;
    Object? capturedArgs;

    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      capturedMethod = call.method;
      capturedArgs = call.arguments;
      return null; // native 端无返回值
    });

    final result = await scheduleBgTaskViaChannel();

    expect(result, isTrue);
    expect(capturedMethod, 'scheduleBgTask');
    expect(capturedArgs, isNull);
  });

  test('native 端未注册 handler 时不抛异常，返回 false（吞错契约）', () async {
    messenger.setMockMethodCallHandler(channel, null);

    final result = await scheduleBgTaskViaChannel();

    expect(result, isFalse);
  });

  test('native 端 handler 抛错时不抛异常，返回 false', () async {
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      throw PlatformException(code: 'unavailable');
    });

    final result = await scheduleBgTaskViaChannel();

    expect(result, isFalse);
  });

  test('cancelBgTaskViaChannel 调用 cancelBgTask 方法，返回 true', () async {
    String? capturedMethod;
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      capturedMethod = call.method;
      return null;
    });

    final result = await cancelBgTaskViaChannel();

    expect(result, isTrue);
    expect(capturedMethod, 'cancelBgTask');
  });

  test('cancelBgTaskViaChannel 无 handler 时不抛异常，返回 false', () async {
    messenger.setMockMethodCallHandler(channel, null);

    final result = await cancelBgTaskViaChannel();

    expect(result, isFalse);
  });
}
