import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:img_syncer/asset.dart';
import 'package:img_syncer/state_model.dart';
import 'package:img_syncer/gallery_viewer_route.dart';
import 'package:img_syncer/l10n/app_localizations.dart';
import 'package:img_syncer/global.dart' as global;
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

// U6：原先本文件用一个手写 _ListenerTestWidget 替身验证“挂载注册
// 监听、卸载移除”，从未实例化 GalleryViewerRoute。以下直接驱动
// 真实 GalleryViewerRoute：Provider 注入 CountingAssetModel，
// 本地资产走 displayLocalAssets；photo_manager 通道 mock 返回
// 临时文件路径与 1x1 PNG 缩略图字节，使 ExtendedImage 加载与
// readInfoFromData 不触真实平台通道。

/// 可计数的 AssetModel，追踪 addListener / removeListener 调用次数
class CountingAssetModel extends AssetModel {
  int addCount = 0;
  int removeCount = 0;

  @override
  void addListener(VoidCallback listener) {
    addCount++;
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    removeCount++;
    super.removeListener(listener);
  }
}

final _tinyPng = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8Xw8AAwMCAO+ip1sAAAAASUVORK5CYII=');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late File tempImageFile;
  late CountingAssetModel model;
  late AssetModel originalGlobalModel;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    originalGlobalModel = assetModel;
    final dir = await Directory.systemTemp.createTemp('pho_gallery_viewer');
    tempImageFile = File('${dir.path}/pic.jpg');
    await tempImageFile.writeAsBytes(_tinyPng);

    const channel = MethodChannel('com.fluttercandies/photo_manager');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      if (call.method == 'getFullFile') return tempImageFile.path;
      if (call.method == 'getThumb') return _tinyPng;
      return null;
    });

    model = CountingAssetModel();
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final entity = AssetEntity(
      id: 'g1',
      typeInt: 1,
      width: 100,
      height: 100,
      createDateSecond: nowSec,
      modifiedDateSecond: nowSec,
      title: 'g1.jpg',
    );
    model.localAssets = [Asset(local: entity)];
  });

  tearDown(() {
    const channel = MethodChannel('com.fluttercandies/photo_manager');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    assetModel = originalGlobalModel;
  });

  Widget buildTestWidget() {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AssetModel>.value(value: model),
        ChangeNotifierProvider(create: (_) => SettingModel()),
        ChangeNotifierProvider(create: (_) => StateModel()),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            global.initI18n(context);
            return const GalleryViewerRoute(useLocal: true, originIndex: 0);
          },
        ),
      ),
    );
  }

  group('GalleryViewerRoute listener 生命周期（真实路由）', () {
    testWidgets('TestListenerCleanupOnDispose - 挂载注册监听，卸载时移除',
        (tester) async {
      await tester.pumpWidget(buildTestWidget());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.byType(GalleryViewerRoute), findsOneWidget);
      // Provider 框架也会 addListener，所以 >=1（不确定精确值）
      expect(model.addCount, greaterThanOrEqualTo(1));
      expect(model.removeCount, 0);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();

      // 卸载后 removeCount == addCount（无泄漏）
      expect(model.addCount, greaterThan(0));
      expect(model.addCount, model.removeCount);
    });

    testWidgets('TestMultipleMountUnmount - 多次挂载/卸载不累积泄漏',
        (tester) async {
      for (int i = 0; i < 3; i++) {
        final fresh = CountingAssetModel();
        final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        fresh.localAssets = [
          Asset(
              local: AssetEntity(
            id: 'g1',
            typeInt: 1,
            width: 100,
            height: 100,
            createDateSecond: nowSec,
            modifiedDateSecond: nowSec,
            title: 'g1.jpg',
          ))
        ];
        // 本轮改用 fresh 模型：重建 Provider 树。
        await tester.pumpWidget(MultiProvider(
          providers: [
            ChangeNotifierProvider<AssetModel>.value(value: fresh),
            ChangeNotifierProvider(create: (_) => SettingModel()),
            ChangeNotifierProvider(create: (_) => StateModel()),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Builder(
              builder: (context) {
                global.initI18n(context);
                return const GalleryViewerRoute(
                    useLocal: true, originIndex: 0);
              },
            ),
          ),
        ));
        await tester.pump();
        final afterMount = fresh.addCount;
        expect(afterMount, greaterThanOrEqualTo(1));
        expect(fresh.removeCount, 0);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        expect(fresh.addCount, afterMount);
        expect(fresh.removeCount, afterMount);
        // initState 里有 Future.delayed(400ms)（mounted 守卫）：
        // 必须让它在测试结束前走完，否则 binding 报 pending timer。
        await tester.pump(const Duration(milliseconds: 500));
      }
    });

    testWidgets('TestProviderInjection - GalleryViewerRoute 使用 Provider 而非全局变量',
        (tester) async {
      // 全局 assetModel 与 Provider 注入的是两个不同实例：若路由
      // 读全局变量，CountingAssetModel 的计数将保持 0。
      expect(identical(assetModel, model), isFalse);

      await tester.pumpWidget(buildTestWidget());
      await tester.pump();
      expect(model.addCount, greaterThanOrEqualTo(1));

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(model.addCount, model.removeCount);
      // 同上：放行 initState 的 400ms delayed future。
      await tester.pump(const Duration(milliseconds: 500));
    });
  });
}
