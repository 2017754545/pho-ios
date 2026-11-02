import 'package:flutter_test/flutter_test.dart';
import 'package:img_syncer/state_model.dart';
import 'package:img_syncer/sync/background_runner.dart';
import 'package:img_syncer/sync/upload_filter.dart';
import 'package:img_syncer/asset.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

// U5b：原先本文件在测试内逐行重写 global.dart 的旧 key 迁移逻辑，
// 从未调用生产代码。迁移逻辑（enalble_encrypt → enable_encrypt）
// 至今只内联在 Global.init() 的两个分支里，没有可独立调用的生产
// 入口，无法在不启动 Go server / 读相册的情况下驱动（见报告余项：
// 需 Area B 把迁移抽为独立函数后，本文件才能真正覆盖它）。
// 以下改走真实可调用的生产 prefs 路径：Global.init 与
// background_sync_entrypoint 的 Step 5 共用的加载序列——
// loadUploadFilterConfig() 读 prefs JSON，setUploadFilter /
// setParallelUploadCount 应用到 SettingModel，再由 shouldSyncAsset
// 实际判定。迁移分支本身此处不做“自证预言”式断言。

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingModel original;

  setUp(() {
    original = settingModel;
    settingModel = SettingModel();
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    settingModel = original;
  });

  Asset makeAsset(String id, {bool isVideo = false}) {
    final entity = AssetEntity(
      id: id,
      typeInt: isVideo ? 2 : 1,
      width: 100,
      height: 100,
      createDateSecond:
          DateTime(2024, 6, 1).millisecondsSinceEpoch ~/ 1000,
      modifiedDateSecond:
          DateTime(2024, 6, 1).millisecondsSinceEpoch ~/ 1000,
      title: '$id.jpg',
    );
    return Asset(local: entity);
  }

  group('prefs 加载序列（真实生产路径）', () {
    test('loadUploadFilterConfig 读 prefs 并应用到 SettingModel，判定随之变化',
        () async {
      // 模拟已持久化的筛选配置（与 FilterSettingsRoute._save 写入格式一致）。
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'upload_filter_config',
        '{"enabled":true,"noImage":true,"extensions":{".gif":false}}',
      );
      await prefs.setInt('parallel_upload_count', 3);

      // 生产加载序列（global.dart 移动端分支 / entrypoint Step 5）：
      // 读配置 → 应用到 settingModel。
      final loaded = await loadUploadFilterConfig();
      settingModel.setUploadFilter(loaded);
      final parallelCountPref = prefs.getInt('parallel_upload_count');
      if (parallelCountPref != null) {
        settingModel.setParallelUploadCount(parallelCountPref);
      }

      expect(settingModel.uploadFilter.enabled, isTrue);
      expect(settingModel.parallelUploadCount, 3);
      // 加载后的配置真实参与同步判定：图片被排除，视频通过。
      expect(
        shouldSyncAsset(makeAsset('i1'), 'i1', {}, '.jpg'),
        isFalse,
      );
      expect(
        shouldSyncAsset(makeAsset('v1', isVideo: true), 'v1', {}, '.mp4'),
        isTrue,
      );
    });

    test('prefs 为空时 loadUploadFilterConfig 回退默认（全部允许）', () async {
      final loaded = await loadUploadFilterConfig();
      settingModel.setUploadFilter(loaded);
      expect(loaded.enabled, isFalse);
      expect(
        shouldSyncAsset(makeAsset('i1'), 'i1', {}, '.jpg'),
        isTrue,
      );
    });

    test('损坏的 prefs JSON 回退默认，不阻塞加载', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('upload_filter_config', '{broken json');
      final loaded = await loadUploadFilterConfig();
      expect(loaded.enabled, isFalse);
      expect(loaded.extensionAllowed, isEmpty);
    });

    test('新写入的配置经 save/load 往返后判定一致', () async {
      final config = UploadFilterConfig(
        enabled: true,
        noVideo: true,
        extensionAllowed: {'.heic': false},
      );
      await saveUploadFilterConfig(config);
      final loaded = await loadUploadFilterConfig();
      settingModel.setUploadFilter(loaded);
      expect(
        shouldSyncAsset(makeAsset('v1', isVideo: true), 'v1', {}, '.mp4'),
        isFalse,
      );
      expect(
        shouldSyncAsset(makeAsset('i1'), 'i1', {}, '.heic'),
        isFalse,
      );
      expect(
        shouldSyncAsset(makeAsset('i2'), 'i2', {}, '.jpg'),
        isTrue,
      );
    });
  });
}
