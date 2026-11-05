import 'package:img_syncer/storage/storage.dart';
import 'package:photo_manager/photo_manager.dart';

/// “文件”页签的数据源抽象：目录列表、建目录、精确目录上传。
/// 默认实现走全局 [storage]；widget 测试注入 fake，避免
/// FilesBody 直接依赖全局单例而无法在测试里替换。
abstract class FilesDataSource {
  Future<List<DirEntry>> listDir(String dir);
  Future<void> createDir(String dir);
  Future<void> uploadToExactDir(AssetEntity asset, String dir);
}

/// 默认数据源：直接委托给全局 [storage] 的新方法
/// （listDirEntries / createDir / uploadAssetEntityToExactDir）。
class StorageFilesDataSource implements FilesDataSource {
  const StorageFilesDataSource();
  @override
  Future<List<DirEntry>> listDir(String dir) => storage.listDirEntries(dir);

  @override
  Future<void> createDir(String dir) => storage.createDir(dir);

  @override
  Future<void> uploadToExactDir(AssetEntity asset, String dir) =>
      storage.uploadAssetEntityToExactDir(asset, dir);
}
