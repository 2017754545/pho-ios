import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:grpc/grpc.dart';
import 'package:img_syncer/logger/logger.dart';
import 'package:img_syncer/proto/img_syncer.pbgrpc.dart';
import 'package:date_format/date_format.dart';
import 'package:img_syncer/state_model.dart';
import 'package:path/path.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:img_syncer/global.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/services.dart';
import 'package:img_syncer/util.dart';
import 'package:img_syncer/storage/storage_interface.dart';

/// 将 EncryptionType 转为 HTTP 头字符串
String encryptionTypeName(EncryptionType type) {
  switch (type) {
    case EncryptionType.none:
      return 'None';
    case EncryptionType.aesCfb:
      return 'AES_128_CFB';
    case EncryptionType.aesGcm:
      return 'AES_256_GCM';
  }
}

RemoteStorage storage = RemoteStorage("127.0.0.1", 10000);

/// 用 pathSegments 构造指向本地 Go server 的 HTTP URL：文件名按段编码，
/// 含空格 / `#` / `?` 的标题也不会被 Uri.parse 截断（`#` 后成 fragment、
/// `?` 后成 query）或拼成非法 URL。调用方传原始段，不预编码。
/// [baseUrl] 供单次上传快照 base URL 用；缺省读当前全局 [httpBaseUrl]。
Uri storageHttpUri(List<String> pathSegments, {String? baseUrl}) {
  final base = Uri.parse(baseUrl ?? httpBaseUrl);
  return base.replace(
      pathSegments: [...base.pathSegments, ...pathSegments]);
}

/// 上传重试的退避延迟：500ms 起指数增长（500/1000/2000/4000/8000ms
/// 封顶）+ 0–249ms 抖动，避免失败后立即 hammering server。
/// [attempt] 为已失败次数（1-based）；[random] 仅供测试注入确定性随机源。
Duration uploadRetryDelay(int attempt, {math.Random? random}) {
  final exponent = (attempt - 1).clamp(0, 4);
  final baseMs = 500 * (1 << exponent);
  final jitterMs = (random ?? math.Random()).nextInt(250);
  return Duration(milliseconds: baseMs + jitterMs);
}

/// 替换全局 [storage] 并关闭旧实例的 gRPC channel 与 HTTP 客户端。
/// 旧实例的关闭不阻塞调用方（fire-and-forget）；storage 重建点
/// （Global.init / checkServer 重启 / 后台入口）都应走这里，
/// 而不是直接给 `storage` 赋值，否则旧 channel 被遗弃且永不 shutdown。
void setGlobalStorage(RemoteStorage next) {
  final previous = storage;
  storage = next;
  unawaited(previous.close());
}

/// 上传完成后是否删除本地源文件：仅 iOS 且上传成功时删除。
/// 原 finally 块无条件删除，同步失败时源文件会丢失（issue #83/#82）。
bool shouldDeleteLocalFileAfterUpload({
  required bool isIOS,
  required bool uploadSucceeded,
}) =>
    isIOS && uploadSucceeded;

/// 测试注入用的 override，非 null 时替换 storage 全局变量
RemoteStorageClient? _storageOverride;
RemoteStorageClient get storageClient => _storageOverride ?? storage;
void setStorageForTest(RemoteStorageClient v) => _storageOverride = v;

class RemoteStorage implements RemoteStorageClient {
  int bufferSize = 1024 * 1024;

  /// 共享 HTTP 客户端，复用连接减少 TCP 握手开销
  http.Client httpClient = http.Client();

  /// 唯一的 gRPC channel：仅在构造函数里创建（此前字段初始化器建了
  /// 一个、构造函数又建一个并覆盖 cli，第一个 channel 被遗弃）。
  late final ClientChannel _channel;

  /// 由 [_channel] 派生的客户端；实现 RemoteStorageClient.cli。
  @override
  late final ImgSyncerClient cli;

  bool _closed = false;

  RemoteStorage(String addr, int port) {
    _channel = ClientChannel(
      addr,
      port: port,
      options: const ChannelOptions(
        credentials: ChannelCredentials.insecure(),
      ),
    );
    cli = ImgSyncerClient(_channel);
  }

