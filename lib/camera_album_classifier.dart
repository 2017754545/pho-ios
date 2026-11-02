/// 仅相机相册的分类器（iOS 信号 only，纯函数，无平台通道、无新依赖）。
///
/// iOS 上不存在 DCIM 路径概念，`originFile` 路径无意义；唯一可靠信号是
/// 相册归属（截图是独立的系统 smart album），文件名启发只作辅助证据。
/// 因此分类结果是三态：信号不足判为 [unknown]，展示层默认**保留**
/// （宁可多显示，不可误删用户照片）；只有确认为截图/录屏时才判
/// [excluded]。
///
/// 局限（有意保留，不猜测扩展）：
/// - 相册名是**精确匹配**（大小写/繁简容差后相等才命中），未收录
///   的变体（如个别本地化名）会判为 unknown 而保留显示（fail-open，
///   宁可多显示）；只有真机上实际出现的相册名才能作为新增匹配的
///   依据，不得凭推测加名。
/// - [isCameraAlbumName] 在 iOS 上很难触发：photo_manager 返回的
///   默认全量相册名是 Recents（“最近项目”），而不是 Camera；相机
///   拍摄的照片与微信等 App 保存的照片都混在 Recents 里，无法仅
///   凭相册名区分。因此“仅相机”展示真正可靠的逐资产排除信号是
///   AssetModel.refreshCameraExcludedIds() 枚举截图相册得到的 ID
///   集合，本分类器只是第二道文件名/相册名启发。
enum CameraClassification {
  /// 相机拍摄（或所在相册即相机相册）。
  camera,

  /// 确认为截图 / 屏幕录制等非相机内容。
  excluded,

  /// 信号不足，无法判定 —— 展示层默认保留。
  unknown,
}

/// 相机相册名（大小写 / 繁简容差匹配）。iOS 上 photo_manager 返回的
/// 系统相册名以英文为主，中文设备也可能返回本地化名，故两者都认。
const _cameraAlbumNames = <String>{
  'camera',
  '相机',
  '相機',
};

/// 截图类相册名（大小写 / 繁简容差匹配）。
const _screenshotAlbumNames = <String>{
  'screenshots',
  'screenshot',
  '截屏',
  '截圖',
  '屏幕截图',
  '螢幕截圖',
};

bool isCameraAlbumName(String? name) {
  if (name == null) return false;
  return _cameraAlbumNames.contains(name.trim().toLowerCase());
}

/// 相册名是否为截图类相册。AssetModel.refreshCameraExcludedIds() 用它
/// 枚举截图相册、收集其中资产 ID（iOS 上最可靠的排除信号）。
bool isScreenshotAlbumName(String? name) {
  if (name == null) return false;
  return _screenshotAlbumNames.contains(name.trim().toLowerCase());
}

/// 文件名前缀启发（仅辅助证据）：iOS 截图 / 录屏文件的常见命名。
/// 命中即判 excluded；未命中不作任何肯定推断（第三方相机 App 也可能
/// 用 IMG_ 等通用前缀，绝不能凭文件名肯定某张是相机拍摄）。
bool _looksLikeScreenshotFile(String? title) {
  if (title == null) return false;
  final name = title.trim().toLowerCase();
  return name.startsWith('screenshot_') ||
      name.startsWith('screenshot ') ||
      name.startsWith('screenrecording_') ||
      name.startsWith('screen recording') ||
      name.startsWith('rpreplay_final');
}

/// 分类一张资产。
///
/// [albumName]：**当前查看的相册名**（展示层取
/// settingModel.localFolder，对列表内全部资产相同），不是该资产
/// 各自所属的相册——因此“所在相册是截图相册”这一条实际含义是
/// “当前正在浏览截图相册”。逐资产的相册归属无法从本参数得知，
/// 须用 AssetModel.cameraExcludedIds 另行排除。
/// [title]：资产文件名/标题（Asset.localTitle 或
/// AssetEntity.title，任一为空都按无信息处理）。
///
/// 判定顺序：
/// 1. 所在相册是截图相册 → excluded（整相册即截图）。
/// 2. 文件名命中截图/录屏启发 → excluded。
/// 3. 所在相册是相机相册 → camera。
/// 4. 其余 → unknown（保留）。
CameraClassification classifyCameraAsset({
  required String? albumName,
  required String? title,
}) {
  if (isScreenshotAlbumName(albumName)) {
    return CameraClassification.excluded;
  }
  if (_looksLikeScreenshotFile(title)) {
    return CameraClassification.excluded;
  }
  if (isCameraAlbumName(albumName)) {
    return CameraClassification.camera;
  }
  return CameraClassification.unknown;
}
