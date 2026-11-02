import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:img_syncer/filter_settings_route.dart';
import 'package:img_syncer/l10n/app_localizations.dart';
import 'package:img_syncer/state_model.dart';
import 'package:img_syncer/sync/upload_filter.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// B1 回归：设置页的扩展名输入框是 deny-list（要排除的扩展名）。
/// 驱动真实的 FilterSettingsRoute：回填只显示 false 条目，保存写
/// false，且往返不销毁已有 false 条目。
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

  testWidgets('回填只显示被排除的扩展名，保存后 false 条目不丢失', (tester) async {
    settingModel.setUploadFilter(UploadFilterConfig(
      enabled: true,
      extensionAllowed: {'.gif': false, '.jpg': true},
    ));
    await pumpRoute(tester);

    // true 条目不显示，只有被排除的 gif 回填进输入框。
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, 'gif');

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final loaded = await loadUploadFilterConfig();
    expect(loaded.enabled, isTrue);
    expect(loaded.extensionAllowed, {'.gif': false});
  });

  testWidgets('新输入的扩展名保存为 false（排除），未列出的默认允许', (tester) async {
    await pumpRoute(tester);

    // 默认未启用筛选：先打开启用开关，再输入。
    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'heic, WEBP');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final loaded = await loadUploadFilterConfig();
    expect(loaded.extensionAllowed, {'.heic': false, '.webp': false});
    expect(
      loaded.allows(
          isVideo: false,
          date: DateTime(2024, 6, 1),
          extensionStr: '.heic'),
      isFalse,
    );
    expect(
      loaded.allows(
          isVideo: false, date: DateTime(2024, 6, 1), extensionStr: '.jpg'),
      isTrue,
    );
  });

  // FK-22：B2 的 UI 换算（_pickDateRange/_dateRangeText/清除日期）
  // 此前无 widget 测试。Feb-29 / 非闰 Feb-28 单元用例已由 Area B
  // 在 test/unit/area_b_pure_test.dart 补齐，此处不重复，只测
  // 选择器往返与清除的 UI 行为。
  testWidgets('日期范围回显换算回选中日，清除日期后保存为空', (tester) async {
    settingModel.setUploadFilter(UploadFilterConfig(
      enabled: true,
      after: DateTime(2024, 2, 28),
      // 内部存上界（选中日次日 00:00）：2 月 29 日（闰年）→ 3 月 1 日。
      before: UploadFilterConfig.exclusiveBeforeBound(DateTime(2024, 2, 29)),
    ));
    await pumpRoute(tester);

    // 回显须换算回用户选中的结束日（2 月 29 日），不能多显示一天。
    expect(find.text('2024-02-28 ~ 2024-02-29'), findsOneWidget);

    await tester.tap(find.text('Clear dates'));
    await tester.pumpAndSettle();
    expect(find.text('Not set'), findsOneWidget);

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final loaded = await loadUploadFilterConfig();
    expect(loaded.after, isNull);
    expect(loaded.before, isNull);
  });

  testWidgets('选择器往返：打开后直接确认默认范围，保存的上界不变', (tester) async {
    settingModel.setUploadFilter(UploadFilterConfig(
      enabled: true,
      after: DateTime(2024, 2, 28),
      before: UploadFilterConfig.exclusiveBeforeBound(DateTime(2024, 2, 29)),
    ));
    await pumpRoute(tester);

    // 打开日期范围选择器（初始范围即当前配置换算回的选中日区间）。
    await tester.tap(find.text('Date range (both end days included)'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);

    // 不改动选择，直接确认：_pickDateRange 按同一换算写回上界。
    await tester.tap(find.descendant(
      of: find.byType(Dialog),
      matching: find.text('Save'),
    ));
    await tester.pumpAndSettle();
    expect(find.text('2024-02-28 ~ 2024-02-29'), findsOneWidget);

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final loaded = await loadUploadFilterConfig();
    expect(loaded.after, DateTime(2024, 2, 28));
    expect(loaded.before, DateTime(2024, 3, 1));
  });

  testWidgets('选择器取消：日期不变', (tester) async {
    settingModel.setUploadFilter(UploadFilterConfig(
      enabled: true,
      after: DateTime(2024, 2, 28),
      before: UploadFilterConfig.exclusiveBeforeBound(DateTime(2024, 2, 29)),
    ));
    await pumpRoute(tester);

    await tester.tap(find.text('Date range (both end days included)'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);

    // Flutter 3.47 的 showDateRangePicker 没有 Cancel 按钮（只有
    // Save + 标题）：取消 = 点对话框外障板（barrierDismissible），
    // 此时 _pickDateRange 拿到 null 直接 return，内存态不变。
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);

    expect(find.text('2024-02-28 ~ 2024-02-29'), findsOneWidget);
  });
}
