import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:img_syncer/asset.dart';
import 'package:img_syncer/global.dart';
import 'package:img_syncer/state_model.dart';
import 'package:img_syncer/storage/storage.dart';
import 'package:img_syncer/storage/storage_interface.dart';
import 'package:img_syncer/sync/background_runner.dart';
import 'package:img_syncer/sync/upload_filter.dart';
import 'package:mockito/mockito.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 手写 mock（与 test/unit/sync_logic_test.dart 同一模式）：覆写
/// uploadAssetEntity 时把形参扩为可空，避免 mockito 的 any/Null 问题。
class _FakeStorage extends Mock implements RemoteStorageClient {
  @override
  Future<void> uploadAssetEntity(AssetEntity? asset) async =>
      super.noSuchMethod(
        Invocation.method(#uploadAssetEntity, [asset]),
        returnValue: Future<void>.value(),
        returnValueForMissingStub: Future<void>.value(),
      );
}

AssetEntity _entity(String id, String title) {
  final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  return AssetEntity(
    id: id,
    typeInt: 1,
    width: 100,
    height: 100,
    createDateSecond: nowSec,
    modifiedDateSecond: nowSec,
    title: title,
  );
}

Asset _asset(String id, String title) {
  assetModel.titleCache[id] = title;
  return Asset(local: _entity(id, title));
}

void main() {
  late bool originalUseRemoteServer;

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    originalUseRemoteServer = useRemoteServer;
    useRemoteServer = true;
    settingModel = SettingModel();
    assetModel = AssetModel();
    stateModel = StateModel();
    settingModel.isRemoteStorageSetted = true;
    settingModel.enableFilter = false;
    assetModel.titleCache = {};
    stateModel.needStopSync = false;
  });

  tearDown(() {
    useRemoteServer = originalUseRemoteServer;
    lastAliveTime = null;
  });

  group('UP-11 storageHttpUri：文件名按段编码', () {
    test('空格/#/? 标题不被截断，pathSegments 往返还原原标题', () {
      httpBaseUrl = 'http://127.0.0.1:12345';
      for (final title in ['my photo.jpg', 'a#b.jpg', 'a?b.jpg', '100%.jpg']) {
        final uri = storageHttpUri([title]);
        expect(uri.pathSegments.last, title);
        expect(Uri.parse(uri.toString()).pathSegments.last, title);
      }
      expect(
        storageHttpUri(['my photo #1.jpg']).toString(),
        contains('my%20photo%20%231.jpg'),
      );
      expect(
        storageHttpUri(['thumbnail', 'a?b.jpg']).toString(),
        contains('/thumbnail/a%3Fb.jpg'),
      );
    });

    test('多段路径（日期目录 + 文件名）逐段编码', () {
      httpBaseUrl = 'http://127.0.0.1:12345';
      final uri = storageHttpUri(['2024', '01', 'a#b.jpg']);
      expect(uri.path, '/2024/01/a%23b.jpg');
      expect(uri.pathSegments, ['2024', '01', 'a#b.jpg']);
    });

    test('baseUrl 快照参数优先于全局 httpBaseUrl', () {
      httpBaseUrl = 'http://127.0.0.1:1111';
      final uri = storageHttpUri(['x.jpg'],
          baseUrl: 'http://127.0.0.1:9999');
      expect(uri.port, 9999);
    });
  });

  group('UP-10 uploadRetryDelay 退避 + 抖动', () {
    test('指数增长且有封顶，抖动在 0–249ms 内', () {
      final random = Random(42);
      final d1 = uploadRetryDelay(1, random: random);
      final d2 = uploadRetryDelay(2, random: random);
      final d3 = uploadRetryDelay(3, random: random);
      final d10 = uploadRetryDelay(10, random: random);
      expect(d1.inMilliseconds, inInclusiveRange(500, 749));
      expect(d2.inMilliseconds, inInclusiveRange(1000, 1249));
      expect(d3.inMilliseconds, inInclusiveRange(2000, 2249));
      expect(d10.inMilliseconds, inInclusiveRange(8000, 8249));
    });
  });

  group('UP-6 parallelCount 钳制', () {
    test('parallelCount=0 与负数按 1 处理，不死锁、全部上传', () async {
      final mock = _FakeStorage();
      setStorageForTest(mock);
      when(mock.uploadAssetEntity(any)).thenAnswer((_) async {
        await Future.delayed(const Duration(milliseconds: 20));
      });
      for (final count in [0, -3]) {
        final result = await runSyncOnce(
          storage: mock,
          assets: [_asset('a$count', 'a$count.jpg')],
          uploadedIds: {},
          parallelCount: count,
          shouldStop: () => false,
        ).timeout(const Duration(seconds: 10));
        expect(result.total, 1);
        expect(result.succeeded, 1);
      }
      verify(mock.uploadAssetEntity(any)).called(2);
    });
  });

  group('UP-1 回调抛错不泄漏信号量许可', () {
    test('onProgress 抛错：全部上传完成、不挂起、不记为失败', () async {
      final mock = _FakeStorage();
      when(mock.uploadAssetEntity(any)).thenAnswer((_) async {});
      var calls = 0;
      final result = await runSyncOnce(
        storage: mock,
        assets: [
          _asset('a', 'a.jpg'),
          _asset('b', 'b.jpg'),
          _asset('c', 'c.jpg'),
        ],
        uploadedIds: {},
        parallelCount: 1,
        callbacks: SyncCallbacks(
          onProgress: (completed, total, failed) {
            calls++;
            if (completed > 0) throw Exception('progress boom');
          },
        ),
        shouldStop: () => false,
      ).timeout(const Duration(seconds: 10));
      expect(calls, greaterThan(0));
      expect(result.total, 3);
      expect(result.failed, 0);
      expect(result.succeeded, 3);
      verify(mock.uploadAssetEntity(any)).called(3);
    });

    test('onAssetFailed 抛错：失败仍计数、其余资产继续上传', () async {
      final mock = _FakeStorage();
      when(mock.uploadAssetEntity(any)).thenAnswer((inv) async {
        final entity = inv.positionalArguments[0] as AssetEntity;
        if (entity.id == 'b') throw Exception('network down');
      });
      final result = await runSyncOnce(
        storage: mock,
        assets: [
          _asset('a', 'a.jpg'),
          _asset('b', 'b.jpg'),
          _asset('c', 'c.jpg'),
        ],
        uploadedIds: {},
        parallelCount: 1,
        callbacks: SyncCallbacks(
          onAssetFailed: (id, error) {
            throw Exception('callback boom');
          },
        ),
        shouldStop: () => false,
      ).timeout(const Duration(seconds: 10));
      expect(result.total, 3);
      expect(result.failed, 1);
      expect(result.succeeded, 2);
      expect(result.failures['b'], contains('network down'));
      verify(mock.uploadAssetEntity(any)).called(3);
    });
  });

  group('FK-2 runSyncOnce 边界：local 为 null 的资产跳过', () {
    test('不抛错、不计入总数，其余资产正常上传', () async {
      final mock = _FakeStorage();
      when(mock.uploadAssetEntity(any)).thenAnswer((_) async {});
      final nullLocal = Asset(local: null, remote: null);
      final result = await runSyncOnce(
        storage: mock,
        assets: [nullLocal, _asset('good', 'good.jpg')],
        uploadedIds: {},
        parallelCount: 1,
        shouldStop: () => false,
      ).timeout(const Duration(seconds: 10));
      expect(result.total, 1);
      expect(result.succeeded, 1);
      verify(mock.uploadAssetEntity(any)).called(1);
    });
  });

  group('FK-6 shouldUploadManually 手动上传守卫', () {
    test('筛选排除 / 已上传 / local 为 null 时 false，允许时 true', () async {
      settingModel.setUploadFilter(UploadFilterConfig(
          enabled: true, extensionAllowed: {'.gif': false}));
      final gif = _asset('g1', 'photo.gif');
      expect(await shouldUploadManually(gif, {}), isFalse);

      final jpg = _asset('j1', 'photo.jpg');
      expect(await shouldUploadManually(jpg, {}), isTrue);
      expect(await shouldUploadManually(jpg, {'j1': true}), isFalse);

      expect(
          await shouldUploadManually(Asset(local: null, remote: null), {}),
          isFalse);
    });

    test('筛选关闭时除已上传外全部允许（与自动同步一致）', () async {
      settingModel.setUploadFilter(UploadFilterConfig(enabled: false));
      expect(await shouldUploadManually(_asset('j2', 'photo.jpg'), {}),
          isTrue);
    });
  });

  group('UP-14 checkServer 并发去重', () {
    test('并发 checkServer 共享同一轮：runServer 只调一次', () async {
      useRemoteServer = false;
      lastAliveTime = null;
      var runServerCalls = 0;
      const channel = MethodChannel('com.example.img_syncer/RunGrpcServer');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'RunGrpcServer') {
          runServerCalls++;
          return '50099,50098';
        }
        return null;
      });
      // ping 目标为关闭端口，失败后走重启路径；initDrive 无 drive 配置时
      // 不发 gRPC 调用，直接返回。Global.init 未跑过，late 的端口全局
      // 需先初始化（_checkServerOnce 的日志行会读 grpcPort）。
      grpcPort = 1;
      httpPort = 2;
      httpBaseUrl = 'http://127.0.0.1:2';
      setGlobalStorage(RemoteStorage('127.0.0.1', 1));
      try {
        await Future.wait([
          checkServer(),
          checkServer(),
          checkServer(),
        ]).timeout(const Duration(seconds: 30));
      } finally {
        messenger.setMockMethodCallHandler(channel, null);
        setGlobalStorage(RemoteStorage('127.0.0.1', 10000));
      }
      expect(runServerCalls, 1);
    });
  });
}