  /// 关闭本实例的 gRPC channel 与共享 HTTP 客户端。幂等；替换全局
  /// storage 时由 [setGlobalStorage] 调用。关闭后本实例不再可用。
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _channel.shutdown();
    httpClient.close();
  }

  Future<void> uploadAssetEntity(AssetEntity asset) async {
    await checkServer();
    // 单次上传内快照 base URL：checkServer 可能在并发上传间重启 server
    // 并切换 httpBaseUrl，同一张照片的缩略图/原件/live 视频必须发往
    // 同一个 server（UP-14 的一部分）。
    final String uploadBaseUrl = httpBaseUrl;
    final file = await asset.originFile;
    if (file == null) {
      throw Exception("asset file is null");
    }
    String? name = asset.title;
    name ??= await asset.titleAsync;
    // print("upload $name");
    // 1990 回退走 util.dart 的唯一 canonical 实现，禁止再复制一份（FK-14）。
    final date = effectiveCreateDate(asset.createDateTime, asset.modifiedDateTime);
    final dateStr =
        formatDate(date, [yyyy, ':', mm, ':', dd, ' ', HH, ':', nn, ':', ss]);
    var thumbnailSize = const ThumbnailSize.square(200);
    if (asset.type == AssetType.video) {
      thumbnailSize = const ThumbnailSize.square(800);
    }
    final thumbnailData =
        await asset.thumbnailDataWithSize(thumbnailSize, quality: 90);
    // 缩略图生成失败（视频/HEIC 等）时降级：跳过缩略图继续上传原件（issue #64/#57）
    File? liveVideoFile;
    final imgLen = await file.length();
    final thumbLen = thumbnailData?.length ?? 0;
    int totalLen = imgLen + thumbLen;
    stateModel.updateUploadProgress(asset.id, 1, totalLen);
    int maxRetries = 3;
    int retryCount = 0;
    bool succeeded = false;
    while (!succeeded) {
      int uploaded = 0;
      try {
        // live 视频在重试循环内重新获取：iCloud 优化存储下视频可能未下载，
        // 首轮拿不到（返回 null），重试时可能已下载完成。
        // 拿不到视频时不静默跳过——抛异常走 catch，失败则不加入 syncedIDs。
        liveVideoFile = null;
        if (asset.isLivePhoto) {
          liveVideoFile = await asset.originFileWithSubtype;
          if (liveVideoFile == null) {
            throw Exception(
                "live video file not available (iCloud not downloaded?)");
          }
          totalLen = imgLen + thumbLen + await liveVideoFile.length();
        }
        // upload thumbnail（缩略图缺失时跳过，不中止上传）
        if (thumbnailData != null) {
          final thumbRsp = await http.post(
            storageHttpUri(['thumbnail', name], baseUrl: uploadBaseUrl),
            body: thumbnailData,
            headers: {
              'Image-Date': dateStr,
              'Image-Is-Live-Photo': asset.isLivePhoto ? "true" : "false",
              'Image-Encrypt-Type': settingModel.enableEncrypt
                  ? encryptionTypeName(settingModel.encryptionType)
                  : "None",
              'Image-Encrypt-Password': settingModel.enableEncrypt
                  ? settingModel.encryptionPassword
                  : "",
            },
          );
          stateModel.updateUploadProgress(
              asset.id, uploaded + thumbLen, totalLen);
          if (thumbRsp.statusCode != 200) {
            // finishUpload(false) 只在 catch 里调一次（此前 try 内与
            // catch 各调一次，重复移除进度/notify）。
            logger.addLog(
                "upload $name thumbnail failed: ${thumbRsp.statusCode} ${thumbRsp.body}");
            throw Exception(
                "upload thumbnail failed: [${thumbRsp.statusCode}] ${thumbRsp.body}");
          }
        }
        // upload origin image
        var req = http.StreamedRequest(
            "POST", storageHttpUri([name], baseUrl: uploadBaseUrl));
        req.headers['Image-Date'] = dateStr;
        req.headers['Image-Is-Live-Photo'] =
            asset.isLivePhoto ? "true" : "false";
        if (settingModel.enableEncrypt) {
          req.headers['Image-Encrypt-Type'] =
              encryptionTypeName(settingModel.encryptionType);
          req.headers['Image-Encrypt-Password'] =
              settingModel.encryptionPassword;
        }
        req.contentLength = await file.length();
        file.openRead().listen((chunk) {
          uploaded += chunk.length;
          stateModel.updateUploadProgress(
              asset.id, uploaded + thumbLen, totalLen);
          req.sink.add(chunk);
        }, onDone: () {
          req.sink.close();
        }, onError: (e) {
          req.sink.close();
          throw Exception("file read error: $e");
        });
        final response = await req.send();
        if (response.statusCode != 200) {
          final body = await response.stream.bytesToString();
          throw Exception("upload failed: [${response.statusCode}] $body");
        }
        // upload Live Photo video
        if (asset.isLivePhoto && liveVideoFile != null) {
          final videoName = await asset.titleAsyncWithSubtype;
          var req = http.StreamedRequest(
              "POST",
              storageHttpUri(['live', videoName],
                  baseUrl: uploadBaseUrl));
          req.headers['Image-Date'] = dateStr;
          req.headers['Image-Is-Live-Photo'] =
              asset.isLivePhoto ? "true" : "false";
          if (settingModel.enableEncrypt) {
            req.headers['Image-Encrypt-Type'] =
                encryptionTypeName(settingModel.encryptionType);
            req.headers['Image-Encrypt-Password'] =
                settingModel.encryptionPassword;
          }
          req.contentLength = await liveVideoFile.length();
          liveVideoFile.openRead().listen((chunk) {
            uploaded += chunk.length;
            stateModel.updateUploadProgress(
                asset.id, uploaded + thumbLen, totalLen);
            req.sink.add(chunk);
          }, onDone: () {
            req.sink.close();
          }, onError: (e) {
            req.sink.close();
            throw Exception("file read error: $e");
          });
          final response = await req.send();
          if (response.statusCode != 200) {
            final body = await response.stream.bytesToString();
            throw Exception("upload failed: [${response.statusCode}] $body");
          }
        }
        stateModel.finishUpload(asset.id, true);
        succeeded = true;
      } catch (e) {
        stateModel.finishUpload(asset.id, false);
        retryCount++;
        if (retryCount >= maxRetries) {
          logger.addLog("upload $name failed: $e");
          rethrow;
        }
        // 退避 + 抖动后再重试，避免失败后立即 hammering server。
        await Future.delayed(uploadRetryDelay(retryCount));
      } finally {
        if (shouldDeleteLocalFileAfterUpload(
            isIOS: Platform.isIOS, uploadSucceeded: succeeded)) {
          Future.delayed(const Duration(milliseconds: 200), () {
            try {
              file.deleteSync();
              liveVideoFile?.deleteSync();
            } catch (e) {
              logger.addLog("delete file failed: $e");
            }
          });
        }
      }
    }
  }

  // @protected
  // Stream<UploadRequest> uploadStream(Stream<List<int>> dataReader,
  //     Stream<Uint8List> thumbnailReader, String name, date) async* {
  //   yield UploadRequest(name: name, date: date);
  //   await for (var data in dataReader) {
  //     yield UploadRequest(data: data);
  //   }
  //   await for (var data in thumbnailReader) {
  //     yield UploadRequest(thumbnailData: data);
  //   }
  // }

  Future<List<RemoteImage>> listImages(
      String date, int offset, maxReturn) async {
    final rsp = await cli
        .listByDate(
          ListByDateRequest(
            date: date,
            offset: offset,
            maxReturn: maxReturn,
          ),
        )
        .timeout(const Duration(seconds: 60));
    if (!rsp.success) {
      throw Exception("list images failed: ${rsp.message}");
    }
    return rsp.infos
        .map((e) => RemoteImage(cli, e.path.replaceAll('\\', '/'),
            size: e.size.toInt(),
            isLivePhoto: e.isLivePhoto,
            httpClient: httpClient))
        .toList();
  }
}

