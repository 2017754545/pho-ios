import 'package:flutter_test/flutter_test.dart';
import 'package:img_syncer/asset.dart';
import 'package:img_syncer/state_model.dart';
import 'package:img_syncer/sync/background_runner.dart';
import 'package:img_syncer/sync/upload_filter.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('UploadFilterConfig.allows 纯谓词', () {
    test('关闭时全部允许（其余条件全部命中也不排除）', () {
      final config = UploadFilterConfig(
        enabled: false,
        noVideo: true,
        noImage: true,
        after: DateTime(2025, 1, 1),
        extensionAllowed: {'.jpg': false},
      );
      expect(
        config.allows(
            isVideo: true, date: DateTime(2020, 1, 1), extensionStr: '.jpg'),
        isTrue,
      );
    });

    test('noVideo 只排除视频，noImage 只排除图片', () {
      final config = UploadFilterConfig(enabled: true, noVideo: true);
      expect(
        config.allows(
            isVideo: true, date: DateTime(2024, 6, 1), extensionStr: '.mp4'),
        isFalse,
      );
      expect(
        config.allows(
            isVideo: false, date: DateTime(2024, 6, 1), extensionStr: '.jpg'),
        isTrue,
      );

      final noImage = UploadFilterConfig(enabled: true, noImage: true);
      expect(
        noImage.allows(
            isVideo: false, date: DateTime(2024, 6, 1), extensionStr: '.jpg'),
        isFalse,
      );
      expect(
        noImage.allows(
            isVideo: true, date: DateTime(2024, 6, 1), extensionStr: '.mp4'),
        isTrue,
      );
    });

    test('日期边界：早于 after 排除，等于 after 通过；晚于 before 排除，等于 before 通过', () {
      final config = UploadFilterConfig(
        enabled: true,
        after: DateTime(2024, 6, 15),
        before: DateTime(2024, 6, 20),
      );
      expect(
        config.allows(
            isVideo: false, date: DateTime(2024, 6, 14), extensionStr: ''),
        isFalse,
      );
      expect(
        config.allows(
            isVideo: false, date: DateTime(2024, 6, 15), extensionStr: ''),
        isTrue,
      );
      expect(
        config.allows(
            isVideo: false, date: DateTime(2024, 6, 20), extensionStr: ''),
        isTrue,
      );
      expect(
        config.allows(
            isVideo: false, date: DateTime(2024, 6, 21), extensionStr: ''),
        isFalse,
      );
    });

    test('扩展名不区分大小写；未出现在 map 里默认允许；空串跳过检查', () {
      final config = UploadFilterConfig(
        enabled: true,
        extensionAllowed: {'.gif': false},
      );
      expect(
        config.allows(
            isVideo: false, date: DateTime(2024, 6, 1), extensionStr: '.GIF'),
        isFalse,
      );
      expect(
        config.allows(
            isVideo: false, date: DateTime(2024, 6, 1), extensionStr: 'gif'),
        isFalse,
      );
      expect(
        config.allows(
            isVideo: false, date: DateTime(2024, 6, 1), extensionStr: '.jpg'),
        isTrue,
      );
      expect(
        config.allows(
            isVideo: false, date: DateTime(2024, 6, 1), extensionStr: ''),
        isTrue,
      );
    });
  });

  group('UploadFilterConfig 序列化', () {
    test('toJson/fromJson 往返一致（含日期与扩展名）', () {
      final config = UploadFilterConfig(
        enabled: true,
        noVideo: true,
        after: DateTime(2024, 1, 2, 3, 4, 5),
        before: DateTime(2024, 12, 31),
        extensionAllowed: {'.gif': false, '.heic': true},
      );
      final restored = UploadFilterConfig.fromJson(config.toJson());
      expect(restored.enabled, isTrue);
      expect(restored.noVideo, isTrue);
      expect(restored.noImage, isFalse);
      expect(restored.after, DateTime(2024, 1, 2, 3, 4, 5));
      expect(restored.before, DateTime(2024, 12, 31));
      expect(restored.extensionAllowed, {'.gif': false, '.heic': true});
    });

    test('fromJson 容错：缺失/错类型字段回退默认，扩展名归一化', () {
      final restored = UploadFilterConfig.fromJson({
        'enabled': 'yes',
        'extensions': {'.JPG': false, '': true, 'png': true},
      });
      expect(restored.enabled, isFalse);
      expect(restored.extensionAllowed, {'.jpg': false, '.png': true});
    });

    test('SharedPreferences 往返：保存后加载一致；损坏内容回退默认', () async {
      SharedPreferences.setMockInitialValues({});
      final config = UploadFilterConfig(
        enabled: true,
        noImage: true,
        extensionAllowed: {'.gif': false},
      );
      await saveUploadFilterConfig(config);
      final loaded = await loadUploadFilterConfig();
      expect(loaded.enabled, isTrue);
      expect(loaded.noImage, isTrue);
      expect(loaded.extensionAllowed, {'.gif': false});

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('upload_filter_config', '{broken json');
      final fallback = await loadUploadFilterConfig();
      expect(fallback.enabled, isFalse);
      expect(fallback.extensionAllowed, isEmpty);
    });
  });

  group('shouldSyncAsset 与筛选的组合', () {
    late SettingModel original;

    setUp(() {
      original = settingModel;
      settingModel = SettingModel();
    });

    tearDown(() {
      settingModel = original;
    });

    Asset makeAsset({
      required String id,
      required int createYear,
      required int modifiedYear,
      bool isVideo = false,
    }) {
      final entity = AssetEntity(
        id: id,
        typeInt: isVideo ? 2 : 1,
        width: 100,
        height: 100,
        createDateSecond:
            DateTime(createYear, 6, 1).millisecondsSinceEpoch ~/ 1000,
        modifiedDateSecond:
            DateTime(modifiedYear, 6, 1).millisecondsSinceEpoch ~/ 1000,
        title: '$id.jpg',
      );
      return Asset(local: entity, remote: null);
    }

    test('已上传检查优先：已上传的即使被筛选排除也返回 false（同一结果，两条路径）', () {
      settingModel.setUploadFilter(
          UploadFilterConfig(enabled: true, noImage: true));
      final asset = makeAsset(id: 'u1', createYear: 2024, modifiedYear: 2024);
      expect(shouldSyncAsset(asset, 'u1', {'u1': true}, '.jpg'), isFalse);
    });

    test('未上传 + 筛选排除 → false；未上传 + 筛选允许 → true', () {
      settingModel.setUploadFilter(
          UploadFilterConfig(enabled: true, noImage: true));
      final image = makeAsset(id: 'i1', createYear: 2024, modifiedYear: 2024);
      expect(shouldSyncAsset(image, 'i1', {}, '.jpg'), isFalse);
      final video = makeAsset(
          id: 'v1', createYear: 2024, modifiedYear: 2024, isVideo: true);
      expect(shouldSyncAsset(video, 'v1', {}, '.mp4'), isTrue);
    });

    test('1990 回退：createDateTime 无效时按 modifiedDateTime 判定日期边界', () {      settingModel.setUploadFilter(UploadFilterConfig(
        enabled: true,
        after: DateTime(2024, 1, 1),
      ));
      // create 1980（无效）+ modified 2024-06-01：按 modified 判定 → 通过。
      final fallback = makeAsset(id: 'f1', createYear: 1980, modifiedYear: 2024);
      expect(shouldSyncAsset(fallback, 'f1', {}, '.jpg'), isTrue);

      settingModel.setUploadFilter(UploadFilterConfig(
        enabled: true,
        after: DateTime(2025, 1, 1),
      ));
      // 同一资产，after 提到 2025：modified 2024-06-01 早于 after → 排除。
      expect(shouldSyncAsset(fallback, 'f1', {}, '.jpg'), isFalse);

      // create 有效时用 create（modified 更旧也不影响）。
      settingModel.setUploadFilter(UploadFilterConfig(
        enabled: true,
        after: DateTime(2024, 1, 1),
      ));
      final normal = makeAsset(id: 'n1', createYear: 2024, modifiedYear: 1980);
      expect(shouldSyncAsset(normal, 'n1', {}, '.jpg'), isTrue);
    });
  });

  group('结束日上界换算（B2：选择器选中的结束日全天保留）', () {
    test('exclusiveBeforeBound/inclusiveEndDay 往返，含闰月与跨年', () {
      expect(
        UploadFilterConfig.exclusiveBeforeBound(DateTime(2024, 6, 1)),
        DateTime(2024, 6, 2),
      );
      expect(
        UploadFilterConfig.exclusiveBeforeBound(DateTime(2024, 2, 28)),
        DateTime(2024, 2, 29),
      );
      expect(
        UploadFilterConfig.exclusiveBeforeBound(DateTime(2024, 12, 31)),
        DateTime(2025, 1, 1),
      );
      expect(
        UploadFilterConfig.inclusiveEndDay(DateTime(2024, 6, 2)),
        DateTime(2024, 6, 1),
      );
      expect(
        UploadFilterConfig.inclusiveEndDay(DateTime(2025, 1, 1)),
        DateTime(2024, 12, 31),
      );
    });

    test('选中结束日 6 月 1 日：当天 15:30 与 23:59 保留，次日 00:01 排除', () {
      // 走选择器同一换算：选中日 -> 内部存储的上界，再跑 allows()。
      final stored = UploadFilterConfig.exclusiveBeforeBound(DateTime(2024, 6, 1));
      final config = UploadFilterConfig(enabled: true, before: stored);
      expect(
        config.allows(
            isVideo: false,
            date: DateTime(2024, 6, 1, 15, 30),
            extensionStr: ''),
        isTrue,
      );
      expect(
        config.allows(
            isVideo: false,
            date: DateTime(2024, 6, 1, 23, 59, 59),
            extensionStr: ''),
        isTrue,
      );
      expect(
        config.allows(
            isVideo: false,
            date: DateTime(2024, 6, 2, 0, 1),
            extensionStr: ''),
        isFalse,
      );
      // 恰等于上界 instant（6 月 2 日 00:00）时 isAfter 为假，通过；
      // 这与锁定的“等于 before 通过”语义一致，上界本身不排除。
      expect(
        config.allows(
            isVideo: false, date: DateTime(2024, 6, 2), extensionStr: ''),
        isTrue,
      );
    });

    test('上界经 JSON 往返后语义不变', () {
      final config = UploadFilterConfig(
        enabled: true,
        before: UploadFilterConfig.exclusiveBeforeBound(DateTime(2024, 6, 1)),
      );
      final restored = UploadFilterConfig.fromJson(config.toJson());
      expect(restored.before, DateTime(2024, 6, 2));
      expect(
        restored.allows(
            isVideo: false,
            date: DateTime(2024, 6, 1, 15, 30),
            extensionStr: ''),
        isTrue,
      );
    });
  });
}
