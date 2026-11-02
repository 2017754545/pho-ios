import 'package:flutter_test/flutter_test.dart';
import 'package:img_syncer/camera_album_classifier.dart';

void main() {
  group('相册名匹配（大小写 / 繁简容差）', () {
    test('相机相册名 → camera', () {
      expect(isCameraAlbumName('Camera'), isTrue);
      expect(isCameraAlbumName('camera'), isTrue);
      expect(isCameraAlbumName('CAMERA'), isTrue);
      expect(isCameraAlbumName('相机'), isTrue);
      expect(isCameraAlbumName('相機'), isTrue);
      expect(isCameraAlbumName('Recents'), isFalse);
      expect(isCameraAlbumName(null), isFalse);
    });

    test('截图相册名 → excluded 集合命中', () {
      expect(isScreenshotAlbumName('Screenshots'), isTrue);
      expect(isScreenshotAlbumName('screenshots'), isTrue);
      expect(isScreenshotAlbumName('Screenshot'), isTrue);
      expect(isScreenshotAlbumName('截屏'), isTrue);
      expect(isScreenshotAlbumName('截圖'), isTrue);
      expect(isScreenshotAlbumName('屏幕截图'), isTrue);
      expect(isScreenshotAlbumName('Camera'), isFalse);
      expect(isScreenshotAlbumName(null), isFalse);
    });
  });

  group('classifyCameraAsset 三态', () {
    test('相机相册内的普通照片 → camera', () {
      expect(
        classifyCameraAsset(albumName: 'Camera', title: 'IMG_1234.jpg'),
        CameraClassification.camera,
      );
      expect(
        classifyCameraAsset(albumName: '相机', title: 'IMG_1234.jpg'),
        CameraClassification.camera,
      );
    });

    test('截图相册内的照片 → excluded（整相册即截图）', () {
      expect(
        classifyCameraAsset(albumName: 'Screenshots', title: 'IMG_1234.png'),
        CameraClassification.excluded,
      );
      expect(
        classifyCameraAsset(albumName: '截屏', title: null),
        CameraClassification.excluded,
      );
    });

    test('文件名前缀启发 → excluded（仅辅助证据，但命中即排除）', () {
      expect(
        classifyCameraAsset(albumName: 'Recents', title: 'Screenshot_2024.png'),
        CameraClassification.excluded,
      );
      expect(
        classifyCameraAsset(
            albumName: 'Recents', title: 'ScreenRecording_1.mp4'),
        CameraClassification.excluded,
      );
      // 相机相册里出现截图文件仍是截图：文件名证据优先于相册名。
      expect(
        classifyCameraAsset(albumName: 'Camera', title: 'Screenshot_1.png'),
        CameraClassification.excluded,
      );
    });

    test('unknown 默认保留：Recents 内无法区分的照片一律 unknown', () {
      // 微信 / WhatsApp 保存到 Recents 的图片与相机照片无法区分，
      // 必须保留显示，绝不能凭弱信号删除。
      expect(
        classifyCameraAsset(albumName: 'Recents', title: 'IMG_1234.jpg'),
        CameraClassification.unknown,
      );
      expect(
        classifyCameraAsset(albumName: 'Recents', title: 'mmexport1.jpg'),
        CameraClassification.unknown,
      );
      expect(
        classifyCameraAsset(albumName: 'Recents', title: null),
        CameraClassification.unknown,
      );
      expect(
        classifyCameraAsset(albumName: null, title: null),
        CameraClassification.unknown,
      );
      expect(
        classifyCameraAsset(albumName: 'Favorites', title: 'IMG_1.jpg'),
        CameraClassification.unknown,
      );
    });

    test('非截图前缀不误判', () {
      expect(
        classifyCameraAsset(
            albumName: 'Recents', title: 'ScreenshotOfMyself.jpg'),
        CameraClassification.unknown,
      );
      expect(
        classifyCameraAsset(albumName: 'Recents', title: 'my_screenshot.png'),
        CameraClassification.unknown,
      );
    });
  });
}
