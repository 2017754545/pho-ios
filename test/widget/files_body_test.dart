import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:img_syncer/asset.dart';
import 'package:img_syncer/files_body.dart';
import 'package:img_syncer/files_data_source.dart';
import 'package:img_syncer/global.dart' as global;
import 'package:img_syncer/l10n/app_localizations.dart';
import 'package:img_syncer/proto/img_syncer.pbgrpc.dart';
import 'package:img_syncer/state_model.dart';
import 'package:img_syncer/storage/storage.dart';
import 'package:mockito/mockito.dart';
import 'package:provider/provider.dart';

class MockImgSyncerClient extends Mock implements ImgSyncerClient {}

class MockHttpClient extends Mock implements http.Client {}

/// Fake server listing: root has one folder + one file, nested folders
/// have one folder/file each. Paths use the drive-relative spelling.
class FakeFilesDataSource implements FilesDataSource {
  FakeFilesDataSource(this.listings);

  final Map<String, List<DirEntry>> listings;
  final List<String> listedDirs = [];
  final List<String> createdDirs = [];

  @override
  Future<List<DirEntry>> listDir(String dir) async {
    listedDirs.add(dir);
    return listings[dir] ?? [];
  }

  @override
  Future<void> createDir(String dir) async {
    createdDirs.add(dir);
  }

  @override
  Future<void> uploadToExactDir(asset, String dir) async {}
}

void main() {
  group('FilesBody back navigation', () {
    late SettingModel testSettingModel;
    late SettingModel originalModel;
    late AssetModel testAssetModel;
    late FakeFilesDataSource fakeDataSource;

    Widget buildTestWidget() {
      return MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingModel>.value(
              value: testSettingModel),
          ChangeNotifierProvider<AssetModel>.value(value: testAssetModel),
          ChangeNotifierProvider(create: (_) => StateModel()),
        ],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) {
              global.initI18n(context);
              return Scaffold(
                body: FilesBody(dataSource: fakeDataSource),
              );
            },
          ),
        ),
      );
    }

    setUp(() {
      originalModel = settingModel;
      testSettingModel = SettingModel()..isRemoteStorageSetted = true;
      // Mirror gallery_body_test: the globals some code paths still
      // read must see the test instance.
      settingModel = testSettingModel;
      testAssetModel = AssetModel();
      // One canned remote asset so _maybeLoad returns early and no
      // real server start is attempted; its path matches nothing in
      // the fake listings.
      testAssetModel.remoteAssets = [
        Asset(
          remote: RemoteImage(
            MockImgSyncerClient(),
            'other/x.jpg',
            httpClient: MockHttpClient(),
            thumbnailData: Uint8List(0),
          ),
        ),
      ];
      fakeDataSource = FakeFilesDataSource({
        '': [
          DirEntry(name: '2026', isDir: true, size: 0),
          DirEntry(name: 'a.jpg', isDir: false, size: 42),
        ],
        '2026': [
          DirEntry(name: '11', isDir: true, size: 0),
          DirEntry(name: 'b.jpg', isDir: false, size: 13),
        ],
        '2026/11': [
          DirEntry(name: 'c.jpg', isDir: false, size: 7),
        ],
      });
    });

    tearDown(() {
      settingModel = originalModel;
    });

    testWidgets('drill down, then back via breadcrumb and back arrow',
        (tester) async {
      await tester.pumpWidget(buildTestWidget());
      await tester.pump();
      await tester.pump();

      // Root: folder + file listed, no back arrow, root crumb visible.
      expect(find.text('2026'), findsOneWidget);
      expect(find.text('a.jpg'), findsOneWidget);
      expect(find.byIcon(Icons.arrow_back), findsNothing);
      expect(find.text('Files'), findsOneWidget);
      expect(fakeDataSource.listedDirs, ['']);

      // Drill into 2026: back arrow + breadcrumb appear, children listed.
      await tester.tap(find.text('2026'));
      await tester.pump();
      await tester.pump();
      expect(find.byIcon(Icons.arrow_back), findsOneWidget);
      expect(find.text('11'), findsOneWidget);
      expect(find.text('b.jpg'), findsOneWidget);
      expect(fakeDataSource.listedDirs, ['', '2026']);

      // Drill into 11.
      await tester.tap(find.text('11'));
      await tester.pump();
      await tester.pump();
      expect(find.text('c.jpg'), findsOneWidget);
      expect(fakeDataSource.listedDirs, ['', '2026', '2026/11']);

      // Back to root in one tap via the breadcrumb root crumb.
      await tester.tap(find.text('Files'));
      await tester.pump();
      await tester.pump();
      expect(find.text('2026'), findsOneWidget);
      expect(find.byIcon(Icons.arrow_back), findsNothing);
      expect(fakeDataSource.listedDirs, ['', '2026', '2026/11', '']);

      // Drill again, then back exactly one level via the back arrow.
      await tester.tap(find.text('2026'));
      await tester.pump();
      await tester.pump();
      expect(find.byIcon(Icons.arrow_back), findsOneWidget);
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pump();
      await tester.pump();
      expect(find.text('2026'), findsOneWidget);
      expect(find.byIcon(Icons.arrow_back), findsNothing);
    });

    testWidgets('breadcrumb segment jumps to that level', (tester) async {
      await tester.pumpWidget(buildTestWidget());
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('2026'));
      await tester.pump();
      await tester.pump();
      await tester.tap(find.text('11'));
      await tester.pump();
      await tester.pump();
      expect(find.text('c.jpg'), findsOneWidget);

      // Tap the '2026' breadcrumb segment: back to 2026, not root.
      await tester.tap(find.text('2026'));
      await tester.pump();
      await tester.pump();
      expect(find.text('11'), findsOneWidget);
      expect(find.text('b.jpg'), findsOneWidget);
      expect(find.byIcon(Icons.arrow_back), findsOneWidget);
      expect(fakeDataSource.listedDirs.last, '2026');
    });
  });
}
