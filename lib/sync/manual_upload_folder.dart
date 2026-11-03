import 'package:shared_preferences/shared_preferences.dart';

/// 手动上传目录（分目录功能，仅 iOS）。
///
/// 自动同步始终写驱动根目录 + 日期子目录；手动上传写固定的手动
/// 目录（设置里定一次），其下按类型分子目录（video/image），不按
/// 日期分子目录（服务端 genPath，见 server/imgmanager）。本文件只
/// 管客户端的目录值语义：持久化 key、默认值、归一化/校验，与
/// 服务端 SanitizeDestDir 的规则保持一致（见 server/imgmanager
/// destdir_test.go 与本文件的测试，两边用例须同步改动）。

/// SharedPreferences key：存原始输入（可能为空串 = 未设置）。
const String manualUploadFolderPrefsKey = 'manual_upload_folder';

/// 未设置时的默认手动目录（相对于驱动根目录）。
const String defaultManualUploadFolder = 'manual';

/// 归一化一个手动目录值：去首尾空白，`/` 分隔，返回规范形式；
/// 空值或非法值返回 null（调用方按“未设置”处理：空值用默认
/// `manual`，设置页对“非空但非法”另行报错）。
///
/// 拒绝（与服务端一致）：反斜杠、绝对路径（以 `/` 开头）、`..` /
/// `.` 元素、空段（`//`、首尾斜杠）、首段为 `live` /
/// `.thumbnail`、首段为日期目录形状（4 位或 8 位纯数字，会与
/// 服务端的日期目录遍历重复访问）。
String? normalizeManualUploadFolder(String? raw) {
  if (raw == null) return null;
  final value = raw.trim();
  if (value.isEmpty) return null;
  if (value.contains('\\')) return null;
  if (value.startsWith('/')) return null;
  final parts = value.split('/');
  for (final part in parts) {
    if (part.isEmpty || part == '.' || part == '..') return null;
  }
  final first = parts.first;
  if (first == 'live' || first == '.thumbnail') return null;
  if (_isDateDirShape(first)) return null;
  return parts.join('/');
}

bool _isDateDirShape(String name) {
  if (name.length != 4 && name.length != 8) return false;
  for (var i = 0; i < name.length; i++) {
    final c = name.codeUnitAt(i);
    if (c < 0x30 || c > 0x39) return false;
  }
  return true;
}

/// 把“驱动内完整浏览路径”换算为相对于驱动根目录的手动目录值：
/// [rootPath] 与 [fullPath] 均为各 drive 目录浏览接口的拼写
/// （SMB：相对共享、无前导斜杠；WebDAV/NFS：以 `/` 开头、末尾
/// 带 `/`）。两者都按 `/` 切段比较：full 以 root 的段为前缀时取
/// 剩余段，否则取 full 自身的段（root 为空/根时）。返回 "" 表示
/// 选中的就是根目录本身（调用方按未设置处理，用默认 `manual`）。
/// 换算结果再经 normalizeManualUploadFolder 校验，非法返回 null。
String? manualFolderRelativeToRoot(String? rootPath, String fullPath) {
  List<String> segments(String? p) {
    if (p == null) return [];
    return p.split('/').where((s) => s.isNotEmpty && s != '.').toList();
  }

  final rootSegs = segments(rootPath);
  final fullSegs = segments(fullPath);
  List<String> rel;
  if (rootSegs.isNotEmpty &&
      fullSegs.length >= rootSegs.length &&
      fullSegs.sublist(0, rootSegs.length).join('/') ==
          rootSegs.join('/')) {
    rel = fullSegs.sublist(rootSegs.length);
  } else {
    rel = fullSegs;
  }
  if (rel.isEmpty) return '';
  return normalizeManualUploadFolder(rel.join('/'));
}

/// 选择器路径拼写（纯函数，供选择器页与测试共用）：各 drive 的
/// 目录列举接口路径拼写不同——SMB 为相对共享的 `/` 分隔路径
/// （可为空），WebDAV/NFS 为 `/` 开头、 `/` 结尾的绝对路径。
/// [isSmb] 为 true 时用 SMB 拼写，否则用 WebDAV/NFS 拼写。

/// 把存的 rootPath 换算为目录列举接口的原生拼写。
String pickerNativeRoot(bool isSmb, String root) {
  if (isSmb) return root;
  if (root.isEmpty) return '/';
  var r = root;
  if (!r.startsWith('/')) r = '/' + r;
  if (!r.endsWith('/')) r = r + '/';
  return r;
}

/// 子目录的原生拼写（与各 form 对话框相同的拼接规则）。
String pickerChildPath(bool isSmb, String current, String name) {
  if (isSmb) {
    return current.isEmpty ? name : '$current/$name';
  }
  return '$current$name/';
}

/// 上一级的原生拼写；已在 [root] 时返回根本身，绝不越界。
String pickerParentPath(bool isSmb, String root, String current) {
  if (current == root) return root;
  if (isSmb) {
    final idx = current.lastIndexOf('/');
    return idx < 0 ? '' : current.substring(0, idx);
  }
  final trimmed =
      current.endsWith('/') ? current.substring(0, current.length - 1) : current;
  final idx = trimmed.lastIndexOf('/');
  return idx < 0 ? '/' : '${trimmed.substring(0, idx + 1)}';
}

/// 读取已存的手动目录原始值（可能为 null/空串）。
Future<String?> loadManualUploadFolder() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString(manualUploadFolderPrefsKey);
}

/// 保存手动目录原始值（设置页已校验；空串表示未设置）。
Future<void> saveManualUploadFolder(String value) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(manualUploadFolderPrefsKey, value);
}
