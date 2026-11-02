import 'dart:io';

import 'package:extended_image/extended_image.dart';
import 'package:flutter/material.dart';
import 'package:img_syncer/background_sync_route.dart';
import 'package:img_syncer/choose_album_route.dart';
import 'package:img_syncer/design_tokens.dart';
import 'package:img_syncer/filter_settings_route.dart';
import 'package:img_syncer/setting_storage_route.dart';
import 'package:img_syncer/global.dart';
import 'package:img_syncer/state_model.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 简化版设置页：选择相册、云存储、后台同步、清除缓存、关于。
/// 开源版本，无 Pro 功能门控、无购买入口。
class SettingsRoute extends StatefulWidget {
  const SettingsRoute({Key? key}) : super(key: key);

  @override
  SettingsRouteState createState() => SettingsRouteState();
}

class SettingsRouteState extends State<SettingsRoute> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.settings),
      ),
      body: ListView(
        children: [
          tile(
            Icons.folder_outlined,
            l10n.chooseAlbum,
            null,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => const ChooseAlbumRoute(),
              ),
            ),
          ),
          tile(
            Icons.cloud_outlined,
            l10n.cloudStorage,
            null,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => const SettingStorageRoute(),
              ),
            ),
          ),
          if (Platform.isIOS) ...[
            tile(
              Icons.file_upload_outlined,
              l10n.parallelUploadCount,
              '${settingModel.parallelUploadCount}',
              onTap: _showParallelCountDialog,
            ),
            tile(
              Icons.filter_alt_outlined,
              l10n.uploadFilter,
              settingModel.uploadFilter.enabled ? l10n.filterEnabled : null,
              onTap: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const FilterSettingsRoute(),
                  ),
                );
                if (mounted) setState(() {});
              },
            ),
            Container(
              padding: const EdgeInsets.all(AppSpacing.paddingSmall),
              child: SwitchListTile(
                secondary: Icon(
                  Icons.photo_camera_outlined,
                  size: 28,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                title: Text(l10n.onlyCamera,
                    style: Theme.of(context).textTheme.titleLarge),
                subtitle: Text(l10n.onlyCameraDesc,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        )),
                value: settingModel.onlyCameraAlbum,
                onChanged: (value) async {
                  // 顺序关键：先用“新值”刷新排除集合，再翻转开关。
                  // 翻转会立即通知相册重建；若先翻转后刷新，重建
                  // 时集合还是旧值（开启时为空），截图会短暂闪现。
                  await assetModel.refreshCameraExcludedIds(
                      onlyCameraAlbum: value);
                  settingModel.setOnlyCameraAlbum(value);
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setBool('only_camera_album', value);
                  // 只影响展示：AssetModel 通知后相册页按
                  // displayLocalAssets 重建；同步不受影响。
                  if (mounted) setState(() {});
                },
              ),
            ),
          ],
          if (Platform.isAndroid)
            tile(
              Icons.cloud_sync_outlined,
              l10n.backgroundSync,
              null,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const BackgroundSyncSettingRoute(),
                ),
              ),
            ),
          const Divider(),
          tile(
            Icons.cleaning_services,
            l10n.clearCache,
            null,
            onTap: () => showClearCacheDialog(context),
          ),
          tile(
            Icons.info,
            l10n.about,
            null,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => const AboutRoute(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget tile(IconData icon, String title, String? subtitle,
      {Function()? onTap}) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.paddingSmall),
      child: ListTile(
        leading: Icon(
          icon,
          size: 28,
          color: colorScheme.onSurfaceVariant,
        ),
        title: Text(title, style: textTheme.titleLarge),
        subtitle: subtitle != null
            ? Text(subtitle,
                style: textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ))
            : null,
        onTap: onTap,
      ),
    );
  }

  Future<void> _showParallelCountDialog() async {
    final current = settingModel.parallelUploadCount;
    final selected = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(l10n.parallelUploadCount),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
            child: Text(
              l10n.parallelUploadCountDesc,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          for (final count in [1, 2, 3, 4])
            RadioListTile<int>(
              title: Text('$count'),
              value: count,
              groupValue: current,
              onChanged: (value) => Navigator.pop(context, value),
            ),
        ],
      ),
    );
    if (selected == null) return;
    settingModel.setParallelUploadCount(selected);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('parallel_upload_count', selected);
    if (mounted) setState(() {});
  }

  void showClearCacheDialog(BuildContext context) {
    showDialog(
        context: context,
        builder: (context) {
          return Dialog(
            child: SizedBox(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.fromLTRB(30, 20, 20, 5),
                    child: Text(
                      l10n.clearCache,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.fromLTRB(30, 5, 20, 5),
                    child: Text(
                      l10n.clearCacheDescription,
                    ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Container(
                        padding: const EdgeInsets.fromLTRB(0, 0, 20, 5),
                        child: TextButton(
                          onPressed: () {
                            Navigator.of(context).pop();
                          },
                          child: Text(l10n.cancel),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.fromLTRB(0, 0, 20, 5),
                        child: TextButton(
                          onPressed: () {
                            clearDiskCachedImages();
                            PhotoManager.clearFileCache();
                            Navigator.of(context).pop();
                          },
                          child: Text(l10n.yes),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        });
  }
}

/// 简化版关于页：显示应用名。
/// 开源版无 package_info_plus 依赖，无隐藏日志入口；Dart 侧无法
/// 不引入新依赖读取 pubspec 版本，故此处不显示版本号——此前
/// 写死的 '1.0.0' 与 pubspec（1.5.1）不符，是错误信息，已去掉。
class AboutRoute extends StatelessWidget {
  const AboutRoute({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.about),
      ),
      body: ListView(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.paddingSmall,
                vertical: AppSpacing.xs),
            child: ListTile(
              title: Text(l10n.appVersion,
                  style: Theme.of(context).textTheme.titleLarge),
              subtitle: Text(
                'Pho',
                style: TextStyle(color: Theme.of(context).colorScheme.primary),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
