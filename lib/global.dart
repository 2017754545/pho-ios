import 'package:img_syncer/setting_storage_route.dart';
import 'package:img_syncer/proto/img_syncer.pbgrpc.dart';
import 'package:img_syncer/run_server.dart';
import 'package:img_syncer/sync_timer.dart';
import 'package:img_syncer/state_model.dart';
import 'package:img_syncer/storage/storage.dart';
import 'package:img_syncer/sync/manual_upload_folder.dart';
import 'package:img_syncer/sync/upload_filter.dart';
import 'package:img_syncer/util.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:img_syncer/logger/logger.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:flutter/material.dart';
import 'package:img_syncer/l10n/app_localizations.dart';
import 'dart:async';
import 'dart:io';

import 'event_bus.dart';

late String httpBaseUrl;
late int grpcPort;
late int httpPort;
bool useRemoteServer = false;
bool isDebug = false;

Color? seedColor;

/// 解析 runServer() 返回的端口号：非数字或超出 1–65535 时返回 null
///（此前 int.parse 直接抛错，会把 server 启动回调炸掉）。
int? _parseServerPort(String s) {
  final port = int.tryParse(s);
  if (port == null || port < 1 || port > 65535) return null;
  return port;
}

class Global {
  static Future init() async {
    assert(() {
      if (!Platform.isIOS) {
        isDebug = true;
      }
      return true;
    }());
    runServer().then((portsStr) async {
      final ports = portsStr.split(",");
      if (ports.length != 2) {
        logger.addLog("grpc server start failed");
        return;
      }
      httpBaseUrl = "http://127.0.0.1:${ports[1]}";
      final parsedGrpcPort = _parseServerPort(ports[0]);
      final parsedHttpPort = _parseServerPort(ports[1]);
      if (parsedGrpcPort == null || parsedHttpPort == null) {
        logger.addLog("grpc server start failed: bad ports '$portsStr'");
        return;
      }
      grpcPort = parsedGrpcPort;
      httpPort = parsedHttpPort;
      setGlobalStorage(RemoteStorage("127.0.0.1", parsedGrpcPort));
      if (useRemoteServer) {
        httpBaseUrl = "http://192.168.100.213:8000";
        setGlobalStorage(RemoteStorage("192.168.100.213", 50051));
      }

      final prefs = await SharedPreferences.getInstance();
      if (isDesktop()) {
        final galleryColumCount = prefs.getInt("galleryColumCount");
        if (galleryColumCount != null) {
          settingModel.setGalleryColumCount(galleryColumCount);
        } else {
          settingModel.setGalleryColumCount(10);
        }
        var enableEncrypt = prefs.getBool("enable_encrypt");
        // 从旧 key (enalble_encrypt) 迁移
        if (enableEncrypt == null) {
          enableEncrypt = prefs.getBool("enalble_encrypt");
          if (enableEncrypt != null) {
            prefs.setBool("enable_encrypt", enableEncrypt);
            prefs.remove("enalble_encrypt");
          }
        }
        if (enableEncrypt != null) {
          settingModel.setEncryptSwitch(enableEncrypt);
        }
        final encryptionType = prefs.getInt("encryption_type");
        if (encryptionType != null) {
          settingModel.setEncryptionType(EncryptionType.values[encryptionType]);
        }
        final encPassword = prefs.getString("encryption_password");
        if (encPassword != null) {
          settingModel.setEncryptionPassword(encPassword);
        }
        await initDrive();
        return;
      }
      var enableEncrypt = prefs.getBool("enable_encrypt");
      // 从旧 key (enalble_encrypt) 迁移
      if (enableEncrypt == null) {
        enableEncrypt = prefs.getBool("enalble_encrypt");
        if (enableEncrypt != null) {
          prefs.setBool("enable_encrypt", enableEncrypt);
          prefs.remove("enalble_encrypt");
        }
      }
      if (enableEncrypt != null) {
        settingModel.setEncryptSwitch(enableEncrypt);
      }
      final encryptionType = prefs.getInt("encryption_type");
      if (encryptionType != null) {
        settingModel.setEncryptionType(EncryptionType.values[encryptionType]);
      }
      final encPassword = prefs.getString("encryption_password");
      if (encPassword != null) {
        settingModel.setEncryptionPassword(encPassword);
      }
      // iOS 自用功能：并行上传数、自定义筛选、仅相机相册（移动端分支；
      // 桌面端不加载，桌面行为不变）。仅 iOS 加载：Android 侧无设置入口，
      // 从备份恢复的 prefs 若被加载会静默改变筛选/并行数且无 UI 可改回，
      // 因此 Android 上始终用默认值（筛选关闭、并行 1、仅相机关闭）。
      if (Platform.isIOS) {
        final parallelCountPref = prefs.getInt("parallel_upload_count");
        if (parallelCountPref != null) {
          settingModel.setParallelUploadCount(parallelCountPref);
        }
        settingModel.setUploadFilter(await loadUploadFilterConfig());
        final manualFolderPref =
            prefs.getString(manualUploadFolderPrefsKey);
        if (manualFolderPref != null) {
          settingModel.setManualUploadFolder(manualFolderPref);
        }
        final onlyCameraAlbumPref = prefs.getBool("only_camera_album");
        if (onlyCameraAlbumPref != null) {
          settingModel.setOnlyCameraAlbum(onlyCameraAlbumPref);
        }
      }
      final seedColorValue = prefs.getInt("seed_color");
      if (seedColorValue != null) {
        seedColor = Color(seedColorValue);
      }
      final galleryColumCount = prefs.getInt("galleryColumCount");
      if (galleryColumCount != null) {
        settingModel.setGalleryColumCount(galleryColumCount);
      }

      final localFolder = prefs.getString("localFolder");
      if (localFolder != null && localFolder != "") {
        settingModel.setLocalFolder(localFolder);
        if (localFolder != "") {
          eventBus.fire(LocalRefreshEvent(refreshUnSync: false));
        }
      } else {
        await requestPermission(alert: false);
        if (Platform.isIOS) {
          settingModel.setLocalFolder("Recents");
          await prefs.setString("localFolder", "Recents");
          eventBus.fire(LocalRefreshEvent(refreshUnSync: true));
        } else {
          final List<AssetPathEntity> paths =
              await PhotoManager.getAssetPathList(
                  type: RequestType.common, hasAll: true);
          final Map<AssetPathEntity, int> assetCountMap = {
            for (final p in paths) p: await p.assetCountAsync,
          };
          paths.sort((a, b) =>
              (assetCountMap[b] ?? 0).compareTo(assetCountMap[a] ?? 0));
          if (paths.isNotEmpty) {
            settingModel.setLocalFolder(paths[0].name);
            await prefs.setString("localFolder", paths[0].name);
            eventBus.fire(LocalRefreshEvent(refreshUnSync: true));
          }
        }
      }
      final lastRefreshUnsyncTime = prefs.getInt("last_refersh_unsync");
      if (lastRefreshUnsyncTime != null) {
        stateModel.updateLastRefreshUnsyncTime(
            DateTime.fromMillisecondsSinceEpoch(lastRefreshUnsyncTime));
      }
      await assetModel.loadTitleCache();
      await loadUnsynchronizedPhotos();
      await initDrive();
      reloadAutoSyncTimer();
    });
  }
}

