import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:img_syncer/main.dart';
import 'package:img_syncer/theme.dart';

void main() {
  // ── 共享 ColorScheme ──────────────────────────────────────────
  final lightScheme = ColorScheme.fromSeed(
    seedColor: seedThemeColors[0],
    brightness: Brightness.light,
  );
  final darkScheme = ColorScheme.fromSeed(
    seedColor: seedThemeColors[0],
    brightness: Brightness.dark,
  );

  // ═══════════════════════════════════════════════════════════════
  // Part 1：17 个组件主题非 null 断言
  // ═══════════════════════════════════════════════════════════════
  group('组件主题断言', () {
    late ThemeData lightTheme;
    late ThemeData darkTheme;

    setUp(() {
      lightTheme = buildThemeData(
        colorScheme: lightScheme,
        brightness: Brightness.light,
      );
      darkTheme = buildThemeData(
        colorScheme: darkScheme,
        brightness: Brightness.dark,
      );
    });

    for (final entry in _themeGetters.entries) {
      test('${entry.key} — light 非 null', () {
        expect(entry.value(lightTheme), isNotNull);
      });
      test('${entry.key} — dark 非 null', () {
        expect(entry.value(darkTheme), isNotNull);
      });
    }
  });

  // ═══════════════════════════════════════════════════════════════
  // Part 2：useMaterial3 断言
  // ═══════════════════════════════════════════════════════════════
  group('useMaterial3 断言', () {
    test('light', () {
      final t = buildThemeData(colorScheme: lightScheme, brightness: Brightness.light);
      expect(t.useMaterial3, isTrue);
    });
    test('dark', () {
      final t = buildThemeData(colorScheme: darkScheme, brightness: Brightness.dark);
      expect(t.useMaterial3, isTrue);
    });
  });

  // ═══════════════════════════════════════════════════════════════
  // Part 3：硬编码颜色回归门禁（CI 可跑）
  // ═══════════════════════════════════════════════════════════════
  group('硬编码颜色回归门禁', () {
    test('lib/ 下不存在未授权的 Colors.xxx 硬编码', () {
      // 白名单：已知使用，已审核通过。白名单按文件豁免，新增条目须在
      // 此处写明理由；overlay 类白色（照片上的图标/文字）不属于
      // “主题色硬编码”，改用 onSurface 反而在深色照片上不可读。
      const whitelist = {
        'design_tokens.dart',       // 品牌色定义（Color.fromARGB，不触发正则）
        'theme.dart',               // seedThemeColors（Color(0xFF...)，不触发正则）
        'main.dart',                // Colors.transparent(L86-88) + Colors.orange/white(L241,246)
        'gallery_body.dart',        // 仅 3 处 Colors.white，均为照片上的 overlay：
                                    // 同步徽标、视频时长文字、播放图标，须恒为白
                                    // 色以保证在任意照片上可读（U4 判定：生产侧正确，
                                    // 不改主题 token）
        'gallery_viewer_route.dart', // Colors.black(L441)+white(L446,L673)
        'video_route.dart',         // Colors.black(L97)+white(L74,L116)
        'buy_route.dart',           // Colors.white(L91)
        'files_body.dart',          // 仅 1 处 Colors.white：缩略图上的视频播放图标，
                                    // 须恒为白色以保证在任意照片上可读（同 gallery_body
                                    // 的 overlay 豁免理由）
      };

      final pattern = RegExp(r'Colors\.(black|white|grey|orange|green|red|blue)\b');
      final violations = <String>[];

      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final name = entity.uri.pathSegments.last;
        final lines = entity.readAsStringSync().split('\n');

        for (var i = 0; i < lines.length; i++) {
          if (pattern.hasMatch(lines[i]) && !whitelist.contains(name)) {
            violations.add('  $name:${i + 1}: ${lines[i].trim()}');
          }
        }
      }

      if (violations.isNotEmpty) {
        fail('发现未授权的硬编码颜色 Colors.xxx:\n${violations.join('\n')}');
      }
    });
  });

  // ═══════════════════════════════════════════════════════════════
  // Part 4：Golden 测试
  //
  // U4 判定：基线 golden 失败的根因是 golden 陈旧，不是生产颜色错。
  // 逐像素比对证实：Card 中心色 golden 为 surface (245,251,246)，
  // 当前渲染为 surfaceContainerLow (239,245,241)，与 theme.dart
  // buildCardTheme 显式指定的 token 一致；AppBar/背景/按钮主色
  // 完全一致，剩余差异仅为文字抗锯齿。golden 已按当前生产主题
  // 在本 Linux VM 上重生成（`flutter test --update-goldens`）。
  // 平台注意：golden 含 Linux 字体光栅化结果，在 macOS 上跑
  // 可能因字体回退不同而出现像素差；macOS CI 首次跑通前须在
  // macOS 上重生成并核对（未验证，见报告）。
  // ═══════════════════════════════════════════════════════════════
  group('Golden 测试', () {
    Widget buildPage(ThemeData theme) {
      return MaterialApp(
        theme: theme,
        home: Scaffold(
          appBar: AppBar(title: const Text('主题预览')),
          body: Column(
            children: [
              Card(
                child: ListTile(
                  leading: const Icon(Icons.photo),
                  title: const Text('示例照片'),
                  subtitle: const Text('描述文字'),
                ),
              ),
              const Divider(),
              Padding(
                padding: const EdgeInsets.all(16),
                child: FilledButton(onPressed: () {}, child: const Text('按钮')),
              ),
            ],
          ),
          bottomNavigationBar: NavigationBar(
            destinations: const [
              NavigationDestination(icon: Icon(Icons.home), label: '首页'),
              NavigationDestination(icon: Icon(Icons.cloud), label: '云端'),
            ],
          ),
        ),
      );
    }

    testWidgets('light 主题页面 — Golden', (tester) async {
      final theme = buildThemeData(
        colorScheme: lightScheme,
        brightness: Brightness.light,
      );
      await tester.pumpWidget(buildPage(theme));
      await tester.pumpAndSettle();

      // 无异常（overflow 等）
      expect(tester.takeException(), isNull);
      expect(find.byType(Card), findsOneWidget);
      expect(find.byType(FilledButton), findsOneWidget);
      expect(find.byType(NavigationBar), findsOneWidget);

      // 像素 golden 仅 Linux：页面含中文文本，macOS 字体回退不同，
      // 同一 golden 在 macOS 上像素差过大（见 Part 4 头注）。
      // 非 Linux 平台只做结构断言，不做像素比对。
      if (!Platform.isLinux) return;

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/theme_light.png'),
      );
    });

    testWidgets('dark 主题页面 — Golden', (tester) async {
      final theme = buildThemeData(
        colorScheme: darkScheme,
        brightness: Brightness.dark,
      );
      await tester.pumpWidget(buildPage(theme));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(Card), findsOneWidget);
      expect(find.byType(FilledButton), findsOneWidget);
      expect(find.byType(NavigationBar), findsOneWidget);

      // 像素 golden 仅 Linux（理由同 light 用例）。
      if (!Platform.isLinux) return;

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/theme_dark.png'),
      );
    });
  });
}

// ── 辅助：组件主题 Getter 映射 ────────────────────────────────────────
final _themeGetters = <String, Object? Function(ThemeData)>{
  'appBarTheme': (t) => t.appBarTheme,
  'cardTheme': (t) => t.cardTheme,
  'listTileTheme': (t) => t.listTileTheme,
  'chipTheme': (t) => t.chipTheme,
  'dialogTheme': (t) => t.dialogTheme,
  'snackBarTheme': (t) => t.snackBarTheme,
  'dividerTheme': (t) => t.dividerTheme,
  'switchTheme': (t) => t.switchTheme,
  'inputDecorationTheme': (t) => t.inputDecorationTheme,
  'navigationRailTheme': (t) => t.navigationRailTheme,
  'bottomSheetTheme': (t) => t.bottomSheetTheme,
  'progressIndicatorTheme': (t) => t.progressIndicatorTheme,
  'sliderTheme': (t) => t.sliderTheme,
  'dropdownMenuTheme': (t) => t.dropdownMenuTheme,
  'popupMenuTheme': (t) => t.popupMenuTheme,
  'tooltipTheme': (t) => t.tooltipTheme,
  'badgeTheme': (t) => t.badgeTheme,
};
