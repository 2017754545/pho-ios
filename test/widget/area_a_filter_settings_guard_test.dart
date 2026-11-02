import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:img_syncer/filter_settings_route.dart';
import 'package:img_syncer/l10n/app_localizations.dart';
import 'package:img_syncer/state_model.dart';
import 'package:img_syncer/sync/upload_filter.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// FK-9 / FK-3 回归：不一致的筛选配置（日期倒置、同时排除图片
/// 与视频）在设置页内警告并禁用保存，而不是静默存入；日期
/// 选择器的初始范围不把倒置配置压成单日。
void main() {
  late SettingModel original;

  setUp(() {
    original = settingModel;
    settingModel = SettingModel();
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    settingModel = original;
  });

  Future<void> pumpRoute(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const FilterSettingsRoute(),
      ),
    );
    await tester.pumpAndSettle();
  }

  TextButton saveButton(WidgetTester tester) =>
      tester.widget<TextButton>(find.widgetWithText(TextButton, 'Save'));

  testWidgets('同时排除图片与视频：警告并禁用保存', (tester) async {
    settingModel.setUploadFilter(UploadFilterConfig(
      enabled: true,
      noVideo: true,
      noImage: true,
    ));
    await pumpRoute(tester);

    expect(
      find.text(
          'Excluding both photos and videos means nothing will be uploaded.'),
      findsOneWidget,
    );
    expect(saveButton(tester).onPressed, isNull);
  });

  testWidgets('日期倒置：警告并禁用保存', (tester) async {
    settingModel.setUploadFilter(UploadFilterConfig(
      enabled: true,
      after: DateTime(2024, 6, 10),
      before: UploadFilterConfig.exclusiveBeforeBound(DateTime(2024, 6, 5)),
    ));
    await pumpRoute(tester);

    expect(
      find.text(
          'The start date is after the end date. Fix the date range before saving.'),
      findsOneWidget,
    );
    expect(saveButton(tester).onPressed, isNull);

    // 未保存：持久化配置仍是默认（全部允许）。
    final loaded = await loadUploadFilterConfig();
    expect(loaded.enabled, isFalse);
  });

  testWidgets('一致的配置：保存可用，无警告', (tester) async {
    settingModel.setUploadFilter(UploadFilterConfig(
      enabled: true,
      noVideo: true,
      after: DateTime(2024, 6, 1),
      before: UploadFilterConfig.exclusiveBeforeBound(DateTime(2024, 6, 5)),
    ));
    await pumpRoute(tester);

    expect(
      find.text(
          'Excluding both photos and videos means nothing will be uploaded.'),
      findsNothing,
    );
    expect(
      find.text(
          'The start date is after the end date. Fix the date range before saving.'),
      findsNothing,
    );
    expect(saveButton(tester).onPressed, isNotNull);
  });

  testWidgets('筛选关闭时，旧的不一致字段不阻塞保存', (tester) async {
    settingModel.setUploadFilter(UploadFilterConfig(
      enabled: false,
      noVideo: true,
      noImage: true,
      after: DateTime(2024, 6, 10),
      before: UploadFilterConfig.exclusiveBeforeBound(DateTime(2024, 6, 5)),
    ));
    await pumpRoute(tester);
    expect(saveButton(tester).onPressed, isNotNull);
  });

  testWidgets('双击保存不重复写入、不抛错', (tester) async {
    settingModel.setUploadFilter(UploadFilterConfig(enabled: true));
    await pumpRoute(tester);

    await tester.tap(find.text('Save'));
    await tester.pump();
    final saveFinder = find.text('Save');
    if (saveFinder.evaluate().isNotEmpty) {
      await tester.tap(saveFinder);
    }
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final loaded = await loadUploadFilterConfig();
    expect(loaded.enabled, isTrue);
  });

  test('initialFilterDateRange：倒置配置展开为跨度，不压单日', () {
    final now = DateTime(2024, 6, 20);
    final range = initialFilterDateRange(
      DateTime(2024, 6, 10),
      UploadFilterConfig.exclusiveBeforeBound(DateTime(2024, 6, 5)),
      now,
    );
    expect(range.start, DateTime(2024, 6, 5));
    expect(range.end, DateTime(2024, 6, 10));
  });

  test('initialFilterDateRange：正常配置原样，空值取默认', () {
    final now = DateTime(2024, 6, 20);
    final range = initialFilterDateRange(
      DateTime(2024, 6, 1),
      UploadFilterConfig.exclusiveBeforeBound(DateTime(2024, 6, 5)),
      now,
    );
    expect(range.start, DateTime(2024, 6, 1));
    expect(range.end, DateTime(2024, 6, 5));

    final defaults = initialFilterDateRange(null, null, now);
    expect(defaults.start, DateTime(2023, 6, 20));
    expect(defaults.end, DateTime(2024, 6, 20));
  });
}
