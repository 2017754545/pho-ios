import 'dart:io';

import 'package:flutter/services.dart';
import 'package:img_syncer/logger/logger.dart';
import 'package:path/path.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// 按日期降序排序（issue #84：Android 上 photo_manager 枚举顺序与
/// 显示日期不一致导致年份穿插）。提取为纯函数以便单元测试。
List<T> sortByDateDesc<T>(List<T> items, DateTime Function(T) dateOf) {
  final sorted = List<T>.of(items);
  sorted.sort((a, b) => dateOf(b).compareTo(dateOf(a)));
  return sorted;
}

/// 资产的有效拍摄日期：部分旧照片 / 导入照片的 createDateTime 可能是
/// 1970 纪元起点等无效值，此时回退到 modifiedDateTime。
/// 该规则此前在 state_model.dart 与 storage.dart 各写了一份，此处为唯一
/// canonical 实现，上传日期筛选与远端比对都复用它，禁止再复制第三份。
DateTime effectiveCreateDate(
    DateTime createDateTime, DateTime modifiedDateTime) {
  if (createDateTime.isBefore(DateTime(1990, 1, 1))) {
    return modifiedDateTime;
  }
  return createDateTime;
}

bool isVideoByPath(String path) {
  if (extension(path).toLowerCase() == ".aes") {
    path = basenameWithoutExtension(path);
  }
  switch (extension(path).toLowerCase()) {
    case ".mp4":
    case ".avi":
    case ".mov":
    case ".mkv":
    case ".flv":
    case ".rmvb":
    case ".rm":
    case ".3gp":
    case ".wmv":
    case ".mpeg":
    case ".mpg":
    case ".webm":
      return true;
  }
  return false;
}

/// 按扩展名查 MIME。调用方传入的扩展名可能带点（如 '.mp4'，见
/// path.extension()）或不带点（如 'mp4'，见 Asset.mimeType() 的正则
/// 捕获组），此处统一归一化（去空白、小写、去前导点）后再匹配；
/// 此前 switch 里图片用无点 key、视频用带点 key，视频 MIME 恒为 null。
String? mimeTypeByExtension(String ext) {
  var key = ext.trim().toLowerCase();
  if (key.startsWith('.')) key = key.substring(1);
  switch (key) {
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'png':
      return 'image/png';
    case 'gif':
      return 'image/gif';
    case 'bmp':
      return 'image/bmp';
    case 'webp':
      return 'image/webp';
    case 'heic':
      return 'image/heic';
    case 'heif':
      return 'image/heif';
    case 'dng':
      return 'image/x-adobe-dng';
    case 'tif':
    case 'tiff':
      return 'image/tiff';
    case 'cr2':
      return 'image/x-canon-cr2';
    case 'nef':
      return 'image/x-nikon-nef';
    case 'arw':
      return 'image/x-sony-arw';
    case 'rw2':
      return 'image/x-panasonic-rw2';
    case 'orf':
      return 'image/x-olympus-orf';
    case 'pef':
      return 'image/x-pentax-pef';
    case 'raf':
      return 'image/x-fuji-raf';
    case 'x3f':
      return 'image/x-sigma-x3f';
    case 'srw':
      return 'image/x-samsung-srw';
    case 'mp4':
      return 'video/mp4';
    case 'avi':
      return 'video/avi';
    case 'mov':
      return 'video/mov';
    case 'mkv':
      return 'video/mkv';
    case 'flv':
      return 'video/flv';
    case 'rmvb':
      return 'video/rmvb';
    case 'rm':
      return 'video/rm';
    case '3gp':
      return 'video/3gp';
    case 'wmv':
      return 'video/wmv';
    case 'mpeg':
      return 'video/mpeg';
    case 'mpg':
      return 'video/mpg';
    case 'webm':
      return 'video/webm';
    default:
      return null;
  }
}

bool isDesktop() {
  return Platform.isLinux || Platform.isMacOS || Platform.isWindows;
}

Future<void> keepScreenOn(bool on) async {
  if (isDesktop()) {
    return;
  }
  try {
    if (Platform.isIOS) {
      const channel = MethodChannel('com.example.img_syncer/notifications');
      await channel.invokeMethod('keepScreenOn', {'enable': on});
    } else {
      if (on) {
        await WakelockPlus.enable();
      } else {
        await WakelockPlus.disable();
      }
    }
  } catch (e) {
    logger.addLog("keepScreenOn($on) failed: $e");
  }
}
