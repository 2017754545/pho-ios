import 'package:flutter_test/flutter_test.dart';
import 'package:img_syncer/asset.dart';
import 'package:img_syncer/state_model.dart';
import 'package:img_syncer/storage/storage_interface.dart';
import 'package:img_syncer/sync/background_runner.dart';
import 'package:mockito/mockito.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 可控的 Asset 子类，绕过 photo_manager AssetEntity 依赖。
class _TestAsset extends Asset {
  final bool _isVideo;
  final DateTime _dateCreated;
  final String _assetId;

  _TestAsset({
    required String id,
    required bool isVideoFlag,
    required DateTime dateCreated,
    String title = 'test.jpg',
  })  : _isVideo = isVideoFlag,
        _dateCreated = dateCreated,
        _assetId = id,
        super(local: null, remote: null) {
    hasLocal = true;
    localTitle = title;
  }

  String get assetId => _assetId;

  @override
  bool isVideo() => _isVideo;

  @override
  DateTime dateCreated() => _dateCreated;
}

/// 用指定 SettingModel 调用 shouldSyncAsset
bool callShouldSync(Asset asset,
    {Map<String, bool>? uploadedIds, SettingModel? sm}) {
  final smUse = sm ?? settingModel;
  final old = settingModel;
  if (sm != null) settingModel = smUse;
  try {
    final ext = (asset.localTitle != null && asset.localTitle!.contains('.'))
        ? '.${asset.localTitle!.split('.').last}'
        : 'jpg';
    final id = (asset is _TestAsset) ? asset.assetId : 'unknown';
    return shouldSyncAsset(asset, id, uploadedIds ?? {}, ext);
  } finally {
    if (sm != null) settingModel = old;
  }
}

/// 记录调用 id 的 storage double：failIds 内的资产抛错，其余成功。
/// 覆写签名与 sync_logic_test.dart 的 MockRemoteStorageClient 相同
/// （mockito 的 any 不能直接用于非空 AssetEntity 形参）。
class _RecordingStorage extends Mock implements RemoteStorageClient {
  final Set<String> failIds;
  final List<String> calls = [];

  _RecordingStorage(this.failIds);

  @override
  Future<void> uploadAssetEntity(AssetEntity? asset) async {
    calls.add(asset!.id);
    if (failIds.contains(asset.id)) {
      throw Exception('network down');
    }
  }
}

