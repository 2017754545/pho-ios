// 单测：锁住 lib/sync_body.dart 中 syncPhotos() 的当前同步行为。
//
// 4 个场景：
//   (a) happy: 3 张全部上传成功
//   (b) partial: 2 成功 1 失败（uploadAssetEntity 内部 retry 3 次后 throw）
//   (c) interrupt: 跑到第 2 张时设 stateModel.needStopSync=true，断言第 3 张不上传且 sem 不泄漏
//   (d) wifi-off: 测 Connectivity().checkConnectivity() 返回 mobile 时 caller 提前 return
//   (e) parallel: parallelCount=3 时 3 张真正并发上传，一个失败不阻塞其他
//
// Mock 用 build_runner 生成的 MockRemoteStorageClient
// （test/unit/mocks/remote_storage_mock.mocks.dart，Mockito 5.4.6，
// U8：生成文件与当前 RemoteStorageClient 接口一致——uploadXFile
// 已随接口移除后重生成；手写 mock 已删除）。
// 生成 mock 的 uploadAssetEntity 形参为可空 AssetEntity?，故
// when/verify 里的 any/argThat 可直接用（手写 implements 版本
// 因非空形参无法用 any，才需要覆写——此处不再需要）。
import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:img_syncer/asset.dart';
import 'package:img_syncer/global.dart';
import 'package:grpc/grpc.dart' as grpc;
import 'package:img_syncer/proto/img_syncer.pbgrpc.dart';
import 'package:img_syncer/state_model.dart';
import 'package:img_syncer/storage/storage.dart';
import 'package:img_syncer/storage/storage_interface.dart';
import 'package:img_syncer/sync_body.dart';
import 'package:img_syncer/sync_timer.dart';
import 'package:mockito/mockito.dart';
import 'mocks/remote_storage_mock.mocks.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';


/// tick 测试用的假 gRPC 客户端：filterNotUploaded 返回一条空的
/// 成功响应（无已上传 ID），不触真实网络。ResponseStream 需一个
/// ClientCall：用 Mock 实现，仅 response getter 被实际使用
/// （receiveResponses 只 for-await 它）。
class _FakeFilterCall extends Mock
    implements
        grpc.ClientCall<
            FilterNotUploadedRequest, FilterNotUploadedResponse> {
  @override
  Stream<FilterNotUploadedResponse> get response =>
      Stream<FilterNotUploadedResponse>.value(
        FilterNotUploadedResponse(success: true),
      );
}

class _FakeImgSyncerClient extends ImgSyncerClient {
  _FakeImgSyncerClient()
      : super(grpc.ClientChannel(
          '127.0.0.1',
          port: 1,
          options: const grpc.ChannelOptions(
            credentials: grpc.ChannelCredentials.insecure(),
          ),
        ));

  @override
  grpc.ResponseStream<FilterNotUploadedResponse> filterNotUploaded(
    Stream<FilterNotUploadedRequest> request, {
    grpc.CallOptions? options,
  }) {
    unawaited(request.drain());
    return grpc.ResponseStream<FilterNotUploadedResponse>(_FakeFilterCall());
  }
}

/// tick 测试用的 storage double：cli 走假 gRPC 客户端，上传计数。
class _TickStorage extends Mock implements RemoteStorageClient {
  final _client = _FakeImgSyncerClient();
  var uploadCalls = 0;

  @override
  ImgSyncerClient get cli => _client;

  @override
  Future<void> uploadAssetEntity(AssetEntity? asset) async {
    uploadCalls++;
  }
}

/// 测试专用 SyncBody 子类：覆盖 build() 跳过 columnBuilder 的
/// 缩略图平台通道加载，仅暴露继承自 SyncBodyState 的 syncPhotos()。
class _SyncBodyHarness extends SyncBody {
  const _SyncBodyHarness({required String localFolder})
      : super(localFolder: localFolder);
  @override
  SyncBodyState createState() => _SyncBodyHarnessState();
}

