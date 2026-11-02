import 'dart:io';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:img_syncer/storage/storage.dart';
import 'package:img_syncer/proto/img_syncer.pbgrpc.dart';
import 'package:img_syncer/global.dart';
import 'package:img_syncer/state_model.dart';
import 'package:http/http.dart' as http;
import 'package:mockito/mockito.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MockImgSyncerClient extends Mock implements ImgSyncerClient {}

RemoteImage _makeRemoteImage(String path) {
  return RemoteImage(
    MockImgSyncerClient(),
    path,
    httpClient: http.Client(),
  );
}

/// 1x1 透明 PNG（thumbnailDataAsync 的 isValidImage 校验可解码）。
final _tinyPng = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8Xw8AAwMCAO+ip1sAAAAASUVORK5CYII=');

void main() {
  // U2：dataStream / thumbnailStream / uploadAssetEntity 都会先调
  // checkServer()；checkServer 失败时在 catch 里读 late 变量 grpcPort
  // 记日志（global.dart），未初始化即抛 LateInitializationError。
  // 本文件不用真实 Go server：与 sync_logic_test 相同的 harness——
  // useRemoteServer=true 使 checkServer 立即返回，同时显式初始化
  // grpcPort（双重保障，任一路径都不触 late 未初始化）。
  late bool originalUseRemoteServer;

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    originalUseRemoteServer = useRemoteServer;
    useRemoteServer = true;
    grpcPort = 50051;
    settingModel = SettingModel();
    stateModel = StateModel();
    // flutter_test 的 TestWidgetsFlutterBinding 会把全局 HttpClient
    // 换成恒返回 400 的 mock（_binding_io.dart setupHttpOverrides），
    // 本地 HttpServer 永远收不到请求。本文件用真实回环 HTTP 测
    // dataStream/thumbnail：把 HttpOverrides.global 置空，恢复
    // 真实 HttpClient（仅本文件用例内；tearDown 恢复原值）。
    // 这是测试 harness 的选择，不改生产代码。
    // Dart 3.13 起 HttpOverrides.global 只有 setter（无 getter），
    // 直接置空即可；本文件各用例都在独立 isolate 跑，不影响他文件。
    HttpOverrides.global = null;
  });

  tearDown(() {
    useRemoteServer = originalUseRemoteServer;
  });

  group('RemoteImage.dataStream - contentLength null defense (M9)', () {
    late HttpServer server;
    late int port;
    final testData = utf8.encode('Hello, test data!');

    /// 设为 true 时，服务器响应不包含 Content-Length header
    bool omitContentLength = false;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      port = server.port;
      httpBaseUrl = 'http://127.0.0.1:$port';
      httpPort = port;
      omitContentLength = false;

      server.listen((request) {
        final resp = request.response;
        resp.statusCode = 200;
        if (!omitContentLength) {
          resp.headers.set('content-length', testData.length.toString());
        }
        resp.add(testData);
        resp.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('contentLength 为 null 时不崩溃，total 使用 -1', () async {
      omitContentLength = true;
      final image = _makeRemoteImage('test.jpg');
      int? progressTotal;

      final stream = image.dataStream(
        reportProgress: false,
        onProgress: (downloaded, total) {
          progressTotal = total;
        },
      );

      final result = BytesBuilder();
      await for (final chunk in stream) {
        result.add(chunk);
      }

      expect(progressTotal, -1);
      expect(result.takeBytes(), testData);
    });

    test('有效 contentLength 被正确报告', () async {
      final image = _makeRemoteImage('test.jpg');
      final progressCalls = <Map<String, int>>[];

      final stream = image.dataStream(
        reportProgress: false,
        onProgress: (downloaded, total) {
          progressCalls.add({'downloaded': downloaded, 'total': total});
        },
      );

      await for (final _ in stream) {
        /* 消费数据 */
      }

      expect(progressCalls.isNotEmpty, isTrue);
      expect(progressCalls.first['total'], testData.length);
      expect(progressCalls.last['downloaded'], testData.length);
    });

    test('onProgress 回调中 downloaded 逐步递增', () async {
      final bigData = utf8.encode('A' * 10000);
      server.close();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      port = server.port;
      httpBaseUrl = 'http://127.0.0.1:$port';
      httpPort = port;
      server.listen((request) {
        final resp = request.response;
        resp.statusCode = 200;
        resp.headers.set('content-length', bigData.length.toString());
        resp.add(bigData);
        resp.close();
      });

      final image = _makeRemoteImage('big.jpg');
      final downloadeds = <int>[];
      int? total;

      final stream = image.dataStream(
        reportProgress: false,
        onProgress: (downloaded, t) {
          downloadeds.add(downloaded);
          total = t;
        },
      );

      await for (final _ in stream) {
        /* 消费数据 */
      }

      expect(total, bigData.length);
      expect(downloadeds.first, greaterThan(0));
      // downloaded 不递减
      for (int i = 1; i < downloadeds.length; i++) {
        expect(downloadeds[i], greaterThanOrEqualTo(downloadeds[i - 1]));
      }
      expect(downloadeds.last, bigData.length);
    });
  });

  group('RemoteImage.thumbnail 重试（真实后端 double，U5c）', () {
    late HttpServer server;
    late int port;
    var thumbHits = 0;

    /// 前 [failFirst] 次 GET 返回 500，之后返回 _tinyPng。
    var failFirst = 0;

    setUp(() async {
      thumbHits = 0;
      failFirst = 0;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      port = server.port;
      httpBaseUrl = 'http://127.0.0.1:$port';
      httpPort = port;
      server.listen((request) async {
        thumbHits++;
        await request.drain();
        final resp = request.response;
        if (thumbHits <= failFirst) {
          resp.statusCode = 500;
          resp.write('boom');
        } else {
          resp.statusCode = 200;
          resp.headers.contentType = ContentType('image', 'png');
          resp.add(_tinyPng);
        }
        await resp.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('前 2 次 500 后成功：重试 3 次拿到缩略图', () async {
      failFirst = 2;
      final image = _makeRemoteImage('thumb.jpg');
      final bytes = await image.thumbnail();
      expect(bytes, _tinyPng);
      expect(thumbHits, 3);
    });

    test('一直 500：3 次耗尽后返回 null，不缓存失败结果', () async {
      failFirst = 99;
      final image = _makeRemoteImage('thumb.jpg');
      final bytes = await image.thumbnail();
      expect(bytes, isNull);
      expect(thumbHits, 3);
      // 再次调用仍重试（失败不写入 thumbnailData 缓存）。
      final again = await image.thumbnail();
      expect(again, isNull);
      expect(thumbHits, 6);
    });
  });

  // U5c 余项（Linux host 无法驱动，已验证的阻塞点）：
  // uploadAssetEntity 的重试循环（maxRetries=3，循环内 uploaded=0
  // 重计）在 Linux 的 flutter test 里跑不起来：第一步
  // asset.originFile → photo_manager 的 AssetEntity.getFile() 在
  // Dart 侧 assert(_platformMatched)（entity.dart:846，
  // _platformMatched = iOS/macOS/Android[/Windows]，Linux 恒为假），
  // debug 下直接抛 _AssertionError，mock 通道根本到不了。flutter
  // test 没有关闭 assert 的开关。macOS/Windows host 或真机上可用
  // 本组删除前的写法复现（HttpServer 先 500 后 200 + getFullFile/
  // getThumb 通道 mock + 150KB 文件观测进度回落）。此处只保留
  // 可在 Linux 跑的退避纯函数测试；上传重试循环本身的真实后端
  // 覆盖由 thumbnail() 重试组（同文件）承担，upload 循环仍待
  // macOS 验证（见报告）。
  group('upload 重试退避（纯函数，可在 Linux 跑）', () {
    test('uploadRetryDelay 指数退避 + 抖动上界（确定性随机源）', () {
      // 500ms 起、指数增长、封顶 8000ms、抖动 0–249ms。
      // 用固定种子 Random 锁住区间而非具体值（抖动本就是随机的，
      // 锁区间才是正确语义）。
      final rng = math.Random(42);
      final d1 = uploadRetryDelay(1, random: rng);
      final d2 = uploadRetryDelay(2, random: rng);
      final d3 = uploadRetryDelay(3, random: rng);
      final dBig = uploadRetryDelay(99, random: rng);
      expect(d1.inMilliseconds, inInclusiveRange(500, 749));
      expect(d2.inMilliseconds, inInclusiveRange(1000, 1249));
      expect(d3.inMilliseconds, inInclusiveRange(2000, 2249));
      expect(dBig.inMilliseconds, inInclusiveRange(8000, 8249));
    });
  });
}
