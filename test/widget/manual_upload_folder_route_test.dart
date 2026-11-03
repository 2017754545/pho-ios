import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:img_syncer/l10n/app_localizations.dart';
import 'package:img_syncer/manual_upload_folder_route.dart';
import 'package:img_syncer/state_model.dart';
import 'package:img_syncer/sync/manual_upload_folder.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 手动上传目录设置页：驱动真实的 ManualUploadFolderRoute。
/// 选择器页需 live 服务端（目录列举 RPC），不在此测；只测设置页
/// 的回填/校验/保存与默认值语义。
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
        home: const ManualUploadFolderRoute(),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('回填已存目录，保存写回 SettingModel 与 prefs', (tester) async {
    settingModel.setManualUploadFolder('photos/manual');
    await pumpRoute(tester);

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, 'photos/manual');

    await tester.enterText(find.byType(TextField), 'other/manual');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(settingModel.manualUploadFolder, 'other/manual');
    expect(settingModel.manualUploadDestDir, 'other/manual');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(manualUploadFolderPrefsKey), 'other/manual');
  });

  testWidgets('留空保存为未设置，生效目录为默认 manual', (tester) async {
    settingModel.setManualUploadFolder('photos/manual');
    await pumpRoute(tester);

    await tester.enterText(find.byType(TextField), '');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(settingModel.manualUploadFolder, '');
    expect(settingModel.manualUploadDestDir, 'manual');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(manualUploadFolderPrefsKey), '');
  });

  testWidgets('非法目录禁用保存，已存值不被覆盖', (tester) async {
    settingModel.setManualUploadFolder('photos/manual');
    await pumpRoute(tester);

    await tester.enterText(find.byType(TextField), '../evil');
    await tester.pump();
    final saveButton = tester.widget<TextButton>(
      find.ancestor(
        of: find.text('Save'),
        matching: find.byType(TextButton),
      ),
    );
    expect(saveButton.onPressed, isNull);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(manualUploadFolderPrefsKey), isNull);
    expect(settingModel.manualUploadFolder, 'photos/manual');
  });

  testWidgets('未设置远程存储时浏览按钮提示先设置存储', (tester) async {
    // isRemoteStorageSetted 为 false（默认 SettingModel 未设存储）。
    expect(settingModel.isRemoteStorageSetted, isFalse);
    await pumpRoute(tester);

    await tester.tap(find.byIcon(Icons.open_in_browser));
    await tester.pump();
    expect(find.textContaining('remote storage'), findsOneWidget);
  });
}
