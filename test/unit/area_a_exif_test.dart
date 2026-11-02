import 'package:flutter_test/flutter_test.dart';
import 'package:img_syncer/asset.dart';

/// UP-17 回归：EXIF 方向值是 1–8 的 tag 值，不是角度；
/// 只有 5–8 需要交换宽高；解析失败返回 null 而不是抛错。
void main() {
  group('exifOrientationSwapsDimensions', () {
    test('1（正常）与 3（180°）不交换', () {
      expect(exifOrientationSwapsDimensions(1), isFalse);
      expect(exifOrientationSwapsDimensions(3), isFalse);
    });

    test('2/4（镜像）不交换', () {
      expect(exifOrientationSwapsDimensions(2), isFalse);
      expect(exifOrientationSwapsDimensions(4), isFalse);
    });

    test('5/6/7/8（90°/270°）交换', () {
      expect(exifOrientationSwapsDimensions(5), isTrue);
      expect(exifOrientationSwapsDimensions(6), isTrue);
      expect(exifOrientationSwapsDimensions(7), isTrue);
      expect(exifOrientationSwapsDimensions(8), isTrue);
    });

    test('null/0/越界值不交换（未知时不猜）', () {
      expect(exifOrientationSwapsDimensions(null), isFalse);
      expect(exifOrientationSwapsDimensions(0), isFalse);
      expect(exifOrientationSwapsDimensions(9), isFalse);
      expect(exifOrientationSwapsDimensions(180), isFalse);
    });
  });

  group('resolveExifDimensions', () {
    test('方向 1：宽高原样', () {
      final resolved = resolveExifDimensions(
          exifWidth: 4032, exifHeight: 3024, orientation: 1);
      expect(resolved!.width, 4032);
      expect(resolved.height, 3024);
    });

    test('方向 3：宽高原样（此前误判为交换）', () {
      final resolved = resolveExifDimensions(
          exifWidth: 4032, exifHeight: 3024, orientation: 3);
      expect(resolved!.width, 4032);
      expect(resolved.height, 3024);
    });

    test('方向 6：宽高交换', () {
      final resolved = resolveExifDimensions(
          exifWidth: 4032, exifHeight: 3024, orientation: 6);
      expect(resolved!.width, 3024);
      expect(resolved.height, 4032);
    });

    test('方向 8：宽高交换', () {
      final resolved = resolveExifDimensions(
          exifWidth: 4032, exifHeight: 3024, orientation: 8);
      expect(resolved!.width, 3024);
      expect(resolved.height, 4032);
    });

    test('任一维度缺失返回 null', () {
      expect(
          resolveExifDimensions(
              exifWidth: null, exifHeight: 3024, orientation: 6),
          isNull);
      expect(
          resolveExifDimensions(
              exifWidth: 4032, exifHeight: null, orientation: 6),
          isNull);
    });
  });

  group('parseExifInt / parseExifOrientation', () {
    test('纯数字解析', () {
      expect(parseExifInt('4032'), 4032);
      expect(parseExifInt(' 6 '), 6);
    });

    test('垃圾输入返回 null 而不抛错', () {
      expect(parseExifInt(null), isNull);
      expect(parseExifInt(''), isNull);
      expect(parseExifInt('abc'), isNull);
      expect(parseExifInt('N/A'), isNull);
    });

    test('方向值取第一个整数', () {
      expect(parseExifOrientation('6'), 6);
      expect(parseExifOrientation('Orientation: 3'), 3);
      expect(parseExifOrientation('unknown'), isNull);
    });
  });
}