DateTime? lastAliveTime;

/// 正在进行的 checkServer 轮次：并发上传同时触发时共享同一轮，
/// 避免多次 server 重启与 httpBaseUrl 来回切换（UP-14）。
Future<void>? _checkServerInFlight;

Future<void> checkServer() async {
  if (useRemoteServer) {
    return;
  }
  if (lastAliveTime != null &&
      DateTime.now().difference(lastAliveTime!) < const Duration(seconds: 60)) {
    return;
  }
  final inFlight = _checkServerInFlight;
  if (inFlight != null) {
    await inFlight;
    return;
  }
  final future = _checkServerOnce();
  _checkServerInFlight = future;
  try {
    await future;
  } finally {
    if (identical(_checkServerInFlight, future)) {
      _checkServerInFlight = null;
    }
  }
}

Future<void> _checkServerOnce() async {
  try {
    await storage.cli.ping(PingRequest());
    lastAliveTime = DateTime.now();
  } catch (e) {
    logger.addLog("ping failed: $e");
    logger.addLog("reboot server");
    final portsStr = await runServer();
    final ports = portsStr.split(",");
    if (ports.length != 2) {
      logger.addLog("grpc server start failed");
      return;
    }
    httpBaseUrl = "http://127.0.0.1:${ports[1]}";
    final parsedGrpcPort = _parseServerPort(ports[0]);
    final parsedHttpPort = _parseServerPort(ports[1]);
    if (parsedGrpcPort == null || parsedHttpPort == null) {
      logger.addLog("grpc server start failed: bad ports '$portsStr'");
      return;
    }
    grpcPort = parsedGrpcPort;
    httpPort = parsedHttpPort;
    setGlobalStorage(RemoteStorage("127.0.0.1", parsedGrpcPort));
    await initDrive();
  }
}

