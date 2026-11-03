import 'package:flutter/material.dart';
import 'package:img_syncer/design_tokens.dart';
import 'package:img_syncer/l10n/app_localizations.dart';
import 'package:img_syncer/proto/img_syncer.pbgrpc.dart';
import 'package:img_syncer/setting_storage_route.dart';
import 'package:img_syncer/state_model.dart';
import 'package:img_syncer/storage/storage.dart';
import 'package:img_syncer/sync/manual_upload_folder.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 手动上传目录设置页（仅 iOS 入口，见 settings_route.dart）。
///
/// 写入模式与筛选设置页一致：页内改内存态，点保存时一次性写回
/// SettingModel + SharedPreferences。目录值只存归一化后的相对
/// 路径（见 normalizeManualUploadFolder）；空值 = 未设置，手动
/// 上传用默认 `manual`。改目录不移动已上传的文件（服务端发现
/// 覆盖任意一级相册目录，见 RangeByDate）。
class ManualUploadFolderRoute extends StatefulWidget {
  const ManualUploadFolderRoute({super.key});

  @override
  ManualUploadFolderRouteState createState() => ManualUploadFolderRouteState();
}

class ManualUploadFolderRouteState extends State<ManualUploadFolderRoute> {
  late final TextEditingController _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: settingModel.manualUploadFolder);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _canSave {
    final raw = _controller.text.trim();
    return raw.isEmpty || normalizeManualUploadFolder(raw) != null;
  }

  void _save() {
    final raw = _controller.text.trim();
    final normalized = normalizeManualUploadFolder(raw);
    if (raw.isNotEmpty && normalized == null) {
      setState(() {
        _error = AppLocalizations.of(context)!.manualUploadFolderInvalid;
      });
      return;
    }
    final value = normalized ?? '';
    settingModel.setManualUploadFolder(value);
    saveManualUploadFolder(value);
    Navigator.pop(context);
  }

  Future<void> _browse() async {
    if (!settingModel.isRemoteStorageSetted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              AppLocalizations.of(context)!.manualUploadFolderNotSet),
        ),
      );
      return;
    }
    final picked = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (context) => const ManualUploadFolderPickerPage(),
      ),
    );
    if (picked != null && mounted) {
      setState(() {
        _controller.text = picked;
        _error = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // 不用 global.dart 的 late l10n：它只在 main 的 widget 树里初始
    // 化，测试/独立路由里未初始化会抛 LateInitializationError。
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.manualUploadFolder),
        actions: [
          TextButton(
            onPressed: _canSave ? _save : null,
            child: Text(l10n.save),
          ),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.symmetric(
          horizontal: AppSpacing.paddingLarge,
          vertical: AppSpacing.paddingSmall,
        ),
        children: [
          Text(
            l10n.manualUploadFolderDesc,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: l10n.manualUploadFolder,
              hintText: l10n.manualUploadFolderHint,
              suffixIcon: IconButton(
                icon: const Icon(Icons.open_in_browser),
                tooltip: l10n.manualUploadFolderBrowse,
                onPressed: _browse,
              ),
              errorText: _error,
            ),
            onChanged: (_) {
              // 保存按钮的可用状态随输入实时变化，须每次重建。
              setState(() {
                _error = null;
              });
            },
          ),
          const SizedBox(height: 8),
          Text(
            l10n.manualUploadFolderEmpty,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// 手动上传目录选择器：只读浏览，不创建任何目录。
///
/// 按当前 drive 类型（prefs 的 `drive`）分发目录列举 RPC
/// （ListDriveSMBDir / ListDriveWebdavDir / ListDriveNFSDir），
/// 与各 storageform 的 rootPathDialog 用同一接口、同一路径拼写。
/// 浏览根植于当前 drive 的 rootPath，绝不越界到根之上；返回
/// 相对于驱动根目录的路径（选根本身返回 ""，即未设置）。
class ManualUploadFolderPickerPage extends StatefulWidget {
  const ManualUploadFolderPickerPage({super.key});

  @override
  ManualUploadFolderPickerPageState createState() =>
      ManualUploadFolderPickerPageState();
}

class ManualUploadFolderPickerPageState
    extends State<ManualUploadFolderPickerPage> {
  Drive _drive = Drive.smb;
  String _share = '';
  String _root = '';
  String _current = '';
  bool _ready = false;
  bool _notSet = false;
  Future<List<String>>? _entriesFuture;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final drive = getDrive(prefs.getString('drive') ?? '');
    String root;
    String share = '';
    if (drive == Drive.smb) {
      share = prefs.getString('share') ?? '';
      root = prefs.getString('rootPath') ?? '';
    } else if (drive == Drive.webDav) {
      root = prefs.getString('webdav_root_path') ?? '';
    } else if (drive == Drive.nfs) {
      root = prefs.getString('nfs_root_path') ?? '';
    } else {
      root = '';
    }
    if (!mounted) return;
    setState(() {
      _drive = drive;
      _share = share;
      _root = _nativeRoot(drive, root);
      _current = _root;
      _notSet = !settingModel.isRemoteStorageSetted;
      _ready = true;
      _entriesFuture = _list(_current);
    });
  }

  bool get _isSmb => _drive == Drive.smb;

  /// 把存的 rootPath 换算为各 drive 目录列举接口的原生拼写
  /// （见 pickerNativeRoot）。
  String _nativeRoot(Drive drive, String root) =>
      pickerNativeRoot(drive == Drive.smb, root);

  /// 子目录的原生拼写（见 pickerChildPath）。
  String _childPath(String current, String name) =>
      pickerChildPath(_isSmb, current, name);

  /// 上一级的原生拼写（见 pickerParentPath），绝不越过浏览根。
  String _parentPath(String current) =>
      pickerParentPath(_isSmb, _root, current);

  Future<List<String>> _list(String dir) async {
    try {
      switch (_drive) {
        case Drive.smb:
          final rsp = await storage.cli.listDriveSMBDir(
            ListDriveSMBDirRequest(share: _share, dir: dir),
          );
          if (!rsp.success) throw StateError(rsp.message);
          return rsp.dirs;
        case Drive.webDav:
          final rsp = await storage.cli
              .listDriveWebdavDir(ListDriveWebdavDirRequest(dir: dir));
          if (!rsp.success) throw StateError(rsp.message);
          return rsp.dirs;
        case Drive.nfs:
          final rsp = await storage.cli
              .listDriveNFSDir(ListDriveNFSDirRequest(dir: dir));
          if (!rsp.success) throw StateError(rsp.message);
          return rsp.dirs;
        default:
          return [];
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString());
      }
      return [];
    }
  }

  void _navigate(String dir) {
    setState(() {
      _current = dir;
      _error = null;
      _entriesFuture = _list(dir);
    });
  }

  /// 当前目录相对于驱动根目录的路径；根本身返回 ""。
  String get _relative =>
      manualFolderRelativeToRoot(_root, _current) ?? '';

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.manualUploadFolderPickerTitle),
        actions: [
          TextButton(
            onPressed: _ready && !_notSet
                ? () => Navigator.pop(context, _relative)
                : null,
            child: Text(l10n.save),
          ),
        ],
      ),
      body: !_ready
          ? const Center(child: CircularProgressIndicator())
          : _notSet
              ? Center(child: Text(l10n.manualUploadFolderNotSet))
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                      alignment: Alignment.centerLeft,
                      child: Text(
                        _relative.isEmpty
                            ? l10n.manualUploadFolderRoot
                            : l10n.manualUploadFolderCurrent(_relative),
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                    if (_current != _root)
                      ListTile(
                        leading: const Icon(Icons.arrow_upward),
                        title: const Text('..'),
                        onTap: () => _navigate(_parentPath(_current)),
                      ),
                    if (_error != null)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Text(
                          _error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    Expanded(
                      child: FutureBuilder<List<String>>(
                        future: _entriesFuture,
                        builder: (context, snapshot) {
                          if (!snapshot.hasData) {
                            return const Center(
                              child: CircularProgressIndicator(),
                            );
                          }
                          final entries = snapshot.data!
                              .where((e) => e != '.' && e != '..')
                              .toList();
                          return ListView.builder(
                            itemCount: entries.length,
                            itemBuilder: (context, index) {
                              final name = entries[index];
                              return ListTile(
                                leading: const Icon(Icons.folder_outlined),
                                title: Text(name),
                                onTap: () =>
                                    _navigate(_childPath(_current, name)),
                              );
                            },
                          );
                        },
                      ),
                    ),
                  ],
                ),
    );
  }
}
