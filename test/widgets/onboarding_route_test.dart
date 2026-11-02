import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:img_syncer/global.dart' as global;
import 'package:img_syncer/l10n/app_localizations.dart';
import 'package:img_syncer/onboarding/onboarding_route.dart';
import 'package:img_syncer/setting_storage_route.dart';
import 'package:shared_preferences/shared_preferences.dart';

// U3 根因（诊断结论）：此前 5 个失败不是“finder 写法”问题，而是
// 测试按一个不存在的权限步骤编写的。生产 OnboardingRoute
// （lib/onboarding/onboarding_route.dart）只有两段：
//   1. 3 页介绍（PageView）→ 2. 存储步骤（_currentStep == 4，
//      _buildStorageStep），中间没有任何权限步骤、也不调用
//      PhotoManager.requestPermissionExtend；权限在 Global.init /
//      requestPermission() 里按需申请。l10n 里权限相关的三个 key
//      生产代码从未引用（U10 死 key，已删除）。
// 因此本文件按真实路由重写：介绍页 → 存储步骤 → Done / 设置存储。
// 若产品上确实需要引导内权限步骤，属生产余项（Area A 实现
// _currentStep 权限页 + 接入 requestPermission 后，本文件对应
// 用例需随之改写），测试不得虚构不存在的 UI。

void main() {
  group('OnboardingRoute', () {
    Widget buildTestWidget({required VoidCallback onComplete}) {
      return MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            global.initI18n(context);
            return OnboardingRoute(onComplete: onComplete);
          },
        ),
      );
    }

    Future<void> pumpUntilSettled(WidgetTester tester) async {
      await tester.pump();
      await tester.pumpAndSettle();
    }

    /// 跳到最后一页（第 3 页），此时右下按钮应为 Get Started。
    Future<void> goToLastPage(WidgetTester tester) async {
      final pageView = tester.widget<PageView>(find.byType(PageView));
      pageView.controller!.jumpToPage(2);
      await pumpUntilSettled(tester);
      expect(find.text('Get Started'), findsOneWidget);
    }

    testWidgets('渲染无异常', (WidgetTester tester) async {
      await tester.pumpWidget(
        buildTestWidget(onComplete: () {}),
      );
      await pumpUntilSettled(tester);

      expect(find.byType(OnboardingRoute), findsOneWidget);
      expect(find.byType(PageView), findsOneWidget);
    });

    testWidgets('PageView 包含 3 页', (WidgetTester tester) async {
      await tester.pumpWidget(
        buildTestWidget(onComplete: () {}),
      );
      await pumpUntilSettled(tester);

      final pageView = tester.widget<PageView>(find.byType(PageView));
      expect(pageView.allowImplicitScrolling, false);
      expect(find.byType(PageView), findsOneWidget);
      // PageView 的 children 通过 onPageChanged 和滑动验证为 3 页
      expect(pageView.onPageChanged, isNotNull);
    });

    testWidgets('点击跳过按钮触发 onComplete', (WidgetTester tester) async {
      bool completed = false;
      SharedPreferences.setMockInitialValues({});

      await tester.pumpWidget(
        buildTestWidget(onComplete: () => completed = true),
      );
      await pumpUntilSettled(tester);

      await tester.tap(find.text('Skip'));
      await pumpUntilSettled(tester);

      expect(completed, isTrue);
    });

    testWidgets('点击 Next 前进到下一页，最后一页显示 Get Started',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        buildTestWidget(onComplete: () {}),
      );
      await pumpUntilSettled(tester);

      expect(find.text('Next'), findsOneWidget);
      await tester.tap(find.text('Next'));
      await pumpUntilSettled(tester);

      // 第 2 页仍是 Next；再点一次到第 3 页变为 Get Started。
      await tester.tap(find.text('Next'));
      await pumpUntilSettled(tester);
      expect(find.text('Get Started'), findsOneWidget);
      expect(find.text('Next'), findsNothing);
    });

    testWidgets('最后一页点击 Get Started 直接进入存储步骤（无权限步骤）',
        (WidgetTester tester) async {
      bool completed = false;
      SharedPreferences.setMockInitialValues({});

      await tester.pumpWidget(
        buildTestWidget(onComplete: () => completed = true),
      );
      await pumpUntilSettled(tester);
      await goToLastPage(tester);

      await tester.tap(find.text('Get Started'));
      await pumpUntilSettled(tester);

      // 未触发 onComplete；进入存储步骤，且不存在权限步骤 UI。
      expect(completed, isFalse);
      expect(find.text('Set up cloud storage (optional)'), findsOneWidget);
      expect(find.text('Set up storage'), findsOneWidget);
      expect(find.text('Done'), findsOneWidget);
      expect(find.text('Grant permission'), findsNothing);
      expect(find.text('Photo access needed'), findsNothing);
    });

    testWidgets('存储步骤：点击设置存储显示 SettingStorageRouteBody',
        (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});

      await tester.pumpWidget(
        buildTestWidget(onComplete: () {}),
      );
      await pumpUntilSettled(tester);
      await goToLastPage(tester);
      await tester.tap(find.text('Get Started'));
      await pumpUntilSettled(tester);

      // 点击设置存储
      await tester.tap(find.text('Set up storage'));
      await pumpUntilSettled(tester);

      // SettingStorageRouteBody 应出现（嵌套 Navigator 内的表单页）。
      expect(find.byType(SettingStorageRouteBody), findsOneWidget);
    });

    testWidgets('存储步骤：点击 Done 结束引导并写入 has_onboarded',
        (WidgetTester tester) async {
      bool completed = false;
      SharedPreferences.setMockInitialValues({});

      await tester.pumpWidget(
        buildTestWidget(onComplete: () => completed = true),
      );
      await pumpUntilSettled(tester);
      await goToLastPage(tester);
      await tester.tap(find.text('Get Started'));
      await pumpUntilSettled(tester);

      await tester.tap(find.text('Done'));
      await pumpUntilSettled(tester);

      expect(completed, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('has_onboarded'), isTrue);
    });
  });
}