Future<void> initDrive() async {
  final prefs = await SharedPreferences.getInstance();
  var drive = prefs.getString("drive");
  drive ??= "SMB";
  switch (getDrive(drive)) {
    case Drive.smb:
      final addr = prefs.getString("addr");
      final username = prefs.getString("username");
      final password = prefs.getString("password");
      final share = prefs.getString("share");
      final root = prefs.getString("rootPath");
      if (addr != null &&
          username != null &&
          password != null &&
          share != null &&
          root != null) {
        final rsp = await storage.cli.setDriveSMB(SetDriveSMBRequest(
          addr: addr,
          username: username,
          password: password,
          share: share,
          root: root,
        ));
        if (rsp.success) {
          logger.addLog("set drive smb success");
          settingModel.setRemoteStorageSetted(true);
          eventBus.fire(RemoteRefreshEvent(refreshUnSync: false));
        } else {
          settingModel.setRemoteStorageSetted(false);
          assetModel.remoteLastError = rsp.message;
        }
      }
      break;
    case Drive.webDav:
      final url = prefs.getString('webdav_url');
      final username = prefs.getString('webdav_username');
      final password = prefs.getString('webdav_password');
      final root = prefs.getString('webdav_root_path');
      final insecure = prefs.getBool('webdav_insecure') ?? true;
      if (url != null && root != null) {
        final rsp = await storage.cli.setDriveWebdav(SetDriveWebdavRequest(
          addr: url,
          username: username,
          password: password,
          root: root,
          insecure: insecure,
        ));
        if (rsp.success) {
          logger.addLog("set drive webdav success");
          settingModel.setRemoteStorageSetted(true);
          eventBus.fire(RemoteRefreshEvent(refreshUnSync: false));
        } else {
          settingModel.setRemoteStorageSetted(false);
          assetModel.remoteLastError = rsp.message;
        }
      }
      break;
    case Drive.nfs:
      final addr = prefs.getString('nfs_url');
      final root = prefs.getString('nfs_root_path');
      if (addr != null && root != null) {
        final rsp = await storage.cli.setDriveNFS(SetDriveNFSRequest(
          addr: addr,
          root: root,
        ));
        if (rsp.success) {
          logger.addLog("set drive nfs success");
          settingModel.setRemoteStorageSetted(true);
          eventBus.fire(RemoteRefreshEvent(refreshUnSync: false));
        } else {
          settingModel.setRemoteStorageSetted(false);
          assetModel.remoteLastError = rsp.message;
        }
      }
      break;
  }
}

class SnackBarManager {
  static final SnackBarManager _instance = SnackBarManager._internal();

  factory SnackBarManager() {
    return _instance;
  }

  SnackBarManager._internal();

  static BuildContext? globalContext;

  static void init(BuildContext context) {
    globalContext = context;
  }

  static void showSnackBar(String message) {
    if (globalContext != null) {
      ScaffoldMessenger.of(globalContext!).showSnackBar(
        SnackBar(
          content: Text(message),
        ),
      );
    }
  }
}

late AppLocalizations l10n;

void initI18n(BuildContext context) {
  l10n = AppLocalizations.of(context)!;
}

Completer<bool>? requesttingPermission;
BuildContext? requestPermissionContext;
void initRequestPermission(BuildContext context) {
  requestPermissionContext = context;
}

Future<bool> requestPermission({alert = true}) async {
  if (isDesktop()) {
    return true;
  }
  bool result = false;
  if (requesttingPermission != null) {
    result = await requesttingPermission!.future;
    return result;
  }
  requesttingPermission = Completer<bool>();
  //权限申请
  final PermissionState ps = await PhotoManager.requestPermissionExtend();
  if (ps == PermissionState.authorized) {
    result = true;
  } else {
    if (alert) {
      result = false;
      if (requestPermissionContext != null) {
        showDialog(
            context: requestPermissionContext!,
            builder: (BuildContext context) => AlertDialog(
                  title: Text(l10n.needPermision),
                  content: Text(l10n.gotoSystemSetting),
                  actions: [
                    TextButton(
                      onPressed: () {
                        Navigator.of(context).pop();
                      },
                      child: Text(l10n.cancel),
                    ),
                    TextButton(
                      onPressed: () {
                        PhotoManager.openSetting();
                        Navigator.of(context).pop();
                      },
                      child: Text(l10n.openSetting),
                    ),
                  ],
                ));
      }
    }
  }
  requesttingPermission?.complete(result);
  requesttingPermission = null;
  return result;
}