class _SyncBodyHarnessState extends SyncBodyState {
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// 构造一个 type=image 的 AssetEntity（标题预填，避免 name() 触发 titleAsync 平台通道）。
AssetEntity _makeAssetEntity(String id) {
  final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  return AssetEntity(
    id: id,
    typeInt: 1, // AssetType.image（见 photo_manager enums.dart:21）
    width: 100,
    height: 100,
    createDateSecond: nowSec,
    modifiedDateSecond: nowSec,
    title: '$id.jpg',
  );
}

/// 构造 Asset 并预填 titleCache（Asset 构造器会读 assetModel.titleCache[id]）。
Asset _makeAsset(String id) {
  assetModel.titleCache[id] = '$id.jpg';
  return Asset(local: _makeAssetEntity(id));
}

/// 轮询直到 syncPhotos 完成（syncing==false），最长 ~5s。
Future<void> _waitForSyncDone(WidgetTester tester, _SyncBodyHarnessState state) async {
  for (var i = 0; i < 100; i++) {
    if (!state.syncing) return;
    await tester.pump(const Duration(milliseconds: 50));
  }
  fail('syncPhotos 未在 5s 内完成（可能 sem 泄漏或上传未结束）');
}

const _connChannel = MethodChannel('dev.fluttercommunity.plus/connectivity');

// FK-20：MethodChannel.setMockMethodCallHandler 已废弃，改用
// TestDefaultBinaryMessengerBinding 的 messenger（当前 API）。
final _messenger =
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

void main() {
  late bool originalUseRemoteServer;

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    originalUseRemoteServer = useRemoteServer;
    // 让 checkServer() 立即返回（global.dart:255），避免真实 gRPC ping 挂起测试。
    useRemoteServer = true;

    // 重置 4 个全局单例，保证用例间隔离
    settingModel = SettingModel();
    assetModel = AssetModel();
    stateModel = StateModel();
    settingModel.parallelUploadCount = 3;
    settingModel.isRemoteStorageSetted = true;
    settingModel.enableFilter = false;
    assetModel.titleCache = {};
    stateModel.needStopSync = false;

    // 清上个用例残留的 override（占位 mock，后续用例各自替换）
    setStorageForTest(MockRemoteStorageClient());
  });

  tearDown(() {
    useRemoteServer = originalUseRemoteServer;
    autoSyncTimer?.cancel();
    autoSyncTimer = null;
    _messenger.setMockMethodCallHandler(_connChannel, null);
  });

  group('syncPhotos 同步行为锁住', () {
    testWidgets('(a) happy: 3 张照片全部上传成功', (tester) async {
      final mock = MockRemoteStorageClient();
      setStorageForTest(mock);
      when(mock.uploadAssetEntity(any)).thenAnswer((_) async {});

      assetModel.localAssets = [
        _makeAsset('a'),
        _makeAsset('b'),
        _makeAsset('c'),
      ];

      await tester.pumpWidget(
          const MaterialApp(home: _SyncBodyHarness(localFolder: 'Test')));
      final state =
          tester.state<_SyncBodyHarnessState>(find.byType(_SyncBodyHarness));

      state.syncPhotos();
      await _waitForSyncDone(tester, state);

      // 全部 3 张都应被上传
      verify(mock.uploadAssetEntity(any)).called(3);
      // happy 路径无失败记录
      expect(state.uploadFailedMap, isEmpty);
    });

    testWidgets('(b) partial: 2 成功 1 失败（retry 3 次后 throw）', (tester) async {
      final mock = MockRemoteStorageClient();
      setStorageForTest(mock);
      final assetA = _makeAsset('a');
      final assetB = _makeAsset('b');
      final assetC = _makeAsset('c');
      // 默认成功；assetC 模拟「uploadAssetEntity 内部 retry 3 次耗尽后 throw」
      when(mock.uploadAssetEntity(any)).thenAnswer((_) async {});
      when(mock.uploadAssetEntity(argThat(equals(assetC.local!))))
          .thenThrow(Exception('network down: retry exhausted'));

      assetModel.localAssets = [assetA, assetB, assetC];

      await tester.pumpWidget(
          const MaterialApp(home: _SyncBodyHarness(localFolder: 'Test')));
      final state =
          tester.state<_SyncBodyHarnessState>(find.byType(_SyncBodyHarness));

      state.syncPhotos();
      await _waitForSyncDone(tester, state);

      // syncPhotos 对每张只调用一次 uploadAssetEntity（retry 在其内部，见 storage.dart:130-241）
      verify(mock.uploadAssetEntity(any)).called(3);
      // 失败的 assetC 应被记录到 uploadFailedMap
      expect(state.uploadFailedMap['c'], isNotNull);
      expect(state.uploadFailedMap['c'], contains('network down'));
      // 成功的 a / b 不在失败 Map 中
      expect(state.uploadFailedMap.containsKey('a'), isFalse);
      expect(state.uploadFailedMap.containsKey('b'), isFalse);
    });

    testWidgets('(e) parallel: parallelCount=3 时 3 张真正并发上传，一个失败不阻塞其他',
        (tester) async {
      final mock = MockRemoteStorageClient();
      setStorageForTest(mock);
      settingModel.parallelUploadCount = 3;
      var active = 0;
      var maxActive = 0;
      when(mock.uploadAssetEntity(any)).thenAnswer((inv) async {
        final entity = inv.positionalArguments[0] as AssetEntity;
        active++;
        if (active > maxActive) maxActive = active;
        await Future.delayed(const Duration(milliseconds: 120));
        active--;
        if (entity.id == 'b') throw Exception('network down');
      });

      assetModel.localAssets = [
        _makeAsset('a'),
        _makeAsset('b'),
        _makeAsset('c'),
      ];

      await tester.pumpWidget(
          const MaterialApp(home: _SyncBodyHarness(localFolder: 'Test')));
      final state =
          tester.state<_SyncBodyHarnessState>(find.byType(_SyncBodyHarness));

      state.syncPhotos();
      await _waitForSyncDone(tester, state);

      // 3 张同时在传：并发峰值必须达到 3（串行时峰值恒为 1）。
      expect(maxActive, 3);
      verify(mock.uploadAssetEntity(any)).called(3);
      // 失败的 b 被记录，a / c 不受影响。
      expect(state.uploadFailedMap['b'], isNotNull);
      expect(state.uploadFailedMap.containsKey('a'), isFalse);
      expect(state.uploadFailedMap.containsKey('c'), isFalse);
    });

    testWidgets('(c) interrupt: 第 2 张上传时设 needStopSync=true，第 3 张不上传且 sem 不泄漏',
        (tester) async {
      final mock = MockRemoteStorageClient();
      setStorageForTest(mock);
      // 串行上传：确保 b 完成并触发 needStopSync=true 后，c 才进入循环检查
      settingModel.parallelUploadCount = 1;
      final assetA = _makeAsset('a');
      final assetB = _makeAsset('b');
      final assetC = _makeAsset('c');
      // 第 2 张（id=b）上传时触发中断标志
      when(mock.uploadAssetEntity(any)).thenAnswer((inv) async {
        final entity = inv.positionalArguments[0] as AssetEntity;
        if (entity.id == 'b') {
          stateModel.needStopSync = true;
        }
      });

      assetModel.localAssets = [assetA, assetB, assetC];

      await tester.pumpWidget(
          const MaterialApp(home: _SyncBodyHarness(localFolder: 'Test')));
      final state =
          tester.state<_SyncBodyHarnessState>(find.byType(_SyncBodyHarness));

      state.syncPhotos();
      await _waitForSyncDone(tester, state);

      // 第 3 张（id=c）不应被上传
      verifyNever(mock.uploadAssetEntity(argThat(equals(assetC.local!))));
      // sem 不泄漏：syncPhotos 正常结束（syncing=false），_waitForSyncDone 也会先校验这点
      expect(state.syncing, isFalse);
    });
  });

  // FK-21：原 (d) 只断言本地重算的布尔值，从未触及生产守卫，
  // 且 NOTE 称守卫“尚未实现”已过时。真实架构（sync_timer.dart，
  // 2026-11-02 现状）：
  //   * reloadAutoSyncTimer() 本身不查 connectivity：非 iOS 注册
  //     Timer.periodic，iOS 调 scheduleBgTaskViaChannel；wifi 守卫
  //     在每个 tick 的 _runAutoSyncTick() 里（wifiOnly 且非 wifi
  //     时 return）。因此“reload 时 wifi-off 就不调度”在生产里
  //     不成立——以下按真实架构断言：reload 只决定 timer 有无，
  //     wifi-off 由 tick 守卫，且 tick 不进入刷新/上传。
  //   * 若产品需要 reload 时就按 wifi  gate（不建 timer / 不提交
  //     BG task），属生产余项（Area B 改 sync_timer.dart），
  //     本组 (d2) 的断言须随之改为 autoSyncTimer isNull。
  // NOTE（旧）已删除：runSyncOnce 与 scheduleBgTaskViaChannel 均已实现。
  group('wifi-off 守卫（per-tick，sync_timer.dart）', () {
    const photoChannel = MethodChannel('com.fluttercandies/photo_manager');

    Future<void> setConnectivity(List<String> values) async {
      _messenger.setMockMethodCallHandler(_connChannel, (call) async {
        if (call.method == 'check') return values;
        return null;
      });
    }

    test('(d1) mock connectivity 通道生效：checkConnectivity() 返回 [mobile]',
        () async {
      await setConnectivity(['mobile']);
      final results = await Connectivity().checkConnectivity();
      expect(results, [ConnectivityResult.mobile]);
    });

    test('(d2) 未启用后台同步时 reloadAutoSyncTimer 不注册 timer', () async {
      SharedPreferences.setMockInitialValues({'backgroundSyncEnabled': false});
      await reloadAutoSyncTimer();
      expect(autoSyncTimer, isNull,
          reason: '未启用后台同步时 reloadAutoSyncTimer 不应注册定时器');
    });

    test('(d3) 已启用 + wifi-off 时 reload 仍注册 timer（守卫在 tick，不在 reload）',
        () async {
      await setConnectivity(['mobile']);
      SharedPreferences.setMockInitialValues({
        'backgroundSyncEnabled': true,
        'backgroundSyncInterval': 60 * 12,
      });
      await reloadAutoSyncTimer();
      expect(autoSyncTimer, isNotNull,
          reason: 'reload 不查 connectivity；wifi 守卫在 _runAutoSyncTick 内');
    });

    testWidgets('(d4) wifi-off tick 不进入刷新：synced_ids 不被写入',
        (tester) async {
      // tick 链：_runAutoSyncTick → wifi 守卫 return（在
      // refreshUnsynchronizedPhotos 之前）。观测点为刷新完成
      // 的副作用：refresh 结束时 saveSyncedIDs() 写 prefs
      // 'synced_ids'；wifi-off 时 tick 在守卫处 return，该 key
      // 始终不存在。注意 requestPermission 在桌面端直接返回
      // true（isDesktop 短路），不能用它作观测点。
      await setConnectivity(['mobile']);
      final tickStorage = _TickStorage();
      setStorageForTest(tickStorage);
      _messenger.setMockMethodCallHandler(photoChannel, (call) async {
        if (call.method == 'getAssetPathList') return <String, dynamic>{'data': <dynamic>[]};
        return null;
      });

      // 间隔取 1 分钟（prefs 单位就是分钟）：Duration.zero 的
      // Timer.periodic 在 fake async 里 pump 永不返回，禁用。
      SharedPreferences.setMockInitialValues({
        'backgroundSyncEnabled': true,
        'backgroundSyncInterval': 1,
        'backgroundSyncWifiOnly': true,
      });
      settingModel.setLocalFolder('Test');
      settingModel.isRemoteStorageSetted = true;

      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await reloadAutoSyncTimer();
      expect(autoSyncTimer, isNotNull);
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(minutes: 1));
      }
      // 体内取消：testWidgets 结束时 pending 的 periodic timer
      // 会触发 binding 的 timersPending 断言，tearDown 不够早。
      autoSyncTimer?.cancel();
      autoSyncTimer = null;

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('synced_ids'), isNull,
          reason: 'wifi-off 时 tick 应在 wifi 守卫处 return，不进入刷新');
      expect(tickStorage.uploadCalls, 0);
      expect(tester.takeException(), isNull);
      _messenger.setMockMethodCallHandler(photoChannel, null);
    });

    testWidgets('(d5) wifi-on tick 通过守卫：刷新完成并写入 synced_ids',
        (tester) async {
      // 与 (d4) 相同装置，仅 connectivity 返回 wifi：tick 通过
      // 守卫 → refresh（假 gRPC 客户端返回空成功响应）→
      // getPhotos（相册列表 mock 为空）→ runSyncOnce（空集）
      // → saveSyncedIDs 写 'synced_ids'。上传数为 0（无资产）。
      await setConnectivity(['wifi']);
      final tickStorage = _TickStorage();
      setStorageForTest(tickStorage);
      _messenger.setMockMethodCallHandler(photoChannel, (call) async {
        if (call.method == 'getAssetPathList') return <String, dynamic>{'data': <dynamic>[]};
        return null;
      });

      SharedPreferences.setMockInitialValues({
        'backgroundSyncEnabled': true,
        'backgroundSyncInterval': 1,
        'backgroundSyncWifiOnly': true,
      });
      settingModel.setLocalFolder('Test');
      settingModel.isRemoteStorageSetted = true;

      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await reloadAutoSyncTimer();
      expect(autoSyncTimer, isNotNull);
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(minutes: 1));
      }
      autoSyncTimer?.cancel();
      autoSyncTimer = null;

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('synced_ids'), '[]',
          reason: 'wifi 时 tick 应通过守卫完成刷新并持久化 syncedIDs');
      expect(tickStorage.uploadCalls, 0);
      expect(tester.takeException(), isNull);
      _messenger.setMockMethodCallHandler(photoChannel, null);
    });
  });
}