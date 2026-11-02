import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 自定义上传筛选的配置（iOS 自用功能；Android 侧无入口，默认全部允许）。
///
/// 语义（与 shouldSyncAsset 里的历史 Pro 行为一致，见
/// test/widget/sync_body_test.dart 锁定的用例）：
/// - [enabled] 为 false 时全部通过（其余字段不起作用）。
/// - [noVideo]/[noImage] 为 true 时分别排除视频 / 图片。
/// - [after]：拍摄日期早于它（isBefore）的排除；[before]：拍摄日期晚于
///   它（isAfter）的排除。存储约定：[before] 存的是用户选中结束日的
///   次日 00:00（见 exclusiveBeforeBound），即含结束日全天的上界；
///   直接由代码写入 [before] 的调用方（如测试）须自行保证该约定。
/// - [extensionAllowed]：扩展名 -> 是否允许（key 形如 '.jpg'，小写）；
///   未出现在 map 里的扩展名默认允许；空 map = 全部允许。
/// - 判定顺序固定：先查已上传 ID（shouldSyncAsset 第一行），再跑本谓词，
///   顺序不可反，否则已上传集合与远端比对会漂移。
/// - 被筛选排除的照片：不上传、不计入待同步数、不删除；放宽条件后下一轮
///   自动重新进入待同步集合。
class UploadFilterConfig {
  bool enabled;
  bool noVideo;
  bool noImage;
  DateTime? after;
  DateTime? before;

  /// key: '.jpg' 形式的小写扩展名（含前导点）；value: 是否允许。
  Map<String, bool> extensionAllowed;

  UploadFilterConfig({
    this.enabled = false,
    this.noVideo = false,
    this.noImage = false,
    this.after,
    this.before,
    Map<String, bool>? extensionAllowed,
  }) : extensionAllowed = extensionAllowed ?? {};

  factory UploadFilterConfig.defaults() => UploadFilterConfig();

  factory UploadFilterConfig.fromJson(Map<String, dynamic> json) {
    DateTime? parseDate(Object? v) {
      if (v is String) return DateTime.tryParse(v);
      if (v is int) {
        return DateTime.fromMillisecondsSinceEpoch(v, isUtc: false);
      }
      return null;
    }

    final rawExt = json['extensions'];
    final extMap = <String, bool>{};
    if (rawExt is Map) {
      for (final e in rawExt.entries) {
        final key = normalizeExtension(e.key.toString());
        if (key.isEmpty) continue;
        if (e.value is bool) extMap[key] = e.value as bool;
      }
    }
    return UploadFilterConfig(
      enabled: json['enabled'] is bool ? json['enabled'] as bool : false,
      noVideo: json['noVideo'] is bool ? json['noVideo'] as bool : false,
      noImage: json['noImage'] is bool ? json['noImage'] as bool : false,
      after: parseDate(json['after']),
      before: parseDate(json['before']),
      extensionAllowed: extMap,
    );
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'noVideo': noVideo,
        'noImage': noImage,
        'after': after?.toIso8601String(),
        'before': before?.toIso8601String(),
        'extensions': extensionAllowed,
      };

  UploadFilterConfig copyWith({
    bool? enabled,
    bool? noVideo,
    bool? noImage,
    DateTime? after,
    bool clearAfter = false,
    DateTime? before,
    bool clearBefore = false,
    Map<String, bool>? extensionAllowed,
  }) {
    return UploadFilterConfig(
      enabled: enabled ?? this.enabled,
      noVideo: noVideo ?? this.noVideo,
      noImage: noImage ?? this.noImage,
      after: clearAfter ? null : (after ?? this.after),
      before: clearBefore ? null : (before ?? this.before),
      extensionAllowed:
          extensionAllowed ?? Map<String, bool>.of(this.extensionAllowed),
    );
  }

  /// 扩展名归一化：去空白、小写、补前导点。调用方传入的已是
  /// path.extension() 的结果（如 '.jpg'），此处不做任何后缀剥离
  ///（本地资产标题不可能以 '.aes' 结尾，那是远端加密文件名）。
  static String normalizeExtension(String ext) {
    var e = ext.trim().toLowerCase();
    if (e.isEmpty) return '';
    if (!e.startsWith('.')) e = '.$e';
    return e;
  }

  /// 把用户在日期选择器里选中的结束日（含）换算为内部存储的
  /// [before] 上界：次日 00:00。allows() 用 `isAfter(before)` 排除，
  /// 以次日 00:00 为上界时，结束日全天的照片都不晚于它，因而全部
  /// 保留；直接存结束日当天的 00:00 会把结束日全天排除（B2）。
  /// 换算用日历构造，自动处理跨月/跨年（如 12 月 31 日 +1 天）。
  static DateTime exclusiveBeforeBound(DateTime pickedEndDay) =>
      DateTime(pickedEndDay.year, pickedEndDay.month, pickedEndDay.day + 1);

  /// [exclusiveBeforeBound] 的逆运算：把内部存储的 [before] 上界
  /// 换算回用户选中的结束日（含），用于回显与日期选择器的初始值。
  static DateTime inclusiveEndDay(DateTime exclusiveBound) => DateTime(
        exclusiveBound.year,
        exclusiveBound.month,
        exclusiveBound.day - 1,
      );

  /// 纯谓词：不触碰任何平台通道，可直接单元测试。
  /// [extensionStr] 为调用方已算好的扩展名（如 '.jpg'，可能为空字符串，
  /// 空串表示无信息，等效于跳过扩展名检查）。
  bool allows({
    required bool isVideo,
    required DateTime date,
    required String extensionStr,
  }) {
    if (!enabled) return true;
    if (noVideo && isVideo) return false;
    if (noImage && !isVideo) return false;
    if (after != null && date.isBefore(after!)) return false;
    if (before != null && date.isAfter(before!)) return false;
    final ext = normalizeExtension(extensionStr);
    if (ext.isEmpty) return true;
    return extensionAllowed[ext] ?? true;
  }
}

/// SharedPreferences 持久化：单个 JSON 字符串，key 与历史 Pro 版本无关，
/// 自用 fork 首次运行即为空配置（全部允许）。
const String _uploadFilterPrefsKey = 'upload_filter_config';

Future<UploadFilterConfig> loadUploadFilterConfig() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString(_uploadFilterPrefsKey);
  if (raw == null || raw.isEmpty) return UploadFilterConfig.defaults();
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) {
      return UploadFilterConfig.fromJson(decoded);
    }
  } catch (_) {
    // 损坏的配置不阻塞启动，回退默认（全部允许）。
  }
  return UploadFilterConfig.defaults();
}

Future<void> saveUploadFilterConfig(UploadFilterConfig config) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_uploadFilterPrefsKey, jsonEncode(config.toJson()));
}