class RemoteImage {
  ImgSyncerClient cli;
  String path;
  int? size;
  Uint8List? data;
  Uint8List? thumbnailData;
  bool isLivePhoto = false;
  /// 共享 HTTP 客户端，复用连接减少 TCP 握手开销
  late http.Client httpClient;

  RemoteImage(
    this.cli,
    this.path, {
    this.data,
    this.thumbnailData,
    this.size,
    this.isLivePhoto = false,
    required this.httpClient,
  });

  bool isVideo() {
    return isVideoByPath(path);
  }

  Stream<Uint8List> thumbnailStream() async* {
    await checkServer();
    final String streamBaseUrl = httpBaseUrl;
    var urlPath = path;
    if (urlPath.startsWith('/')) {
      urlPath = urlPath.substring(1);
    }
    // 远端路径含日期目录：按 '/' 切段后逐段编码，文件名里的 #/? 不截断 URL。
    final url = storageHttpUri(
        ['thumbnail', ...urlPath.split('/')],
        baseUrl: streamBaseUrl);
    final request = http.Request('GET', url);
    if (settingModel.enableEncrypt) {
      request.headers['Image-Encrypt-Type'] =
          encryptionTypeName(settingModel.encryptionType);
      request.headers['Image-Encrypt-Password'] =
          settingModel.encryptionPassword;
    }
    final response = await httpClient.send(request);
    if (response.statusCode != 200) {
      final errMsg = await response.stream.bytesToString();
      throw Exception(
          "get [$urlPath] thumbnail failed: [${response.reasonPhrase}] $errMsg");
    }
    await for (var data in response.stream) {
      yield data as Uint8List;
    }
  }

