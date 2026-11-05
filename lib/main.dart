import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:img_syncer/desktop/home_page.dart';
import 'package:img_syncer/event_bus.dart';
import 'package:img_syncer/files_body.dart';
import 'package:img_syncer/global.dart';
import 'package:img_syncer/util.dart';
import 'package:provider/provider.dart';
import 'package:img_syncer/state_model.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'gallery_body.dart';
import 'sync_body.dart';
import 'package:adaptive_theme/adaptive_theme.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/services.dart';
import 'package:img_syncer/l10n/app_localizations.dart';
import 'package:img_syncer/theme.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:img_syncer/design_tokens.dart';
import 'package:img_syncer/onboarding/onboarding_route.dart';
// iOS 后台同步 headless entrypoint，必须被 main 的 import 图可达，
// 否则 Debug Dart kernel 不会编译此库，BGProcessingTask 启动 headless
// engine 时 Dart_LookupLibrary 找不到它。
// ignore: unused_import
import 'background_sync_entrypoint.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 清除 adaptive_theme 持久化的旧暗色模式，强制浅色
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove('adaptive_theme');
  Global.init().then((e) => runApp(
        MultiProvider(
          providers: [
            ChangeNotifierProvider(create: (context) => settingModel),
            ChangeNotifierProvider(create: (context) => assetModel),
            ChangeNotifierProvider(create: (context) => stateModel),
          ],
          child: const MyApp(),
        ),
      ));
}

class _AppEntryPoint extends StatefulWidget {
  const _AppEntryPoint();
  @override
  State<_AppEntryPoint> createState() => _AppEntryPointState();
}