Asset _makeRunAsset(String id) {
  final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final entity = AssetEntity(
    id: id,
    typeInt: 1,
    width: 100,
    height: 100,
    createDateSecond: nowSec,
    modifiedDateSecond: nowSec,
    title: '$id.jpg',
  );
  return Asset(local: entity);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    settingModel = SettingModel();
    stateModel = StateModel();
    assetModel = AssetModel();
  });

  group('shouldSyncAsset 过滤一致性', () {
    test('已上传的资源被过滤', () {
      final asset = _TestAsset(
          id: 'test1', isVideoFlag: false, dateCreated: DateTime(2024, 6, 1));
      expect(
        callShouldSync(asset, uploadedIds: {'test1': true}),
        isFalse,
      );
    });

    test('未上传的资源通过过滤', () {
      final asset = _TestAsset(
          id: 'test2', isVideoFlag: false, dateCreated: DateTime(2024, 6, 1));
      expect(
        callShouldSync(asset, uploadedIds: {}),
        isTrue,
      );
    });

    test('filterNoVideo 过滤视频', () {
      final sm = SettingModel();
      sm.setFilterSwitch(true);
      sm.setFilterNoVideo(true);
      final video =
          _TestAsset(id: 'v1', isVideoFlag: true, dateCreated: DateTime(2024, 6, 1));
      expect(callShouldSync(video, sm: sm), isFalse);
    });

    test('filterNoImage 过滤图片', () {
      final sm = SettingModel();
      sm.setFilterSwitch(true);
      sm.setFilterNoImage(true);
      final image =
          _TestAsset(id: 'i1', isVideoFlag: false, dateCreated: DateTime(2024, 6, 1));
      expect(callShouldSync(image, sm: sm), isFalse);
    });

    test('filterAfter 过滤过旧的照片', () {
      final sm = SettingModel();
      sm.setFilterSwitch(true);
      sm.setFilterAfter(DateTime(2024, 6, 15));
      final oldPhoto =
          _TestAsset(id: 'old1', isVideoFlag: false, dateCreated: DateTime(2024, 6, 1));
      expect(callShouldSync(oldPhoto, sm: sm), isFalse);
    });

    test('filterBefore 不过滤同日照片（不含 +1天偏差）', () {
      // BUG 修复核心：columnBuilder 之前用了 .add(Duration(days: 1))
      // 现在统一为 isAfter(filterBefore!) 不含偏移
      final sm = SettingModel();
      sm.setFilterSwitch(true);
      sm.setFilterBefore(DateTime(2024, 6, 1));
      final sameDay = _TestAsset(
          id: 'same', isVideoFlag: false, dateCreated: DateTime(2024, 6, 1));
      // 同日 != isAfter，通过
      expect(callShouldSync(sameDay, sm: sm), isTrue);

      final nextDay = _TestAsset(
          id: 'next', isVideoFlag: false, dateCreated: DateTime(2024, 6, 2));
      // 6/2 > 6/1 → isAfter → 被过滤
      expect(callShouldSync(nextDay, sm: sm), isFalse);
    });

    test('filterTypeMap 根据扩展名过滤', () {
      final sm = SettingModel();
      sm.setFilterSwitch(true);
      sm.filterTypeMap['.gif'] = false;
      final gif = _TestAsset(
          id: 'g1',
          isVideoFlag: false,
          dateCreated: DateTime(2024, 6, 1),
          title: 'test.gif');
      expect(callShouldSync(gif, sm: sm), isFalse);

      final jpg = _TestAsset(
          id: 'j1',
          isVideoFlag: false,
          dateCreated: DateTime(2024, 6, 1),
          title: 'test.jpg');
      expect(callShouldSync(jpg, sm: sm), isTrue);
    });

    test('filter 未启用时全部通过', () {
      final sm = SettingModel();
      sm.setFilterSwitch(false);
      sm.setFilterNoVideo(true);
      final video =
          _TestAsset(id: 'v2', isVideoFlag: true, dateCreated: DateTime(2024, 6, 1));
      expect(callShouldSync(video, sm: sm), isTrue);
    });
  });

  // U5a：原先这里只有一个“10 > 10 为假、11 > 10 为真”的常量断言，
  // 从未触及生产代码。以下用真实 runSyncOnce + 失败 storage double
  // 锁住 background_runner.dart 的 failedTimes 语义：
  //   失败 +1、成功 -1（不低于 0 的效果由“>0 才减”保证）、
  //   循环顶检查 failedTimes > 10 时 break（即第 12 个连续失败
  //   资产不会被尝试：11 次失败后 failedTimes==11 > 10）。
  group('failedTimes 断连检测（runSyncOnce 真实路径）', () {
    test('连续 11 次失败后，第 12 张不再尝试', () async {
      final ids = List.generate(12, (i) => 'f$i');
      final storage = _RecordingStorage(ids.toSet());
      final assets = ids.map(_makeRunAsset).toList();

      final result = await runSyncOnce(
        storage: storage,
        assets: assets,
        uploadedIds: {},
        parallelCount: 1,
        shouldStop: () => false,
      );

      // 串行：11 次失败把 failedTimes 推到 11，第 12 张在循环顶 break。
      expect(storage.calls, ids.sublist(0, 11));
      expect(result.failed, 11);
      expect(result.total, 12);
      expect(result.failures.keys, ids.sublist(0, 11).toSet());
    });

    test('中间一次成功会把 failedTimes 减 1：11 次失败不再触发 break', () async {
      // 5 失败（failedTimes=5）→ 1 成功（→4）→ 6 失败（→10）：
      // 全程 failedTimes 未超过 10，12 张全部被尝试。
      final ids = List.generate(12, (i) => 'm$i');
      final failIds = {...ids}..remove('m5');
      final storage = _RecordingStorage(failIds);
      final assets = ids.map(_makeRunAsset).toList();

      final result = await runSyncOnce(
        storage: storage,
        assets: assets,
        uploadedIds: {},
        parallelCount: 1,
        shouldStop: () => false,
      );

      expect(storage.calls, ids);
      expect(result.failed, 11);
      expect(result.succeeded, 1);
      expect(result.total, 12);
    });
  });
}