  Future<Uint8List?> thumbnail() async {
    if (thumbnailData != null) {
      return thumbnailData;
    }
    int maxRetries = 3;
    int retryCount = 0;
    while (retryCount < maxRetries) {
      try {
        var currentData = BytesBuilder();
        var dataStream = thumbnailStream();
        await for (var d in dataStream) {
          currentData.add(d);
        }
        final bytes = currentData.takeBytes();
        if (bytes.isEmpty) {
          throw Exception("empty thumbnail");
        }
        thumbnailData = bytes;
        return bytes;
      } catch (e) {
        logger.addLog("get $path thumbnail failed: $e");
        retryCount++;
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }
    // 失败不写入缓存，交给调用方重试（issue #89）
    return null;
  }

  Stream<Uint8List> dataStream({
    bool reportProgress = true,
    void Function(int downloaded, int total)? onProgress,
  }) async* {
    await checkServer();
    final String streamBaseUrl = httpBaseUrl;
    if (path.startsWith('/')) {
      path = path.substring(1);
    }
    final url = storageHttpUri(path.split('/'), baseUrl: streamBaseUrl);
    final request = http.Request('GET', url);
    if (settingModel.enableEncrypt) {
      request.headers['Image-Encrypt-Type'] =
          encryptionTypeName(settingModel.encryptionType);
      request.headers['Image-Encrypt-Password'] =
          settingModel.encryptionPassword;
    }
    final response = await httpClient.send(request);
    if (response.statusCode != 200) {
      throw Exception("get image failed: ${response.statusCode}");
    }
    final total = response.contentLength ?? -1;
    if (reportProgress) {
      stateModel.updateDownloadProgress(basename(path), 1, total);
    }
    if (onProgress != null) {
      onProgress(1, total);
    }
    int downloaded = 0;
    await for (var data in response.stream) {
      downloaded += data.length;
      if (reportProgress) {
        stateModel.updateDownloadProgress(basename(path), downloaded, total);
      }
      if (onProgress != null) {
        onProgress(downloaded, total);
      }
      yield data as Uint8List;
    }
    if (reportProgress) {
      stateModel.finishDownload(basename(path), true);
    }
    if (onProgress != null) {
      onProgress(downloaded, total);
    }
  }

  Future<Uint8List> imageData({
    bool reportProgress = true,
    void Function(int downloaded, int total)? onProgress,
  }) async {
    if (data != null) {
      return data!;
    }
    var currentData = BytesBuilder();
    var stream = dataStream(
      reportProgress: reportProgress,
      onProgress: onProgress,
    );
    await for (var d in stream) {
      currentData.add(d);
    }
    data = currentData.takeBytes();
    return data!;
  }
}
