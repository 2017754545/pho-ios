import 'package:flutter_test/flutter_test.dart';
import 'package:img_syncer/sync/upload_filter.dart';
import 'package:img_syncer/util.dart';

void main() {
  group('UP-18 mimeTypeByExtension key 归一化', () {
    test('视频：带点/不带点/大写都返回 video MIME（此前带点 key 恒为 null）', () {
      expect(mimeTypeByExtension('mp4'), 'video/mp4');
      expect(mimeTypeByExtension('.mp4'), 'video/mp4');
      expect(mimeTypeByExtension('.MP4'), 'video/mp4');
      expect(mimeTypeByExtension('mov'), 'video/mov');
      expect(mimeTypeByExtension('.mov'), 'video/mov');
      expect(mimeTypeByExtension('webm'), 'video/webm');
      expect(mimeTypeByExtension('.WEBM'), 'video/webm');
    });

    test('图片：带点/不带点/大写一致', () {
      expect(mimeTypeByExtension('jpg'), 'image/jpeg');
      expect(mimeTypeByExtension('.jpg'), 'image/jpeg');
      expect(mimeTypeByExtension('.JPG'), 'image/jpeg');
      expect(mimeTypeByExtension('jpeg'), 'image/jpeg');
      expect(mimeTypeByExtension('.heic'), 'image/heic');
      expect(mimeTypeByExtension('png'), 'image/png');
    });

    test('未知/空扩展名返回 null', () {
      expect(mimeTypeByExtension('xyz'), isNull);
      expect(mimeTypeByExtension('.xyz'), isNull);
      expect(mimeTypeByExtension(''), isNull);
      expect(mimeTypeByExtension('.'), isNull);
    });
  });

  group('FK-14 effectiveCreateDate canonical 规则', () {
    test('1990 前的 createDateTime 回退到 modifiedDateTime', () {
      expect(
        effectiveCreateDate(DateTime(1980, 5, 1), DateTime(2024, 6, 1)),
        DateTime(2024, 6, 1),
      );
      expect(
        effectiveCreateDate(DateTime(1970, 1, 1), DateTime(2024, 6, 1)),
        DateTime(2024, 6, 1),
      );
    });

    test('有效的 createDateTime 直接采用（modified 更旧也不影响）', () {
      expect(
        effectiveCreateDate(DateTime(2024, 6, 1), DateTime(1980, 1, 1)),
        DateTime(2024, 6, 1),
      );
    });

    test('恰为 1990-01-01 时不回退（isBefore 边界）', () {
      expect(
        effectiveCreateDate(DateTime(1990, 1, 1), DateTime(2024, 6, 1)),
        DateTime(1990, 1, 1),
      );
    });
  });

  group('FK-22 B2 补充：闰年 2 月 29 日 / 非闰年 2 月 28 日', () {
    test('选中结束日为闰年 2 月 29 日：上界为 3 月 1 日 00:00', () {
      expect(
        UploadFilterConfig.exclusiveBeforeBound(DateTime(2024, 2, 29)),
        DateTime(2024, 3, 1),
      );
      expect(
        UploadFilterConfig.inclusiveEndDay(DateTime(2024, 3, 1)),
        DateTime(2024, 2, 29),
      );
    });

    test('选中结束日为非闰年 2 月 28 日：上界为 3 月 1 日（无 2 月 29 日）', () {
      expect(
        UploadFilterConfig.exclusiveBeforeBound(DateTime(2025, 2, 28)),
        DateTime(2025, 3, 1),
      );
      expect(
        UploadFilterConfig.exclusiveBeforeBound(DateTime(2023, 2, 28)),
        DateTime(2023, 3, 1),
      );
      expect(
        UploadFilterConfig.inclusiveEndDay(DateTime(2025, 3, 1)),
        DateTime(2025, 2, 28),
      );
    });

    test('闰年 2 月 28 日选中日：上界为 2 月 29 日（不是 3 月 1 日）', () {
      expect(
        UploadFilterConfig.exclusiveBeforeBound(DateTime(2024, 2, 28)),
        DateTime(2024, 2, 29),
      );
    });

    test('边界 instant 语义：结束日 2 月 29 日全天保留，恰等于上界通过，之后排除', () {
      // 边界 instant 说明（B2）：allows() 用 `date.isAfter(before)` 排除，
      // before 存的是次日 00:00。恰等于上界 instant（3 月 1 日 00:00:00）
      // 时 isAfter 为假 → 通过；这是“等于 before 通过”的锁定语义在
      // 上界换算下的直接结果，不是 off-by-one：3 月 1 日 00:00:01 即排除。
      final stored =
          UploadFilterConfig.exclusiveBeforeBound(DateTime(2024, 2, 29));
      final config = UploadFilterConfig(enabled: true, before: stored);
      expect(
        config.allows(
            isVideo: false,
            date: DateTime(2024, 2, 29, 23, 59, 59),
            extensionStr: ''),
        isTrue,
      );
      expect(
        config.allows(
            isVideo: false, date: DateTime(2024, 3, 1), extensionStr: ''),
        isTrue,
      );
      expect(
        config.allows(
            isVideo: false,
            date: DateTime(2024, 3, 1, 0, 0, 1),
            extensionStr: ''),
        isFalse,
      );
    });
  });
}
