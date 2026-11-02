import 'package:flutter/material.dart';
import 'package:img_syncer/event_bus.dart';
import 'package:img_syncer/l10n/app_localizations.dart';
import 'package:img_syncer/state_model.dart';
import 'package:img_syncer/sync/upload_filter.dart';

/// 自定义上传筛选设置页（iOS 自用功能；Android 侧无入口）。
///
/// 写入模式与 ChooseAlbumRoute 一致：页面内改内存态，点保存时一次性
/// 写回 SettingModel + SharedPreferences，并 fire LocalRefreshEvent
/// (refreshUnSync: true) 让同步页计数立即按新筛选刷新。
///
/// 组合语义（页内文案亦说明）：被排除的照片不上传、不计入待同步数、
/// 不删除；放宽条件后下一轮自动重新进入待同步集合。
///
/// 日期选择器的初始范围：[before] 内部存的是结束日次日 00:00
/// （上界），初始值须换算回用户选中的结束日（含），否则初始
/// 结束日会多显示一天。不一致的已存配置（开始日晚于结束日）
/// 不再把初始范围压成单日——那样确认后会静默用结束日覆盖
/// [after]；改为展示覆盖两日的跨度，确认不改动时两个日期都
/// 保留，范围随之恢复一致。
DateTimeRange initialFilterDateRange(
    DateTime? after, DateTime? before, DateTime now) {
  final initialStart = after ?? DateTime(now.year - 1, now.month, now.day);
  final initialEnd = before != null
      ? UploadFilterConfig.inclusiveEndDay(before)
      : DateTime(now.year, now.month, now.day);
  final startDay =
      DateTime(initialStart.year, initialStart.month, initialStart.day);
  final endDay = DateTime(initialEnd.year, initialEnd.month, initialEnd.day);
  return DateTimeRange(
    start: startDay.isAfter(endDay) ? endDay : startDay,
    end: startDay.isAfter(endDay) ? startDay : endDay,
  );
}

class FilterSettingsRoute extends StatefulWidget {
  const FilterSettingsRoute({super.key});

  @override
  State<FilterSettingsRoute> createState() => _FilterSettingsRouteState();
}

class _FilterSettingsRouteState extends State<FilterSettingsRoute> {
  late bool _enabled;
  late bool _noVideo;
  late bool _noImage;
  DateTime? _after;
  DateTime? _before;
  late final TextEditingController _extensionsController;

  /// In-flight guard: double-tapping Save previously ran _save twice,
  /// writing (and popping) twice.
  bool _saving = false;

  /// The user-selected end day (inclusive) behind the stored
  /// exclusive bound, or null when no end is set.
  DateTime? get _endDay => _before == null
      ? null
      : UploadFilterConfig.inclusiveEndDay(_before!);

  /// Start day after end day (only meaningful while the filter is
  /// enabled). Such a config can only arrive from an older saved
  /// config: the date picker itself never produces one.
  bool get _hasDateInversion {
    if (!_enabled || _after == null || _endDay == null) return false;
    final startDay = DateTime(_after!.year, _after!.month, _after!.day);
    return startDay.isAfter(_endDay!);
  }

  /// Both exclusion switches on (only meaningful while enabled):
  /// excludes every asset, so nothing would ever upload (FK-3).
  bool get _excludesEverything => _enabled && _noVideo && _noImage;

  bool get _canSave => !_saving && !_hasDateInversion && !_excludesEverything;

  @override
  void initState() {
    super.initState();
    final config = settingModel.uploadFilter;
    _enabled = config.enabled;
    _noVideo = config.noVideo;
    _noImage = config.noImage;
    _after = config.after;
    _before = config.before;
    // 被排除的扩展名（extensionAllowed 值为 false 的条目）回填为逗号
    // 分隔文本（key 含前导点，显示时去掉）。未列出的扩展名默认允许，
    // 因此回填时只取 false 条目；true 条目不显示（B1：保存时只写
    // false，往返不丢失）。
    final excluded = config.extensionAllowed.entries
        .where((e) => !e.value)
        .map((e) => e.key.startsWith('.') ? e.key.substring(1) : e.key)
        .toList();
    _extensionsController = TextEditingController(text: excluded.join(', '));
  }

