import 'package:flutter_test/flutter_test.dart';
import 'package:img_syncer/asset.dart';
import 'package:img_syncer/gallery_body.dart';
import 'package:photo_manager/photo_manager.dart';

Asset _localAsset(String id, DateTime created) {
  final entity = AssetEntity(
    id: id,
    typeInt: 1,
    width: 100,
    height: 100,
    createDateSecond: created.millisecondsSinceEpoch ~/ 1000,
    modifiedDateSecond: created.millisecondsSinceEpoch ~/ 1000,
    title: '$id.jpg',
  );
  return Asset(local: entity, remote: null);
}

void main() {
  group('stableKey', () {
    test('本地资产以 id 为键，远端资产以 path 为键', () {
      expect(_localAsset('abc', DateTime(2024, 6, 1)).stableKey(), 'local:abc');
    });

    test('无 local/remote 的资产有回退键（不崩溃）', () {
      final asset = Asset();
      expect(asset.stableKey(), startsWith('asset:'));
    });
  });

  group('resolveSelectedAssets（FK-7）', () {
    test('按 id 解析：列表重排后仍命中同一资产', () {
      final a = _localAsset('a', DateTime(2024, 6, 1));
      final b = _localAsset('b', DateTime(2024, 6, 2));
      final c = _localAsset('c', DateTime(2024, 6, 3));
      final selected = {'local:b'};

      // 原始顺序。
      expect(resolveSelectedAssets([a, b, c], selected), [b]);
      // 刷新/重排后（b 移到首位，前面插入新资产）。
      final d = _localAsset('d', DateTime(2024, 6, 4));
      expect(resolveSelectedAssets([d, b, a, c], selected), [b]);
      // b 被另一资产替换了位置：按位置取 [1] 会取到 a，错误；
      // 按 id 解析仍取 b（若 b 已不在列表则取空，见下）。
      expect(resolveSelectedAssets([d, a, c], selected), isEmpty);
    });

    test('删除/分享/上传共享的解析：已移除的 id 被丢弃，不误伤他人', () {
      final a = _localAsset('a', DateTime(2024, 6, 1));
      final b = _localAsset('b', DateTime(2024, 6, 2));
      final selected = {'local:a', 'local:b', 'local:ghost'};
      // b 已删除，ghost 从未存在：只剩 a。
      expect(resolveSelectedAssets([a], selected), [a]);
    });

    test('空选择/空列表返回空，不越界', () {
      final a = _localAsset('a', DateTime(2024, 6, 1));
      expect(resolveSelectedAssets([a], <String>{}), isEmpty);
      expect(resolveSelectedAssets([], {'local:a'}), isEmpty);
    });
  });

  group('pruneStaleSelectionIds', () {
    test('保留仍在列表中的 id，丢弃其余', () {
      final a = _localAsset('a', DateTime(2024, 6, 1));
      final pruned = pruneStaleSelectionIds(
          [a], {'local:a', 'local:gone'});
      expect(pruned, {'local:a'});
    });
  });

  group('groupDateLocateEntries（UP-20）', () {
    test('按月分组：每组计数为组内各日之和，最后一组不丢失', () {
      final entries = <DateTime, LocateInfo>{
        DateTime(2024, 6, 1): LocateInfo(location: 0, count: 5),
        DateTime(2024, 6, 2): LocateInfo(location: 100, count: 3),
        DateTime(2024, 7, 1): LocateInfo(location: 200, count: 2),
      };
      final groups = groupDateLocateEntries(
          entries, (day) => DateTime(day.year, day.month));
      expect(groups.length, 2);
      expect(groups[0].key, DateTime(2024, 6));
      expect(groups[0].count, 8);
      expect(groups[0].location, 0);
      // 此前 bug：7 月的 2 张被并入 6 月，7 月组从未出现。
      expect(groups[1].key, DateTime(2024, 7));
      expect(groups[1].count, 2);
      expect(groups[1].location, 200);
    });

    test('按年分组：跨年各组独立，计数不串', () {
      final entries = <DateTime, LocateInfo>{
        DateTime(2023, 12, 31): LocateInfo(location: 0, count: 4),
        DateTime(2024, 1, 1): LocateInfo(location: 100, count: 1),
        DateTime(2024, 6, 1): LocateInfo(location: 200, count: 7),
      };
      final groups =
          groupDateLocateEntries(entries, (day) => DateTime(day.year));
      expect(groups.length, 2);
      expect(groups[0].key, DateTime(2023));
      expect(groups[0].count, 4);
      expect(groups[1].key, DateTime(2024));
      expect(groups[1].count, 8);
    });

    test('空映射返回空组', () {
      expect(
          groupDateLocateEntries(
              <DateTime, LocateInfo>{}, (day) => DateTime(day.year)),
          isEmpty);
    });
  });

  group('locaterIndexForOffset（UP-19）', () {
    test('空列表返回 -1（不除零、不越界）', () {
      expect(locaterIndexForOffset(0, 10, 0), -1);
      expect(locaterIndexForOffset(100, 10, 0), -1);
    });

    test('负偏移钳制到 0，超界偏移钳制到末位', () {
      expect(locaterIndexForOffset(-50, 10, 3), 0);
      expect(locaterIndexForOffset(1000, 10, 3), 2);
      expect(locaterIndexForOffset(25, 10, 3), 2);
      expect(locaterIndexForOffset(9, 10, 3), 0);
    });

    test('非法步高（0/NaN/无穷）返回首位，不抛错', () {
      expect(locaterIndexForOffset(50, 0, 3), 0);
      expect(locaterIndexForOffset(50, double.nan, 3), 0);
      expect(locaterIndexForOffset(50, double.infinity, 3), 0);
    });
  });
}