class _AppEntryPointState extends State<_AppEntryPoint> {
  bool? _needsOnboarding;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((prefs) {
      if (!mounted) return;
      setState(() {
        _needsOnboarding = !(prefs.getBool('has_onboarded') ?? false);
      });
    });
  }

  void _finishOnboarding() {
    if (!mounted) return;
    setState(() {
      _needsOnboarding = false;
    });
    // 引导页可能遮住了系统权限弹窗，导致首次照片加载失败。
    // 退出引导页后重新触发加载。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      eventBus.fire(LocalRefreshEvent(refreshUnSync: true));
    });
  }

  @override
  Widget build(BuildContext context) {
    initI18n(context);
    if (_needsOnboarding == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_needsOnboarding!) {
      return OnboardingRoute(onComplete: _finishOnboarding);
    }
    return const MyHomePage(title: 'PHO');
  }
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);
  static const String _title = 'PHO';
  // This widget is the root of your application.

  @override
  Widget build(BuildContext context) {
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent, // 设置状态栏颜色为透明
      systemNavigationBarColor: Colors.transparent, // 设置导航栏颜色为透明
      systemNavigationBarDividerColor: Colors.transparent, // 设置导航栏分隔线颜色为透明
    ));
    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) {
        late ColorScheme lightColorScheme;
        late ColorScheme darkColorScheme;
        if (lightDynamic != null) {
          lightColorScheme = lightDynamic.harmonized();
        } else {
          print("lightDynamic is null");
          lightColorScheme = ColorScheme.fromSeed(
            seedColor: seedColor ?? seedThemeColors[0],
            brightness: Brightness.light,
          );
        }
        if (darkDynamic != null) {
          darkColorScheme = darkDynamic.harmonized();
        } else {
          print("darkDynamic is null");
          darkColorScheme = ColorScheme.fromSeed(
            seedColor: seedColor ?? seedThemeColors[0],
            brightness: Brightness.dark,
          );
        }

        var lightTheme = buildThemeData(
          colorScheme: lightColorScheme,
          brightness: Brightness.light,
        );
        var darkTheme = buildThemeData(
          colorScheme: darkColorScheme,
          brightness: Brightness.dark,
        );
        return AdaptiveTheme(
            light: lightTheme,
            dark: darkTheme,
            initial: AdaptiveThemeMode.light,
            builder: (theme, darkTheme) {
              return MaterialApp(
                title: _title,
                debugShowCheckedModeBanner: false,
                home: const _AppEntryPoint(),
                theme: theme,
                darkTheme: darkTheme,
                themeMode: ThemeMode.light,
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
              );
            });
      },
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({Key? key, required this.title}) : super(key: key);
  final String title;
  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> with WidgetsBindingObserver {
  int _selectedIndex = 0;

  /// Connectivity subscription: previously created and never
  /// cancelled, leaking one listener per home-page mount.
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;

  @override
  void initState() {
    super.initState();
    // didChangeAppLifecycleState is dead code unless the observer
    // is registered: without this, background/foreground transitions
    // never set needStopSync or re-probe the server.
    WidgetsBinding.instance.addObserver(this);
    SnackBarManager.init(context);
    // W7-T1: 恢复警告 - 检测空syncedIDs但有历史刷新记录的情况
    SharedPreferences.getInstance().then((prefs) {
      final syncedIds = prefs.getString('synced_ids');
      final lastRefresh = prefs.getInt('last_refersh_unsync');
      if (syncedIds != null &&
          syncedIds == '[]' &&
          lastRefresh != null &&
          lastRefresh != 0) {
        SnackBarManager.showSnackBar("之前同步状态丢失，建议连接 WiFi 后保持应用前台以重新校验同步状态");
      }
    });
    SharedPreferences.getInstance().then((prefs) async {
      if (!mounted) return;
      final seedColorValue = prefs.getInt("seed_color");
      if (seedColorValue != null) {
        seedColor = Color(seedColorValue);
        AdaptiveTheme.of(context).setTheme(
          light: buildThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: seedColor!,
              brightness: Brightness.light,
            ),
            brightness: Brightness.light,
          ),
        );
      }
    });
    if (!isDesktop()) {
      Connectivity().checkConnectivity().then((results) {
        if (!mounted) return;
        stateModel.setOnline(!results.contains(ConnectivityResult.none));
      });
      _connectivitySubscription =
          Connectivity().onConnectivityChanged.listen((results) {
        stateModel.setOnline(!results.contains(ConnectivityResult.none));
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _connectivitySubscription?.cancel();
    _connectivitySubscription = null;
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      stateModel.needStopSync = true;
    } else if (state == AppLifecycleState.resumed) {
      // 息屏/切后台后回到前台：连接可能已被系统冻结失效。
      // 重置中断标志，强制探测 Go server（绕过 60s 去抖），并触发 cloud 刷新。
      stateModel.needStopSync = false;
      lastAliveTime = null;
      checkServer().then((_) {
        if (settingModel.isRemoteStorageSetted) {
          eventBus.fire(RemoteRefreshEvent(refreshUnSync: false));
        }
      });
    }
  }

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    initI18n(context);
    initRequestPermission(context);
    PreferredSizeWidget? appBar;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return !isDesktop()
        ? Consumer<StateModel>(
            builder: (context, model, child) => Scaffold(
              appBar: appBar,
              backgroundColor: colorScheme.surface,
              body: Column(
                children: [
                  if (!model.isOnline)
                    Container(
                      width: double.infinity,
                      color: colorScheme.errorContainer,
                      padding:
                          const EdgeInsets.symmetric(vertical: AppSpacing.xs),
                      child: Text(
                        l10n.offline,
                        textAlign: TextAlign.center,
                        style: textTheme.labelSmall
                            ?.copyWith(color: colorScheme.onErrorContainer),
                      ),
                    ),
                  Expanded(
                    child: IndexedStack(
                      index: _selectedIndex,
                      children: [
                        GalleryBody(
                          useLocal: true,
                        ),
                        GalleryBody(useLocal: false),
                        const FilesBody(),
                        Consumer<SettingModel>(
                          builder: (context, model, child) {
                            return SyncBody(
                              localFolder: model.localFolder,
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              bottomNavigationBar: model.isSelectionMode
                  ? null
                  : NavigationBar(
                      onDestinationSelected: _onItemTapped,
                      selectedIndex: _selectedIndex,
                      destinations: <Widget>[
                        NavigationDestination(
                          icon: const Icon(Icons.phone_android_outlined),
                          selectedIcon: const Icon(Icons.phone_android),
                          label: l10n.local,
                        ),
                        NavigationDestination(
                          icon: const Icon(Icons.cloud_outlined),
                          selectedIcon: const Icon(Icons.cloud),
                          label: l10n.cloud,
                        ),
                        NavigationDestination(
                          icon: const Icon(Icons.folder_outlined),
                          selectedIcon: const Icon(Icons.folder),
                          label: l10n.files,
                        ),
                        NavigationDestination(
                          icon: const Icon(Icons.cloud_sync_outlined),
                          selectedIcon: const Icon(Icons.cloud_sync),
                          label: l10n.sync,
                        ),
                      ],
                    ),
            ),
          )
        : const DesktopHomePage();
  }
}

ThemeData buildThemeData({
  required ColorScheme colorScheme,
  required Brightness brightness,
}) {
  return ThemeData(
    colorScheme: colorScheme,
    useMaterial3: true,
    textTheme: textTheme,
    navigationBarTheme: brightness == Brightness.light
        ? buildNavigationBarThemeLight(colorScheme)
        : buildNavigationBarThemeDark(colorScheme),
    iconTheme: brightness == Brightness.light ? iconThemeLight : iconThemeDark,
    floatingActionButtonTheme: brightness == Brightness.light
        ? floatingActionButtonThemeLight
        : const FloatingActionButtonThemeData(),
    appBarTheme: buildAppBarTheme(colorScheme),
    cardTheme: buildCardTheme(colorScheme),
    listTileTheme: buildListTileTheme(colorScheme),
    chipTheme: buildChipTheme(colorScheme),
    dialogTheme: buildDialogTheme(colorScheme),
    snackBarTheme: buildSnackBarTheme(colorScheme),
    dividerTheme: buildDividerTheme(colorScheme),
    switchTheme: buildSwitchTheme(colorScheme),
    inputDecorationTheme: buildInputDecorationTheme(colorScheme),
    navigationRailTheme: buildNavigationRailTheme(colorScheme),
    bottomSheetTheme: buildBottomSheetTheme(colorScheme),
    progressIndicatorTheme: buildProgressIndicatorTheme(colorScheme),
    sliderTheme: buildSliderTheme(colorScheme),
    filledButtonTheme: buildFilledButtonTheme(colorScheme),
    textButtonTheme: buildTextButtonTheme(colorScheme),
    outlinedButtonTheme: buildOutlinedButtonTheme(colorScheme),
    segmentedButtonTheme: buildSegmentedButtonTheme(colorScheme),
    dropdownMenuTheme: buildDropdownMenuTheme(colorScheme),
    popupMenuTheme: buildPopupMenuTheme(colorScheme),
    tooltipTheme: buildTooltipTheme(colorScheme),
    badgeTheme: buildBadgeTheme(colorScheme),
  );
}
