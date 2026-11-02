import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:img_syncer/design_tokens.dart';
import 'package:img_syncer/event_bus.dart';
import 'package:photo_manager/photo_manager.dart';
import 'state_model.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:img_syncer/global.dart';
import 'package:img_syncer/widgets/thumbnail_skeleton.dart';
import 'package:flutter/services.dart';

class ChooseAlbumRoute extends StatefulWidget {
  const ChooseAlbumRoute({Key? key}) : super(key: key);
  @override
  ChooseAlbumRouteState createState() => ChooseAlbumRouteState();
}

class ChooseAlbumRouteState extends State<ChooseAlbumRoute> {
  List<AssetPathEntity> albums = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final value = await getAlbums();
        if (!mounted) return;
        setState(() {
          albums = value;
        });
      } catch (e) {
        // getAlbums() itself is guarded to return [] on failure;
        // this only covers failures in the post-frame plumbing.
        if (!mounted) return;
        setState(() {
          albums = [];
        });
      }
    });
  }

  Future<List<AssetPathEntity>> getAlbums() async {
    try {
      final re = await requestPermission();
      if (!re) return [];
      final List<AssetPathEntity> paths = await PhotoManager.getAssetPathList(
          type: RequestType.common, hasAll: true);
      // sort by asset count by assetCountAsync
      // 使用Future.wait来获取所有异步值并保存到Map中
      final Map<AssetPathEntity, int> assetCountMap = {};
      // 一个相册的 assetCountAsync 抛错时只记 0 分：此前
      // Future.wait 会整体失败，导致全部相册都不显示。
      await Future.wait(paths.map((path) async {
        try {
          int assetCount = await path.assetCountAsync;
          assetCountMap[path] = assetCount;
        } catch (e) {
          assetCountMap[path] = 0;
        }
      }));

      // 使用sort方法对paths进行排序：数量从大到小；数量相同
      // 时按相册名排序，使同数量相册的顺序确定（此前仅按数量
      // 排序，相等时顺序不确定）。
      paths.sort((a, b) {
        int countA = assetCountMap[a] ?? 0;
        int countB = assetCountMap[b] ?? 0;
        final byCount = countB.compareTo(countA);
        if (byCount != 0) return byCount;
        return a.name.compareTo(b.name);
      });
      return paths;
    } catch (e) {
      return [];
    }
  }

  Future<Uint8List?> getFirstPhotoThumbnail(AssetPathEntity path) async {
    try {
      final List<AssetEntity> entities =
          await path.getAssetListPaged(page: 0, size: 1);
      if (entities.isNotEmpty) {
        final entity = entities[0];
        final data = await entity
            .thumbnailDataWithSize(const ThumbnailSize.square(400), quality: 90);
        return data;
      }
    } catch (e) {
      print("[ChooseAlbum] getFirstPhotoThumbnail 失败: $e");
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    var children = <Widget>[];
    for (var path in albums) {
      children.add(
        FutureBuilder(
          future: getFirstPhotoThumbnail(path),
          builder: (context, snapshot) {
            return AlbumCard(
              path: path,
              thumbnail: snapshot.data,
            );
          },
        ),
      );
    }
    return Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        appBar: AppBar(
          backgroundColor: Theme.of(context).appBarTheme.backgroundColor,
          iconTheme: Theme.of(context).iconTheme,
          elevation: 0,
          title: Text(l10n.chooseAlbum,
              style: Theme.of(context).textTheme.titleLarge),
        ),
        body: CustomScrollView(
          primary: false,
          slivers: <Widget>[
            SliverPadding(
              padding: const EdgeInsets.all(AppSpacing.sm),
              sliver: SliverGrid.count(
                crossAxisSpacing: AppSpacing.sm,
                mainAxisSpacing: AppSpacing.sm,
                crossAxisCount: 2,
                childAspectRatio: 0.75,
                children: children,
              ),
            ),
          ],
        ));
  }
}

class AlbumCard extends StatelessWidget {
  final AssetPathEntity path;
  final Uint8List? thumbnail;
  const AlbumCard({
    Key? key,
    required this.path,
    required this.thumbnail,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (context, constraints) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                  width: constraints.maxWidth,
                  height: constraints.maxHeight - 80,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(AppRadius.extraSmall),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: thumbnail != null
                      ? Image.memory(thumbnail!, fit: BoxFit.cover)
                      : ThumbnailSkeleton()),
              Container(
                  alignment: Alignment.centerLeft,
                  height: 40,
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.only(left: AppSpacing.sm),
                        child: Text(
                            path.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context)
                                .textTheme
                                .bodyLarge),
                      ),
                    ],
                  )),
              Container(
                alignment: Alignment.centerRight,
                height: 40,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Container(
                        alignment: Alignment.centerLeft,
                        padding: const EdgeInsets.only(left: AppSpacing.sm),
                        child: FutureBuilder(
                          future: path.assetCountAsync,
                          builder: (context, snapshot) => Badge(
                            label: Text("${snapshot.data ?? 0}"),
                            backgroundColor: Theme.of(context)
                                .colorScheme
                                .primary
                                .withAlpha(128),
                            textStyle: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ),
                    ),
                    Container(
                      alignment: Alignment.centerRight,
                      width: 120,
                      padding: const EdgeInsets.fromLTRB(0, AppSpacing.xs, AppSpacing.xs, AppSpacing.xs),
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          padding: const EdgeInsets.symmetric(
                              horizontal: AppSpacing.md,
                              vertical: AppSpacing.xs),
                        ),
                        onPressed: () {
                          stateModel.updateLastRefreshUnsyncTime(null);
                          settingModel.setLocalFolder(path.name);
                          SharedPreferences.getInstance().then((prefs) {
                            prefs.setString("localFolder", path.name);
                          });
                          eventBus.fire(LocalRefreshEvent(refreshUnSync: true));
                          Navigator.pop(context);
                        },
                        child: Text(l10n.choose),
                      ),
                    ),
                  ],
                ),
              )
            ],
          );
        },
      ),
    );
  }
}
