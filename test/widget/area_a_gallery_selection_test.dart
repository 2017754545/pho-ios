import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:img_syncer/asset.dart';
import 'package:img_syncer/gallery_body.dart';
import 'package:img_syncer/global.dart' as global;
import 'package:img_syncer/l10n/app_localizations.dart';
import 'package:img_syncer/state_model.dart';
import 'package:photo_manager/photo_manager.dart';

/// FK-7 回归：选择以稳定资产 ID 为键。删除/分享/下载/上传都经
/// GalleryBodyState.selectedAssets() 在操作时对当前列表解析，
/// 因此本测试直接驱动该状态机：选中后列表刷新/重排/插入/删除，
/// 解析结果必须始终是当初选中的资产，绝不是“同一位置”的资产。
///
/// 注意：磁贴缩略图加载走 photo_manager 平台通道，测试环境无
/// 该通道实现，故本文件不 pump 含磁贴的重建帧；状态机本身
/// （选择/解析/剪枝）是三个操作的唯一公共路径，覆盖它即覆盖
/// 误操作根源。删除/分享/上传的平台调用（PhotoManager.editor /
/// share_plus / storage）不在此验证。
Asset _localAsset(String id, DateTime created) {
  final entity = AssetEntity(
    id: id,
    typeInt: 1,
    width: 100,
    height: 100,
    createDateSecond: created.millisecondsSinceEpoch ~/ 1000,
    modifiedDateSecond: created.millisecondsSinceEpoch ~/ 1000,
    title: '$id.jpg',
  );
  return Asset(local: entity, remote: null);
}

void main() {
  late SettingModel originalSetting;
  late AssetModel originalAsset;
  late StateModel originalState;
  late SettingModel setting;
  late AssetModel assets;
  late StateModel state;

  setUp(() {
    originalSetting = settingModel;
    originalAsset = assetModel;
    originalState = stateModel;
    setting = SettingModel();
    assets = AssetModel();
    state = StateModel();
    settingModel = setting;
    assetModel = assets;
    stateModel = state;
  });

  tearDown(() {
    // 不在这里 dispose assets：测试框架在 tearDown 后才卸载
    // widget 树，提前 dispose 会使 Consumer 摘除监听时报错；
    // 本文件创建的 AssetModel 订阅随测试进程结束而丢弃，与
    // 既有测试套件的行为一致。
    settingModel = originalSetting;
    assetModel = originalAsset;
    stateModel = originalState;
  });

  /// Close the selection bottom sheet and settle before the test
  /// ends: the sheet owns an animation ticker, and tearing the
  /// Scaffold down while it is still open fails the test. One
  /// pump first so the sheet actually builds (closing an
  /// un-built sheet trips a Scaffold assertion), then empty the
  /// list and close it so the settling rebuild renders no tiles.
  Future<void> finishGallery(
      WidgetTester tester, GalleryBodyState galleryState) async {
    await tester.pump();
    assets.localAssets = [];
    galleryState.clearSelection();
    await tester.pumpAndSettle();
  }

  Future<GalleryBodyState> pumpGallery(WidgetTester tester) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingModel>.value(value: setting),
          ChangeNotifierProvider<AssetModel>.value(value: assets),
          ChangeNotifierProvider<StateModel>.value(value: state),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) {
              global.initI18n(context);
              return Scaffold(
                body: GalleryBody(useLocal: true, showAppBar: false),
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();
    return tester.state<GalleryBodyState>(find.byType(GalleryBody));
  }

  testWidgets('选中后列表重排：解析结果仍是原资产', (tester) async {
    final galleryState = await pumpGallery(tester);
    final a = _localAsset('a', DateTime(2024, 6, 1));
    final b = _localAsset('b', DateTime(2024, 6, 2));
    final c = _localAsset('c', DateTime(2024, 6, 3));
    assets.localAssets = [a, b, c];

    galleryState.toggleSelectionForAsset(b);
    expect(galleryState.selectedAssets(), [b]);
    expect(galleryState.isAssetSelected(b), isTrue);
    expect(galleryState.isAssetSelected(a), isFalse);

    // 刷新/重排：b 移到首位，前面插入新资产；按旧位置索引
    // 解析会取到新资产 d，错误。按 id 解析必须仍取 b。
    final d = _localAsset('d', DateTime(2024, 6, 4));
    assets.localAssets = [d, b, a, c];
    expect(galleryState.selectedAssets(), [b]);
    expect(galleryState.isAssetSelected(b), isTrue);
    expect(galleryState.isAssetSelected(d), isFalse);
    expect(galleryState.isAssetSelected(a), isFalse);
    await finishGallery(tester, galleryState);
  });

  testWidgets('选中资产被删除：选择被剪枝，不误伤其余资产', (tester) async {
    final galleryState = await pumpGallery(tester);
    final a = _localAsset('a', DateTime(2024, 6, 1));
    final b = _localAsset('b', DateTime(2024, 6, 2));
    assets.localAssets = [a, b];

    galleryState.toggleSelectionForAsset(a);
    galleryState.toggleSelectionForAsset(b);
    expect(galleryState.selectedCount, 2);

    // b 被删除（例如在查看器里删掉）：解析只剩 a，b 的 id 丢弃。
    assets.localAssets = [a];
    expect(galleryState.selectedAssets(), [a]);
    expect(galleryState.selectedCount, 1);

    // 全部删除：选择清空，不返回空列表之外的任何东西。
    assets.localAssets = [];
    expect(galleryState.selectedAssets(), isEmpty);
    expect(galleryState.selectedCount, 0);
    await finishGallery(tester, galleryState);
  });

  testWidgets('相机模式开关切换导致列表成员变化：选择跟随资产', (tester) async {
    final galleryState = await pumpGallery(tester);
    final a = _localAsset('a', DateTime(2024, 6, 1));
    final b = _localAsset('b', DateTime(2024, 6, 2));
    assets.localAssets = [a, b];
    galleryState.toggleSelectionForAsset(a);

    // 模拟排除集合刷新后 b 被过滤、a 仍在（成员变化）。
    assets.cameraExcludedIds = {'b'};
    setting.onlyCameraAlbum = true;
    // 非 iOS 测试宿主上 displayLocalAssets 不过滤，故直接用
    // 成员变化模拟：列表变为仅 a。
    assets.localAssets = [a];
    expect(galleryState.selectedAssets(), [a]);

    assets.localAssets = [b];
    expect(galleryState.selectedAssets(), isEmpty);
    await finishGallery(tester, galleryState);
  });

  testWidgets('取消选择后不再解析出资产', (tester) async {
    final galleryState = await pumpGallery(tester);
    final a = _localAsset('a', DateTime(2024, 6, 1));
    assets.localAssets = [a];
    galleryState.toggleSelectionForAsset(a);
    expect(galleryState.selectedAssets(), [a]);
    // 一帧，让选择 BottomSheet 建好：未建好的 sheet 上调
    // 用 close() 会触发 Scaffold 断言（测试流程产物，真机
    // 上帧会正常跑，见 finishGallery 的说明）。
    await tester.pump();
    galleryState.toggleSelectionForAsset(a);
    expect(galleryState.selectedAssets(), isEmpty);
    galleryState.clearSelection();
    expect(galleryState.selectedAssets(), isEmpty);
    await finishGallery(tester, galleryState);
  });
}