  @override
  void dispose() {
    _extensionsController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    // Inconsistent configs are never saved: the Save button is
    // disabled for them, and this re-check covers any path that
    // reaches _save anyway.
    if (!_canSave) return;
    setState(() {
      _saving = true;
    });
    try {
      // 文本框里列出的是要排除的扩展名（deny-list）：全部写 false；
      // 未列出的扩展名在 allows() 里默认允许（B1）。
      final extensions = <String, bool>{};
      for (final part in _extensionsController.text.split(',')) {
        final ext = UploadFilterConfig.normalizeExtension(part);
        if (ext.isNotEmpty) extensions[ext] = false;
      }
      final config = UploadFilterConfig(
        enabled: _enabled,
        noVideo: _noVideo,
        noImage: _noImage,
        after: _after,
        before: _before,
        extensionAllowed: extensions,
      );
      settingModel.setUploadFilter(config);
      await saveUploadFilterConfig(config);
      if (mounted) {
        eventBus.fire(LocalRefreshEvent(refreshUnSync: true));
        Navigator.pop(context);
      }
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
        });
      }
    }
  }

  Future<void> _pickDateRange() async {
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(1990, 1, 1),
      lastDate: DateTime(2100, 12, 31),
      initialDateRange:
          initialFilterDateRange(_after, _before, DateTime.now()),
    );
    if (range == null) return;
    setState(() {
      _after = range.start;
      // 结束日按次日 00:00 存（B2）：allows() 用 isAfter(before)
      // 排除，次日 00:00 作上界时结束日全天保留；直接存结束日
      // 00:00 会把结束日全天的照片排除。回显时换算回选中日。
      _before = UploadFilterConfig.exclusiveBeforeBound(range.end);
    });
  }

  String _dateRangeText(AppLocalizations l10n) {
    if (_after == null && _before == null) return l10n.filterDateNotSet;
    String fmt(DateTime? d) => d == null
        ? '…'
        : '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    // _before 存的是上界（次日 00:00），显示时换算回用户选中的
    // 结束日，否则会多显示一天。
    final endDay =
        _before == null ? null : UploadFilterConfig.inclusiveEndDay(_before!);
    return '${fmt(_after)} ~ ${fmt(endDay)}';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.uploadFilter),
        actions: [
          TextButton(
            onPressed: _canSave ? _save : null,
            child: Text(l10n.save),
          ),
        ],
      ),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              l10n.uploadFilterDesc,
              style: theme.textTheme.bodyMedium,
            ),
          ),
          SwitchListTile(
            title: Text(l10n.filterEnabled),
            value: _enabled,
            onChanged: (value) => setState(() => _enabled = value),
          ),
          SwitchListTile(
            title: Text(l10n.filterExcludeVideos),
            value: _noVideo,
            onChanged: _enabled
                ? (value) => setState(() => _noVideo = value)
                : null,
          ),
          SwitchListTile(
            title: Text(l10n.filterExcludeImages),
            value: _noImage,
            onChanged: _enabled
                ? (value) => setState(() => _noImage = value)
                : null,
          ),
          ListTile(
            title: Text(l10n.filterDateRange),
            subtitle: Text(_dateRangeText(l10n)),
            trailing: const Icon(Icons.date_range_outlined),
            enabled: _enabled,
            onTap: _enabled ? _pickDateRange : null,
          ),
          // 不一致的配置直接在页内警告并禁用保存（FK-9/FK-3），
          // 而不是静默存入一个“什么都不上传”或空范围的筛选。
          if (_hasDateInversion)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                l10n.filterDateRangeInvalid,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          if (_excludesEverything)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                l10n.filterExcludesAll,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          if (_enabled && (_after != null || _before != null))
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => setState(() {
                  _after = null;
                  _before = null;
                }),
                child: Text(l10n.filterClearDates),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TextField(
              controller: _extensionsController,
              enabled: _enabled,
              decoration: InputDecoration(
                labelText: l10n.filterExtensions,
                hintText: l10n.filterExtensionsHint,
                helperText: l10n.filterExtensionsDesc,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
