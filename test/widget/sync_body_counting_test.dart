import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:img_syncer/asset.dart';
import 'package:img_syncer/global.dart';
import 'package:img_syncer/l10n/app_localizations_en.dart';
import 'package:img_syncer/state_model.dart';
import 'package:img_syncer/storage/storage.dart';
import 'package:img_syncer/storage/storage_interface.dart';
import 'package:img_syncer/sync/upload_filter.dart';
import 'package:img_syncer/sync_body.dart';
import 'package:mockito/mockito.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeStorage extends Mock implements RemoteStorageClient {
  @override
  Future<void> uploadAssetEntity(AssetEntity? asset) async =>
      super.noSuchMethod(
        Invocation.method(#uploadAssetEntity, [asset]),
        returnValue: Future<void>.value(),
        returnValueForMissingStub: Future<void>.value(),
      );
}

/// FK-1 用 harness：build 前把 scrollOffset 置为极大，跳过缩略图与
/// 标题加载分支（平台通道），只测计数路径的扩展名解析。
class _CountingHarness extends SyncBody {
  const _CountingHarness({required String localFolder})
      : super(localFolder: localFolder);
  @override
  SyncBodyState createState() => _CountingHarnessState();
}

class _CountingHarnessState extends SyncBodyState {
  @override
  Widget build(BuildContext context) {
    scrollOffset = 1000000;
    return super.build(context);
  }
}

/// UP-2 用 harness：跳过 columnBuilder，只暴露 syncPhotos()。
class _SyncPhotosHarness extends SyncBody {
  const _SyncPhotosHarness({required String localFolder})
      : super(localFolder: localFolder);
  @override
  SyncBodyState createState() => _SyncPhotosHarnessState();
}

class _SyncPhotosHarnessState extends SyncBodyState {
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// name() 恒抛错的 Asset：模拟标题解析失败，使 runSyncOnce 在计数遍
/// 即抛错（单张上传失败由 runSyncOnce 内部消化，不会走到 syncPhotos 的
/// catch；Linux host 上 titleAsync 不走平台通道、不会抛错，故用子类）。
class _ThrowingNameAsset extends Asset {
  _ThrowingNameAsset() : super(local: _entity('x1', 'x1.jpg'));

  @override
  Future<String> name() async => throw Exception('title boom');
}

AssetEntity _entity(String id, String? title) {
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

void main() {
  late SettingModel originalSetting;
  late AssetModel originalAsset;
  late StateModel originalState;

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    originalSetting = settingModel;
    originalAsset = assetModel;
    originalState = stateModel;
    settingModel = SettingModel();
    assetModel = AssetModel();
    stateModel = StateModel();
    l10n = AppLocalizationsEn();
    settingModel.isRemoteStorageSetted = true;
    stateModel.needStopSync = false;
    setStorageForTest(_FakeStorage());
  });

  tearDown(() {
    settingModel = originalSetting;
    assetModel = originalAsset;
    stateModel = originalState;
  });

  testWidgets(
      'FK-1：localTitle 为 null、titleAsync（经 titleCache）解析为 .gif 的资产最终不计入待同步数',
      (tester) async {
    settingModel.setUploadFilter(UploadFilterConfig(
        enabled: true, extensionAllowed: {'.gif': false}));
    assetModel.titleCache = {};
    // jpg 对照：标题预填，同步路径即知扩展名，始终计入。
    assetModel.titleCache['j1'] = 'photo.jpg';
    final jpg = Asset(local: _entity('j1', 'photo.jpg'));
    // gif：构造时 titleCache 里没有它，localTitle 为 null；随后标题
    // 经 titleCache 解析为 .gif（模拟 titleAsync 尚未加载完成的状态，
    // 不走 photo_manager 平台通道）。
    final gif = Asset(local: _entity('g1', null));
    expect(gif.localTitle, isNull);
    assetModel.titleCache['g1'] = 'photo.gif';
    assetModel.localAssets = [gif, jpg];

    await tester.pumpWidget(
      ChangeNotifierProvider<StateModel>.value(
        value: stateModel,
        child: const MaterialApp(
            home: _CountingHarness(localFolder: 'Test')),
      ),
    );
    // 不用 pumpAndSettle：ThumbnailSkeleton 的 shimmer 动画永不停止，
    // settle 必然超时。标题解析是微任务级 future，几次定长 pump 足够
    // 让解析完成 + setState 重建生效。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    // 解析完成后重建：.gif 被筛选排除，只剩 jpg 一张。
    expect(find.byType(ListTile), findsOneWidget);
  });

  testWidgets('UP-2：runSyncOnce 抛错时 syncPhotos 恢复 syncing=false 与进度清零',
      (tester) async {
    final mock = _FakeStorage();
    setStorageForTest(mock);
    when(mock.uploadAssetEntity(any)).thenAnswer((_) async {});
    assetModel.titleCache = {};
    // name() 抛错使 runSyncOnce 在计数遍即抛错，走到 syncPhotos 的
    // catch/finally（单张上传失败不会走到这里，那个路径由 runSyncOnce
    // 内部消化）。
    assetModel.localAssets = [_ThrowingNameAsset()];

    await tester.pumpWidget(
        const MaterialApp(home: _SyncPhotosHarness(localFolder: 'Test')));
    final state =
        tester.state<_SyncPhotosHarnessState>(find.byType(_SyncPhotosHarness));

    state.syncPhotos();
    for (var i = 0; i < 100; i++) {
      if (!state.syncing) break;
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(state.syncing, isFalse);
    expect(stateModel.syncTotal, 0);
    expect(stateModel.syncCompleted, 0);
    verifyNever(mock.uploadAssetEntity(any));
  });
}
