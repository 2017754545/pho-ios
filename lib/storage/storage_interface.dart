// ignore_for_file: deprecated_member_use
import 'dart:async';
import 'package:photo_manager/photo_manager.dart';
import 'package:img_syncer/proto/img_syncer.pbgrpc.dart';
import 'package:img_syncer/storage/storage.dart';

/// [RemoteStorage] 的抽象接口，用于单元测试 mock 注入。
abstract class RemoteStorageClient {
  ImgSyncerClient get cli;
  Future<void> uploadAssetEntity(AssetEntity asset);
  Future<List<RemoteImage>> listImages(String date, int offset, maxReturn);
}
