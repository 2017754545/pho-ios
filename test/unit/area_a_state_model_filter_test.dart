import 'package:flutter_test/flutter_test.dart';
import 'package:img_syncer/state_model.dart';
import 'package:img_syncer/sync/upload_filter.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// FK-4 / FK-10 / FK-12 回归：历史 setter 保留（sync_body_test 锁定
/// 其存在）但必须持久化；setUploadFilter 替换引用并归一化非午夜
/// before；live map 的引用失效语义有文档与测试锁定。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('setter 状态经重启往返（FK-4）', () {
    test('setter 写入后，重新加载得到同一配置', () async {
      final sm = SettingModel();
      sm.setFilterSwitch(true);
      sm.setFilterNoVideo(true);
      sm.setFilterAfter(DateTime(2024, 6, 15));
      sm.filterTypeMap = {'.gif': false};

      // setter 的持久化是排队异步写入：等写入链排空再模拟重启加载。
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final loaded = await loadUploadFilterConfig();
      expect(loaded.enabled, isTrue);
      expect(loaded.noVideo, isTrue);
      expect(loaded.noImage, isFalse);
      expect(loaded.after, DateTime(2024, 6, 15));
      expect(loaded.extensionAllowed, {'.gif': false});

      // “重启”：全新 SettingModel 用加载到的配置替换。
      final restarted = SettingModel();
      restarted.setUploadFilter(loaded);
      expect(restarted.enableFilter, isTrue);
      expect(restarted.uploadFilter.noVideo, isTrue);
      expect(restarted.uploadFilter.after, DateTime(2024, 6, 15));
    });

    test('enableFilter 与 setFilterSwitch 是同一份数据', () {
      final sm = SettingModel();
      sm.enableFilter = true;
      expect(sm.uploadFilter.enabled, isTrue);
      sm.setFilterSwitch(false);
      expect(sm.enableFilter, isFalse);
    });
  });

  group('setUploadFilter 引用失效与 before 归一化（FK-10/FK-12）', () {
    test('替换后旧配置对象不再是生效配置', () {
      final sm = SettingModel();
      final oldConfig = sm.uploadFilter;
      final oldMap = sm.filterTypeMap;
      sm.setUploadFilter(UploadFilterConfig(enabled: true));
      expect(identical(sm.uploadFilter, oldConfig), isFalse);
      expect(identical(sm.filterTypeMap, oldMap), isFalse);
      // 旧对象上的修改不再影响生效配置。
      oldConfig.enabled = false;
      expect(sm.uploadFilter.enabled, isTrue);
    });

    test('非午夜 before 被归一化为次日 00:00，结束日回显正确', () {
      final sm = SettingModel();
      sm.setUploadFilter(UploadFilterConfig(
        enabled: true,
        before: DateTime(2024, 6, 1, 15, 30),
      ));
      expect(sm.uploadFilter.before, DateTime(2024, 6, 2));
      expect(
        UploadFilterConfig.inclusiveEndDay(sm.uploadFilter.before!),
        DateTime(2024, 6, 1),
      );
    });

    test('午夜 before 原样保留（原始边界语义，不可区分）', () {
      final sm = SettingModel();
      sm.setUploadFilter(UploadFilterConfig(
        enabled: true,
        before: DateTime(2024, 6, 20),
      ));
      expect(sm.uploadFilter.before, DateTime(2024, 6, 20));
    });

    test('setFilterBefore 存原始值，不做 exclusive 换算（锁定语义）', () {
      final sm = SettingModel();
      sm.setFilterBefore(DateTime(2024, 6, 1));
      expect(sm.uploadFilter.before, DateTime(2024, 6, 1));
    });

    test('filterTypeMapSnapshot 是副本，改副本不影响配置', () {
      final sm = SettingModel();
      sm.filterTypeMap = {'.gif': false};
      final snapshot = sm.filterTypeMapSnapshot;
      snapshot['.jpg'] = false;
      expect(sm.uploadFilter.extensionAllowed, {'.gif': false});
      expect(snapshot, {'.gif': false, '.jpg': false});
    });
  });
}
