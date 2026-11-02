import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:img_syncer/asset.dart';
import 'package:img_syncer/logger/logger.dart';
import 'package:img_syncer/state_model.dart';
import 'package:img_syncer/sync/background_runner.dart';
import 'package:img_syncer/util.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:img_syncer/storage/storage.dart';
import 'package:img_syncer/design_tokens.dart';
import 'package:url_launcher/url_launcher.dart';
import 'event_bus.dart';
import 'package:extended_image/extended_image.dart';
import 'package:img_syncer/video_route.dart';
import 'package:img_syncer/global.dart';
import 'package:path_provider/path_provider.dart';
import 'package:gal/gal.dart';
import 'package:video_player/video_player.dart';

class GalleryViewerRoute extends StatefulWidget {
  const GalleryViewerRoute({
    Key? key,
    required this.useLocal,
    required this.originIndex,
  }) : super(key: key);
  final bool useLocal;
  final int originIndex;

  @override
  GalleryViewerRouteState createState() => GalleryViewerRouteState();
}

class GalleryViewerRouteState extends State<GalleryViewerRoute>
    with TickerProviderStateMixin {
  // late final PageController _pageController;
  late final ExtendedPageController _pageController;
  late AnimationController _animationController;
  bool showLivePhotoVideo = false;
  bool showLoading = false;
  VideoPlayerController? _videoController;
  late List<Asset> all;
  late int currentIndex;
  bool showAppBar = true;
  bool poped = false;
  VoidCallback? _doubleTapListener;
  late final AssetModel _assetModel;

  /// Recompute [all] from the model and clamp [currentIndex].
  /// Returns true when the index had to move (the page controller
  /// must be jumped to match). Called on every model change and at
  /// the start of [build]: the list is recomputed on every access
  /// elsewhere, so a snapshot taken in initState goes stale as soon
  /// as camera-excluded assets refresh or assets are added/removed
  /// (camera-excluded assets must not stay viewable).
  bool _syncAllWithModel() {
    all = widget.useLocal
        ? _assetModel.displayLocalAssets
        : _assetModel.remoteAssets;
    final clamped = all.isEmpty ? 0 : currentIndex.clamp(0, all.length - 1);
    if (clamped != currentIndex) {
      currentIndex = clamped;
      return true;
    }
    return false;
  }

  /// The asset at [index] in the current list, or null when the
  /// index is out of bounds (empty list / shrunk list). Every
  /// indexed access in this route must go through here.
  Asset? _assetAt(int index) =>
      (index >= 0 && index < all.length) ? all[index] : null;

  Asset? get _currentAsset => _assetAt(currentIndex);

  void _onAssetModelChange() {
    if (mounted) {
      final indexChanged = _syncAllWithModel();
      if (indexChanged && _pageController.hasClients) {
        _pageController.jumpToPage(currentIndex);
      }
      setState(() {});
    }
  }

  void _onAnimationTick() {
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _assetModel = context.read<AssetModel>();
    currentIndex = widget.originIndex;
    _pageController = ExtendedPageController(
      initialPage: widget.originIndex,
      keepPage: true,
    );
    all = widget.useLocal
        ? _assetModel.displayLocalAssets
        : _assetModel.remoteAssets;
    // 延迟加载全分辨率数据，避免 Hero 动画期间 HTTP 下载抢占主 isolate 事件循环
    // 延迟 400ms 确保 300ms 的 FadeTransition 动画完成后再启动下载
    Future.delayed(const Duration(milliseconds: 400), () {
      if (mounted) {
        _syncAllWithModel();
        _currentAsset?.readInfoFromData();
      }
    });
    _assetModel.addListener(_onAssetModelChange);
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 100), // 你可以调整动画时间
    );
    _animationController.addListener(_onAnimationTick);
  }

  @override
  void didUpdateWidget(covariant GalleryViewerRoute oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.useLocal != widget.useLocal ||
        oldWidget.originIndex != widget.originIndex) {
      currentIndex = widget.originIndex;
      _syncAllWithModel();
    }
  }

  @override
  void dispose() {
    // The live-photo video controller was never disposed here: every
    // long-press that created one leaked its native player.
    _videoController?.dispose();
    _videoController = null;
    _assetModel.removeListener(_onAssetModelChange);
    _animationController.removeListener(_onAnimationTick);
    if (_doubleTapListener != null) {
      _animationController.removeListener(_doubleTapListener!);
      _doubleTapListener = null;
    }
    _animationController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  bool _isShowingImageInfo = false;
  void showImageInfo(BuildContext context) {
    final currentAsset = _currentAsset;
    if (currentAsset == null) {
      return;
    }
    if (!currentAsset.isInfoReady()) {
      return;
    }
    if (_isShowingImageInfo) {
      return;
    }
    _isShowingImageInfo = true;
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(AppRadius.extraLarge)),
      ),
      clipBehavior: Clip.antiAliasWithSaveLayer,
      builder: (BuildContext context) {
        final theme = Theme.of(context);
        final colorScheme = theme.colorScheme;
        final textTheme = theme.textTheme;
        List<Widget> columns = [];
        columns.add(
          // 抓手
          Container(
            margin: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 0),
            height: 4.0,
            width: 40.0,
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(2.0),
            ),
          ),
        );
        if (currentAsset.date != null) {
          columns.add(ListTile(
              leading: SizedBox(
                width: 40, // 设置宽度
                child: Align(
                  alignment: Alignment.center,
                  child: Icon(
                    Icons.calendar_today_outlined,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              title: Text("Date", style: textTheme.titleMedium),
              subtitle: Text(
                currentAsset.date!,
                style: textTheme.bodyMedium
                    ?.copyWith(color: colorScheme.onSurfaceVariant),
              )));
        }
        if (currentAsset.make != null && currentAsset.model != null) {
          List<String> children = [
            if (currentAsset.fNumber != null) "f/${currentAsset.fNumber}",
            if (currentAsset.exposureTime != null) currentAsset.exposureTime!,
            if (currentAsset.focalLength != null)
              "${currentAsset.focalLength}mm",
            if (currentAsset.iSO != null) "ISO${currentAsset.iSO}",
          ];
          columns.add(
            ListTile(
              leading: SizedBox(
                width: 40, // 设置宽度
                child: Align(
                  alignment: Alignment.center,
                  child: Icon(
                    Icons.camera_outlined,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              title: Text("${currentAsset.make} ${currentAsset.model}",
                  style: textTheme.titleMedium),
              subtitle: Text(
                children.join("  \u2022  "),
                style: textTheme.bodyMedium
                    ?.copyWith(color: colorScheme.onSurfaceVariant),
              ),
            ),
          );
        }
        columns.add(ListTile(
          leading: SizedBox(
            width: 40, // 设置宽度
            child: Align(
              alignment: Alignment.center,
              child: Icon(
                currentAsset.isVideo()
                    ? Icons.movie
                    : Icons.photo_size_select_actual_outlined,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          title: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: FutureBuilder(
              future: currentAsset.name(),
              builder: (context, snapshot) =>
                  Text(snapshot.data ?? "", style: textTheme.titleMedium),
            ),
          ),
          subtitle: currentAsset.isVideo()
              ? null
              : RichText(
                  text: TextSpan(
                    style: textTheme.bodyMedium
                        ?.copyWith(color: colorScheme.onSurfaceVariant),
                    children: [
                      TextSpan(
                        text: currentAsset.imageWidth != null &&
                                currentAsset.imageHeight != null
                            ? "${(currentAsset.imageWidth! * currentAsset.imageHeight! / 1024 / 1024).floor()} MP"
                            : null,
                      ),
                      TextSpan(
                          text: currentAsset.imageWidth != null
                              ? "  \u2022  ${currentAsset.imageWidth!}x${currentAsset.imageHeight!}"
                              : null),
                    ],
                  ),
                ),
        ));

        columns.add(ListTile(
          leading: SizedBox(
            width: 40, // 设置宽度
            child: Align(
              alignment: Alignment.center,
              child: Icon(
                currentAsset.hasLocal
                    ? Icons.phone_android
                    : Icons.cloud_outlined,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          title: currentAsset.isLocal()
              ? Text("Local", style: textTheme.titleMedium)
              : Text("Cloud", style: textTheme.titleMedium),
          subtitle: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: FutureBuilder(
              future: Future.wait([
                currentAsset.path(),
                currentAsset.size(),
              ]),
              builder: (context, snapshot) => snapshot.data == null
                  ? Container()
                  : RichText(
                      text: TextSpan(
                        style: textTheme.bodyMedium
                            ?.copyWith(color: colorScheme.onSurfaceVariant),
                        children: [
                          TextSpan(
                              text:
                                  "${(snapshot.data![1] as double).toStringAsFixed(1)} MB"),
                          if (currentAsset.hasRemote || Platform.isAndroid) ...[
                            const TextSpan(text: "  \u2022  "),
                            TextSpan(text: snapshot.data![0] as String? ?? ""),
                          ]
                        ],
                      ),
                    ),
            ),
          ),
        ));
        if (Platform.isIOS) columns.add(const SizedBox(height: 20));
        return IntrinsicHeight(
          child: Column(
            children: columns,
          ),
        );
      },
    ).then((value) => _isShowingImageInfo = false);
  }

  void deleteCurrent(BuildContext context) {
    // Capture the asset now: currentIndex is meaningless once the
    // list refreshes or the delete completes.
    final asset = _currentAsset;
    if (asset == null) return;
    showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text(l10n.deleteThisPhoto),
        content: Text(l10n.cantBeUndone),
        actions: <Widget>[
          TextButton(
            onPressed: () async {
              // A failed delete previously left this dialog stuck
              // open forever: delete() throwing skipped the .then()
              // that popped it, with no error shown.
              try {
                await asset.delete();
                if (asset.hasLocal) {
                  _assetModel.removeLocalAsset(asset);
                } else {
                  _assetModel.removeRemoteAsset(asset);
                  final id = await findLocalIDByAsset(asset);
                  if (id != null) {
                    stateModel.removeSyncedPhotos([id]);
                    await stateModel.saveSyncedIDs();
                  }
                }
                if (dialogContext.mounted) {
                  Navigator.of(dialogContext).pop();
                }
                if (mounted) {
                  Navigator.of(context).pop();
                }
              } catch (e) {
                SnackBarManager.showSnackBar(e.toString());
                if (dialogContext.mounted) {
                  Navigator.of(dialogContext).pop();
                }
              }
            },
            child: Text(l10n.yes),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.cancel),
          ),
        ],
      ),
    );
  }

  void download(Asset asset) async {
    if (asset.isLocal()) {
      return;
    }
    await keepScreenOn(true);
    final name = await asset.originName();
    try {
      Uint8List data;
      if (!asset.isVideo()) {
        data = await asset.imageDataAsync(reportProgress: true);
      } else {
        data = await asset.remote!.imageData();
      }
      if (Platform.isAndroid) {
        String absPath = '${settingModel.localFolderAbsPath}/$name';
        final file = File(absPath);
        if (file.existsSync()) {
          throw Exception("$name already exists, skip download.");
        }
        await file.writeAsBytes(data);
        await file.setLastModified(asset.dateCreated());
        await scanFile(absPath);
        SnackBarManager.showSnackBar("${l10n.download} $name ${l10n.success}");
      } else if (Platform.isIOS) {
        var appDocDir = await getTemporaryDirectory();
        String savePath = "${appDocDir.path}/$name";
        final file = File(savePath);
        // if (file.existsSync()) {
        //   throw Exception("$name already exists, skip download.");
        // }
        await file.writeAsBytes(data);
        await file.setLastModified(asset.dateCreated());
        if (asset.isVideo()) {
          await Gal.putVideo(savePath);
        } else {
          await Gal.putImage(savePath);
        }
        SnackBarManager.showSnackBar(
            "${l10n.download} $name ${l10n.success}\n${l10n.browseInRecents}");
      } else if (isDesktop()) {
        String? outputFile = await FilePicker.platform.saveFile(
          dialogTitle: 'Please select an output file:',
          fileName: name,
        );
        if (outputFile == null) {
          return;
        }
        final file = File(outputFile);
        await file.writeAsBytes(data);
        SnackBarManager.showSnackBar("${l10n.download} $name ${l10n.success}");
      }
      eventBus.fire(LocalRefreshEvent(refreshUnSync: false));
    } catch (e) {
      SnackBarManager.showSnackBar(e.toString());
    } finally {
      keepScreenOn(false);
    }
  }

  void upload(Asset asset) async {
    if (!asset.isLocal()) {
      return;
    }

    if (!settingModel.isRemoteStorageSetted) {
      SnackBarManager.showSnackBar(
          "Remote storage is not setted,please set it first");
      return;
    }
    final entity = asset.local;
    if (entity == null) {
      SnackBarManager.showSnackBar("Asset local is null, unable to upload");
      return;
    }
    // 手动上传同样过同步筛选（FK-6）：被筛选排除/已上传的不上传。
    if (!await shouldUploadManually(
        asset, {for (final id in stateModel.syncedIDs) id: true})) {
      SnackBarManager.showSnackBar(l10n.skippedByUploadFilter);
      return;
    }
    await keepScreenOn(true);
    try {
      await storage.uploadAssetEntity(entity);
      if (mounted) {
        SnackBarManager.showSnackBar(
            "${l10n.upload} ${await asset.name()} ${l10n.success}");
      }
      eventBus.fire(RemoteRefreshEvent(refreshUnSync: false));
      // syncedIDs 已由 uploadAssetEntity 内部的 finishUpload 处理，不需要重复添加
    } catch (e) {
      logger.addLog(e.toString());
      SnackBarManager.showSnackBar(e.toString());
    } finally {
      keepScreenOn(false);
    }
  }

  Widget livePhotoVideoPlayer(Asset asset) {
    final controller = _videoController;
    if (controller == null) {
      return Container();
    }
    late double aspectRatio;
    if (asset.imageWidth == null ||
        asset.imageHeight == null ||
        asset.imageWidth! <= 0 ||
        asset.imageHeight! <= 0) {
      aspectRatio = controller.value.aspectRatio;
    } else {
      aspectRatio = asset.imageWidth! / asset.imageHeight!;
    }
    return Center(
      child: AspectRatio(
        aspectRatio: aspectRatio, // 指定你想要的宽高比
        child: ClipRect(
          child: FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: controller.value.size.width,
              height: controller.value.size.height,
              child: VideoPlayer(controller),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // Recompute on every build: the model may have changed since
    // initState (refresh, camera-only toggle, deletion elsewhere).
    final indexChanged = _syncAllWithModel();
    if (indexChanged && _pageController.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && all.isNotEmpty && _pageController.hasClients) {
          _pageController.jumpToPage(currentIndex);
        }
      });
    }
    final currentAsset = _currentAsset;
    if (currentAsset == null) {
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: colorScheme.scrim.withOpacity(0.25),
          elevation: 0,
          iconTheme: const IconThemeData(color: Colors.white),
        ),
        body: Center(
          child: Text(
            widget.useLocal ? l10n.noLocalPhotos : l10n.noCloudPhotos,
            style: const TextStyle(color: Colors.white),
          ),
        ),
      );
    }
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Colors.black,
      appBar: showAppBar
          ? AppBar(
              backgroundColor: colorScheme.scrim.withOpacity(0.25),
              elevation: 0,
              iconTheme: const IconThemeData(color: Colors.white),
              actions: [
                if (currentAsset.isLivePhoto())
                  IconButton(
                    icon: SizedBox(
                      height: 23,
                      width: 23,
                      child: Image.asset("assets/icon/live_photos.png"),
                    ),
                    onPressed: null,
                  ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => deleteCurrent(context),
                ),
                if (!isDesktop())
                  IconButton(
                    icon: const Icon(Icons.share_outlined),
                    onPressed: () async {
                      // Capture the asset now; re-reading
                      // all[currentIndex] after the awaits could
                      // share a different asset.
                      final asset = _currentAsset;
                      if (asset == null) return;
                      try {
                        final tempFilePath =
                            await asset.downloadToTmpFilePath();
                        Share.shareXFiles([
                          XFile(tempFilePath,
                              name: await asset.originName(),
                              mimeType: await asset.mimeType())
                        ]);
                      } catch (e) {
                        SnackBarManager.showSnackBar("Share failed: $e");
                      }
                    },
                  ),
                if (!currentAsset.isLocal())
                  Consumer<StateModel>(builder: (context, model, child) {
                    return IconButton(
                      icon: const Icon(Icons.cloud_download_outlined),
                      onPressed: () =>
                          model.isDownloading() || model.isUploading()
                              ? null
                              : download(currentAsset),
                    );
                  }),
                if (currentAsset.isLocal())
                  Consumer<StateModel>(builder: (context, stateModel, child) {
                    final asset = currentAsset;
                    final localId = asset.local?.id;
                    final isSynced = localId != null &&
                        stateModel.syncedIDs.isNotEmpty &&
                        stateModel.syncedIDs.contains(localId);
                    final isBusy =
                        stateModel.isDownloading() || stateModel.isUploading();
                    return IconButton(
                      icon: isSynced
                          ? const Icon(Icons.cloud_done_outlined,
                              color: Color.fromARGB(255, 90, 252, 101))
                          : const Icon(Icons.cloud_upload_outlined),
                      // 已上传或传输中时禁用按钮
                      onPressed:
                          isSynced || isBusy ? null : () => upload(asset),
                    );
                  }),
                IconButton(
                  icon: const Icon(Icons.info_outline),
                  onPressed: () {
                    currentAsset.imageDataAsync().then(
                          (value) => showImageInfo(context),
                        );
                  },
                ),
              ],
            )
          : null,
      body: Hero(
        tag: "asset_${currentAsset.stableKey()}",
        flightShuttleBuilder: (BuildContext flightContext,
            Animation<double> animation,
            HeroFlightDirection flightDirection,
            BuildContext fromHeroContext,
            BuildContext toHeroContext) {
          // 自定义过渡动画小部件
          return AnimatedBuilder(
            animation: animation,
            builder: (BuildContext context, Widget? child) {
              return Opacity(
                opacity: animation.value,
                child: ExtendedImage(
                  image: currentAsset.thumbnailProvider(),
                  fit: BoxFit.contain,
                ),
              );
            },
          );
        },
        child: Container(
          constraints: BoxConstraints.expand(
            height: MediaQuery.of(context).size.height,
          ),
          child: Stack(
            children: [
              ExtendedImageGesturePageView.builder(
                itemCount: all.length,
                controller: _pageController,
                onPageChanged: (int index) {
                  final asset = _assetAt(index);
                  if (asset == null) return;
                  setState(() {
                    currentIndex = index;
                  });
                  asset.readInfoFromData().then((value) {
                    if (!mounted) return;
                    // Re-check bounds: the list may have shrunk
                    // while the info load was in flight.
                    if (index + 1 >= 0 && index + 1 < all.length) {
                      all[index + 1].thumbnailDataAsync();
                      all[index + 1].imageDataAsync();
                    }
                    if (index - 1 >= 0 && index - 1 < all.length) {
                      all[index - 1].thumbnailDataAsync();
                      all[index - 1].imageDataAsync();
                    }
                  });
                },
                itemBuilder: (BuildContext context, int index) {
                  final asset = _assetAt(index);
                  if (asset == null) {
                    return const SizedBox.shrink();
                  }
                  return Stack(
                    alignment: Alignment.center,
                    fit: StackFit.expand,
                    children: [
                      ExtendedImage(
                        image: asset,
                        fit: BoxFit.contain,
                        mode: ExtendedImageMode.gesture,
                        initGestureConfigHandler: (state) {
                          return GestureConfig(
                            minScale: 1.0,
                            maxScale: 3.0,
                            inPageView: true,
                            gestureDetailsIsChanged: (details) {
                              if (details == null) {
                                return;
                              }
                              final offset = details.offset;
                              if (offset == null) {
                                return;
                              }
                              // 如果是下拉手势则弹出ImageInfo
                              if (details.totalScale == 1.0 &&
                                  offset.dy < -100) {
                                showImageInfo(context);
                              }
                              // 如果是上拉手势则返回
                              if (details.totalScale == 1.0 &&
                                  offset.dy > 100) {
                                if (!poped) {
                                  poped = true;
                                  Navigator.pop(context);
                                }
                              }
                            },
                          );
                        },
                        loadStateChanged: (ExtendedImageState state) {
                          switch (state.extendedImageLoadState) {
                            case LoadState.loading:
                              return ExtendedImage(
                                image: asset.thumbnailProvider(),
                                fit: BoxFit.contain,
                              );
                            case LoadState.completed:
                              return null; // Use the high-resolution image.
                            case LoadState.failed:
                              asset.name().then((n) {
                                if (!context.mounted) return;
                                if (n.toLowerCase().contains(".heic") ||
                                    n.toLowerCase().contains(".hevc")) {
                                  if (Platform.isWindows) {
                                    // Use this item's own BuildContext:
                                    // SnackBarManager.globalContext may be
                                    // null (never initialised) or stale,
                                    // and force-unwrapping it crashes.
                                    showDialog(
                                        context: context,
                                        builder: (context) {
                                          return AlertDialog(
                                            title: Text("HEVC Extention"),
                                            content:
                                                Text(l10n.installHEVCExtention),
                                            actions: [
                                              TextButton(
                                                onPressed: () {
                                                  Navigator.of(context).pop();
                                                },
                                                child: Text(l10n.cancel),
                                              ),
                                              TextButton(
                                                onPressed: () {
                                                  Navigator.of(context).pop();
                                                  Navigator.of(context).pop();
                                                  final Uri ExtUrl = Uri.parse(
                                                      'https://apps.microsoft.com/detail/9NMZLZ57R3T7');
                                                  launchUrl(ExtUrl,
                                                      mode: LaunchMode
                                                          .externalApplication);
                                                },
                                                child: Text(l10n.openMSStore),
                                              ),
                                            ],
                                          );
                                        });
                                  }
                                }
                              });
                              return null;
                            default:
                              return null;
                          }
                        },
                        onDoubleTap: (ExtendedImageGestureState state) {
                          if (state.gestureDetails != null &&
                              state.gestureDetails!.totalScale != null) {
                            double begin = state.gestureDetails!.totalScale!;
                            double end =
                                state.gestureDetails!.totalScale! >= 2.0
                                    ? 1.0
                                    : 2.0;
                            _animationController.reset();
                            if (_doubleTapListener != null) {
                              _animationController
                                  .removeListener(_doubleTapListener!);
                            }
                            _doubleTapListener = () {
                              double animationScale =
                                  (end - begin) * _animationController.value;
                              state.handleDoubleTap(
                                  scale: begin + animationScale);
                            };
                            _animationController
                                .addListener(_doubleTapListener!);
                            _animationController.forward();
                          }
                        },
                      ),
                      if (asset.isVideo())
                        const Icon(
                          Icons.play_circle_outline,
                          color: Colors.white,
                          size: 60,
                        ),
                      GestureDetector(
                        onTap: () async {
                          if (asset.isVideo()) {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (context) => VideoRoute(
                                  asset: asset,
                                ),
                              ),
                            );
                          } else {
                            setState(() {
                              showAppBar = !showAppBar;
                            });
                          }
                        },
                        onLongPress: () async {
                          if (!asset.isLivePhoto()) {
                            return;
                          }
                          // Dispose any previous controller first:
                          // a second long-press without an
                          // onLongPressEnd would otherwise leak it.
                          await _videoController?.dispose();
                          _videoController = null;
                          final controller =
                              await asset.getLivePhotoVideoController();
                          if (!mounted) {
                            await controller?.dispose();
                            return;
                          }
                          if (controller == null) {
                            return;
                          }
                          _videoController = controller;
                          try {
                            await controller.initialize();
                            HapticFeedback.lightImpact();
                            await controller.play();
                            if (!mounted) return;
                            setState(() {
                              showLivePhotoVideo = true;
                            });
                          } catch (e) {
                            SnackBarManager.showSnackBar(
                                "Play live photo failed: $e");
                          }
                        },
                        onLongPressEnd: (details) {
                          setState(() {
                            showLivePhotoVideo = false;
                          });
                          final controller = _videoController;
                          _videoController = null;
                          controller?.pause();
                          controller?.dispose();
                        },
                      ),
                      Positioned(
                          top: MediaQuery.of(context).padding.top,
                          left: 0,
                          width: MediaQuery.of(context).size.width,
                          child: ValueListenableBuilder<double>(
                            valueListenable: asset.imageLoadProgress,
                            builder: (context, progress, child) {
                              if (progress > 0 && progress < 1) {
                                return LinearProgressIndicator(
                                  value: progress,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .primary
                                      .withOpacity(0.7),
                                  backgroundColor: Colors.transparent,
                                );
                              }
                              return Container();
                            },
                          )),
                      Center(
                        child: Consumer<StateModel>(
                          builder: (context, model, child) {
                            double percent = 0;
                            final viewed = _assetAt(currentIndex);
                            final viewedLocalId = viewed?.local?.id;
                            if (viewed != null &&
                                viewed.isLocal() &&
                                viewedLocalId != null) {
                              percent =
                                  model.getUploadPercent(viewedLocalId);
                            }
                            if (percent > 0) {
                              return SizedBox(
                                width: 45,
                                height: 45,
                                child: CircularProgressIndicator(
                                  value: percent,
                                  strokeWidth: 6,
                                  backgroundColor: Colors.transparent,
                                ),
                              );
                            }
                            return Container();
                          },
                        ),
                      ),
                      if (showLoading)
                        const Center(
                          child: CircularProgressIndicator(),
                        ),
                      if (showLivePhotoVideo && _videoController != null)
                        livePhotoVideoPlayer(currentAsset),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
