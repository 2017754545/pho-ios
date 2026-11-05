# Pho iOS 自用改动说明（CHANGES-iOS.md）

基线：`fregie/pho` v1.5.1，提交 `cd1bb38`（`build: 使用本地 fork 依赖修复 WebDAV/NFS 构建`）。
许可证 GPLv3：本 fork 仅供个人自用；如向他人分发，须同样以 GPLv3 提供源码。
加密功能未做。无内购 / Pro 门控代码被改动（仓库内原本就不存在）。

> 本文件只描述“相对原版改了什么”，不含修订历史。

## 一、范围决定（iOS only）

- 三个功能只在 iOS 路径接线与验证。Android 专属调用点原样不动：
  `lib/sync_timer.dart` 的 `parallelCount: 1` 保持不变（只修正了其中一条
  过期注释）；无 Android 路径分类逻辑。
- 共享 Dart 代码中实现（按审计计划），但新设置 UI 入口仅 `Platform.isIOS`
  时可见，Android 行为实际不变；桌面端（Windows/macOS/Linux）不加载新设置，
  桌面行为不变。
- Go 服务端、proto 在本 Dart 改动范围内均未改动，无新依赖；原生 iOS
  代码仅 `AppDelegate.swift` 增加 `cancelBgTask` 通道处理（第十二节 UP-5，
  与已有 `backgroundSync` 通道同一 handler）。Go 服务端另有 2026-11-02
  的独立修复，见第十一节。`uploadAssetEntity` 的重试退避加固已在第十二节
  UP-10 完成（500ms 指数退避、上限 8s、抖动）。

## 二、功能 1：并行上传

- `lib/state_model.dart`：`SettingModel` 新增 `parallelUploadCount`
 （默认 1，即现有串行行为；`setParallelUploadCount` 钳制 1–4）。
 持久化：SharedPreferences 键 `parallel_upload_count`，由设置页显式写入。
- `lib/sync_body.dart`（前台同步）：`runSyncOnce` 的 `parallelCount: 1`
  改为读 `settingModel.parallelUploadCount`。`runSyncOnce` 本身未改
  （Semaphore + worker 池机制原本就已存在）。
- `lib/background_sync_entrypoint.dart`（iOS 后台同步 Step 5/Step 10）：
  加载 `parallel_upload_count` 与筛选配置；`parallelCount` 取
  `min(setting, 2)` 并附注释——BGProcessingTask 有时长限制，后台任务
  超时会被系统杀掉；前台同步不受此封顶限制。
- `lib/global.dart`（移动端 prefs 加载分支）：加载
  `parallel_upload_count`、筛选配置与 `only_camera_album`。
- `lib/settings_route.dart`（仅 iOS 可见）：设置列表新增“并行上传数”
  一项，点开对话框选 1/2/3/4，附说明文案（数值越大越快、越耗电；
  后台同步最多同时 2 张）。
- 文案：`lib/l10n/app_en.arb` / `app_zh.arb` 新增 `parallelUploadCount`、
  `parallelUploadCountDesc`（`flutter gen-l10n` 已重新生成）。

## 三、功能 2：自定义上传筛选

- 新增 `lib/sync/upload_filter.dart`：`UploadFilterConfig`（`enabled`
  开关、排除视频/图片、起止日期、扩展名允许表 `extensionAllowed`
  （false=排除），key 形如小写 `.jpg`，未出现即允许），`toJson`/`fromJson`（容错解析，
  损坏内容回退默认），`allows()` 纯谓词，`normalizeExtension()` 归一化。
  持久化：单个 JSON 字符串，SharedPreferences 键 `upload_filter_config`
  （`loadUploadFilterConfig` / `saveUploadFilterConfig`）。默认全部允许，
  零行为变化。
- `lib/sync/background_runner.dart`：`shouldSyncAsset` 在已上传 ID 检查
  **之后** 应用筛选（顺序固定，不可反）。类型用 `Asset.isVideo()`、
  日期用 `effectiveCreateDate`（1990 回退规则，见下）、扩展名用调用方
  传入的扩展名字符串。计数、上传、同步页展示三处共用同一判定。
  未加大小/时长谓词（v1 刻意不加：热路径异步文件 IO）。
- `lib/util.dart`：新增 `effectiveCreateDate(createDateTime,
  modifiedDateTime)`——createDateTime 早于 1990-01-01 时回退
  modifiedDateTime。此前该规则在 `lib/state_model.dart` 与
  `lib/storage/storage.dart` 各写了一份，现为唯一 canonical 实现；
  `state_model.dart` 内两处重复点已改用它（语义不变），不再产生第三份拷贝。
- 新增 `lib/filter_settings_route.dart`：筛选设置页（仿 ChooseAlbumRoute
  的 StatefulWidget + 写回模式）。内容：启用开关、排除视频/图片开关、
  `showDateRangePicker` 日期范围、逗号分隔的扩展名输入框、组合语义说明。
  点保存时写回 `SettingModel` + SharedPreferences，并 fire
  `LocalRefreshEvent(refreshUnSync: true)` 使同步页计数立即刷新。
- `lib/settings_route.dart`（仅 iOS 可见）：设置列表新增“上传筛选”入口。
- `lib/sync_timer.dart`：修正过期注释（原注释声称的过滤逻辑在基线代码
  中并不存在；现在筛选由 `shouldSyncAsset` 统一执行，注释按此重写）。
- 组合语义（页内文案亦说明）：被排除的照片不上传、不计入待同步数量、
  不删除；放宽条件后下一轮自动重新进入待同步集合。
- 文案：新增 `uploadFilter`、`uploadFilterDesc`、`filterEnabled`、
  `filterExcludeVideos`、`filterExcludeImages`、`filterAfter`、
  `filterBefore`、`filterDateNotSet`、`filterDateRange`、
  `filterClearDates`、`filterExtensions`、`filterExtensionsHint`、
  `filterExtensionsDesc`。

### B1/B2 修复（2026-11-02 二次审计后，判定核心未动）

- **B1 扩展名输入框无效**：`allows()` 是 deny-list（未列出即允许），
  但设置页 `_save()` 把输入的扩展名全写 `true`、回填只取 `true` 条
  目，`false` 条目一点保存就被销毁，且界面文案承诺的是 allow-list。
  修复（deny-list 对齐）：`_save()` 写 `false`、回填只取 `false` 条目；
  文案改为“要排除的扩展名”（中英）及对应的 hint/desc；`allows()`、
  锁定测试期望均未动。`normalizeExtension` 的误导性 “.aes 剥离”注释
  已修正（调用方传入的已是 `path.extension()` 结果，此处不剥离）。
- **B2 结束日整日被排除**：`_pickDateRange` 把选择器返回的结束日
  00:00 直接存入 `before`，`allows()` 用 `isAfter` 排除，导致结束日
  全天照片被排除。修复（仅 UI 边界，`allows()` 比较语义未动）：
  `UploadFilterConfig.exclusiveBeforeBound()` 把选中结束日换算为次日
  00:00 存入 `before`，`inclusiveEndDay()` 换算回选中日用于回显与选择
  器初始值（日历构造，跨月/跨年自动归一）；日期范围标题注明“含首尾
  两日”。直接写 `before` 的调用方（测试）须自行保证“次日 00:00 上界”
  约定，见 `upload_filter.dart` 类注释。
- 旧配置注意：本次修复前已存入的 `before`（结束日当天 00:00）在新
  代码下仍按旧语义表现（结束日被排除）且回显会少显示一天；重新
  打开筛选页选一次日期范围即可纠正。本 fork 未发布，无已发布用户
  受影响。
- 新增测试：`upload_filter_test.dart` 增加 B2 换算组（往返、真实带时
  间戳的日期、JSON 往返，含闰月与跨年）；新增
  `test/widget/filter_settings_route_test.dart`（驱动真实设置页：回填
  只显示 `false` 条目、保存不销毁 `false`、新输入存为 `false`）。
  修复后全量 `flutter test`：**115 通过 / 12 失败**（12 个失败与基线
  完全相同，见第七节；新增 5 个测试全部通过）。

## 四、功能 3：仅相机相册（仅展示层开关）

- 新增 `lib/camera_album_classifier.dart`：纯函数、三态分类
  （`camera` / `excluded` / `unknown`），无平台通道、无新依赖。
  iOS 信号 only：相册名容差匹配（Camera/相机/相機；Screenshots/截屏/
  屏幕截图）+ 文件名前缀启发（`Screenshot_`/`Screenrecording_` 等，
  仅作辅助证据）。信号不足判 `unknown`，展示层默认**保留**，绝不凭弱
  证据隐藏/删除用户照片。不读 EXIF。
- `lib/state_model.dart`：
  - `SettingModel` 新增布尔 `onlyCameraAlbum`（默认 false），持久化键
    `only_camera_album`，加载点同功能 1。
  - `AssetModel` 新增 `cameraExcludedIds`（截图类相册内的资产 ID 集合）
    与 `refreshCameraExcludedIds()`（仅 iOS 且开关开启时枚举截图相册、
    分页收集 ID；失败记日志、不阻塞展示），以及展示用派生列表
    `displayLocalAssets`（仅相机模式开启时排除截图相册资产与分类器
    判定的截图/录屏文件）。
  - `refreshLocal()` 在取回本地照片后调用 `refreshCameraExcludedIds()`。
  - 本开关**不影响同步选择**（同步始终用 `localAssets` +
    `shouldSyncAsset`），**不改 `localFolder`**（哨兵值会清空
    `syncedIDs`，已否决）。
- `lib/gallery_body.dart`：展示、分享、删除、上传选中、下载选中五处
  索引源统一改用 `displayLocalAssets`（与 `originIndex` 保持同一列表，
  避免索引错位）；仅相机模式下“本地有照片但过滤后为空”时显示专属空态文案。
- `lib/gallery_viewer_route.dart`：浏览器的 `all` 列表改用
  `displayLocalAssets`，与 `originIndex` 一致。
- `lib/settings_route.dart`（仅 iOS 可见）：设置列表新增“仅相机”开关
  + 一行说明文案（复用已有的 `onlyCamera` 文案，新增 `onlyCameraDesc`）。
  桌面端开关不显示。
- iOS 硬限制（设置页文案已明说）：Recents（最近项目）中由微信、
  WhatsApp 等保存的图片，在纯 Dart 侧无法与相机照片区分，仍会显示。
  截图相册 ID 排除集是 iOS 下真正有效的排除机制。
- 文案：新增 `onlyCameraDesc`、`noCameraPhotos`。

## 五、测试修复（基线即已损坏，非本次回归）

基线 `flutter analyze` 有 15 个 error，全部位于两个测试文件，原因是
它们引用了已被开源版移除的 Pro API（测试无法编译）：

- `test/unit/sync_logic_test.dart`：`paralleUploadCount`（拼写错误）
  改为正确拼写的 `parallelUploadCount`（2 处）。`enableFilter` 字段
  已按新 API 实现为 getter/setter，无需改测试。
- `test/widget/sync_body_test.dart`：未改动——本次实现的
  `setFilterSwitch` / `setFilterNoVideo` / `setFilterNoImage` /
  `setFilterAfter` / `setFilterBefore` / `filterTypeMap` 与该文件锁定的
  语义一致（含“同日不含 +1 天偏移”的边界），该文件现可直接编译通过。
  没有为迁就拼写错误新增别名字段。

## 六、新增测试

- `test/unit/upload_filter_test.dart`：`allows()` 纯谓词（类型、日期边界
  含 1990 回退、扩展名大小写、关闭=全部允许）、`toJson`/`fromJson`
  往返与容错、SharedPreferences 往返与损坏回退、`shouldSyncAsset`
  组合（已上传优先、筛选排除/允许、1990 回退走 `modifiedDateTime`）。
- `test/unit/camera_album_classifier_test.dart`：相册名/文件名矩阵、
  unknown 默认保留、非截图前缀不误判。
- `test/unit/sync_logic_test.dart` 新增用例 (e) parallel：
  `parallelCount=3` 时 3 张真正并发（并发峰值断言为 3，串行时恒为 1），
  其中一张失败不阻塞其余两张。

## 七、验证结果（Linux VM，Flutter 3.47.9 stable，Go 1.26.10）

改动前基线（`flutter analyze` / `flutter test`，2026-11-02 实测）：

- `flutter analyze`：120 个 issues，其中 15 个 error（见第五节，两个测试
  文件无法编译），其余为 info/warning。
- `flutter test`：79 通过 / 14 失败（含 2 个测试文件编译失败）。

改动后（2026-11-02 全部审查项修复后，协调方独立复验）：

- `flutter analyze`：94 个 issues，**0 error、17 warning、77 info**（warnings
  未超 B1/B2 后基线 22 个；三个新增 Dart 文件零 issues）。
- `flutter test`：**203 通过 / 0 失败**（基线 12 个既有失败全部修复，见第十二节；
  全部此前通过的测试仍通过；新增回归测试均通过）。
- `go vet ./server/...`：干净；`go test ./server/...` 不依赖 Docker 的包全部
  通过，Docker 集成套件因镜像拉取不可达未执行（见第十一节）。
- 未尝试 `flutter build ios`：Linux VM 无 macOS/Xcode，且需先
  `make server-ios` 生成 xcframework，见第八节。

## 八、macOS 构建步骤（用户侧，未在本机执行，仅指令）

前置：macOS + Xcode（已登录个人 Apple ID 即可个人签名侧载，无需付费
开发者账号发 TestFlight；但“无开发者账号推送”等限制与原版相同，
本改动不涉及推送），Flutter SDK（stable），Go 1.25+，CocoaPods
（如 `ios/Podfile` 需要）。

```sh
# 1. 在仓库根目录，先编 Go 服务端 iOS 框架（生成 .xcframework，
#    否则 flutter build ios 会缺 server_ios 绑定而失败）
make server-ios

# 2. 取 Flutter 依赖
flutter pub get

# 3a. 构建未签名/开发签名的 iOS 应用包（二选一）
flutter build ios --debug
# 或发布模式：
# flutter build ios --release

# 3b. 或用 Xcode 打开 ios/Runner.xcworkspace，
#     在 Signing & Capabilities 中选个人 Team（Personal Team），
#     Product > Run 安装到已连接的 iPhone（Xcode 会自动管理
#     provisioning profile 与签名证书）。
```

侧载说明：用 Xcode 个人签名直接装到自己 iPhone 即可；如需生成
IPA 再用个人证书签名安装，可用
`flutter build ipa --export-method development`（Flutter 会自动生成
`ExportOptions.plist`，无需手写；个人 Team 在 Xcode Signing &
Capabilities 中选已登录的 Apple ID，见 3b）。GitHub Actions 工作流
（`.github/workflows/ios-build.yml`，仅 `workflow_dispatch` 触发）用
`flutter build ios --release --no-codesign` 出未签名 `.app` 再打包 IPA，
与本地 3a 的 `--debug/--release` 带签名构建是两条等价路径。
`make server-ios` 每次拉取新基线后如 Go 代码有变都应重跑；
**本次 Go 代码已有改动（第十一节），构建前必须重跑一次**。

## 九、逐文件改动清单

新增文件：

- `lib/camera_album_classifier.dart`（功能 3，纯分类器）
- `lib/filter_settings_route.dart`（功能 2，筛选设置页）
- `lib/sync/upload_filter.dart`（功能 2，配置模型 + 持久化）
- `test/unit/camera_album_classifier_test.dart`
- `test/unit/upload_filter_test.dart`

修改文件：

- `lib/state_model.dart`（三功能的状态字段与 AssetModel 展示层支持；
  日期回退规则改用共享 helper）
- `lib/sync/background_runner.dart`（`shouldSyncAsset` 应用筛选）
- `lib/sync_body.dart`（前台同步读 `parallelUploadCount`）
- `lib/background_sync_entrypoint.dart`（后台入口加载新设置 + 并行封顶 2）
- `lib/global.dart`（移动端加载新设置）
- `lib/sync_timer.dart`（仅注释修正；`parallelCount: 1` 不变）
- `lib/util.dart`（`effectiveCreateDate` 共享 helper）
- `lib/settings_route.dart`（仅 iOS 可见的三项入口）
- `lib/gallery_body.dart`（展示列表改用 `displayLocalAssets` + 空态分支）
- `lib/gallery_viewer_route.dart`（浏览器列表改用 `displayLocalAssets`）
- `lib/l10n/app_en.arb`、`lib/l10n/app_zh.arb`（新增文案 key）
- `lib/l10n/app_localizations.dart`、`app_localizations_en.dart`、
  `app_localizations_zh.dart`（`flutter gen-l10n` 重新生成）
- `analysis_options.yaml`（Flutter 工具链自动写入的 analyzer exclude，
  工具生成内容）
- `test/unit/sync_logic_test.dart`（拼写修复 + 新增并行用例）

未改动（本 Dart 改动范围内）：proto、原生 Android 代码、`pubspec.yaml` /
依赖、`lib/sync_timer.dart` 的并行参数、加密相关代码。Go 服务端改动见
第十一节；原生 iOS 改动仅 `AppDelegate.swift` 的 `cancelBgTask` 处理。

### diffstat（相对基线 cd1bb38，不含新增文件）

```
 analysis_options.yaml               |   9 ++
 lib/background_sync_entrypoint.dart |  15 +++-
 lib/gallery_body.dart               |  27 ++++--
 lib/gallery_viewer_route.dart       |   4 +-
 lib/global.dart                     |  12 +++
 lib/l10n/app_en.arb                 |  19 ++++-
 lib/l10n/app_localizations.dart     | 102 +++++++++++++++++++++++
 lib/l10n/app_localizations_en.dart  |  56 +++++++++++++
 lib/l10n/app_localizations_zh.dart  |  54 ++++++++++++
 lib/l10n/app_zh.arb                 |  19 ++++-
 lib/settings_route.dart             |  82 +++++++++++++++++++
 lib/state_model.dart                | 159 ++++++++++++++++++++++++++++++++++--
 lib/sync/background_runner.dart     |  21 ++++-
 lib/sync_body.dart                  |   4 +-
 lib/sync_timer.dart                 |   8 +-
 lib/util.dart                       |  12 +++
 test/unit/sync_logic_test.dart      |  44 +++++++++-
 17 files changed, 617 insertions(+), 30 deletions(-)
```

## 十、已知限制（须真机验证，未在本 Linux VM 验证）

1. iOS 真机行为整体未验证：无 macOS/Xcode，无法编译安装。
   需在真机上验证：并行数 2–4 的实际上传速度与稳定性、后台同步
   （BGProcessingTask）封顶 2 的表现、筛选开关前后的计数/上传一致性、
   仅相机开关的截图隐藏效果与空态。
2. 仅相机模式依赖 iOS 截图相册枚举（`PhotoManager.getAssetPathList` +
   分页取 ID）；大相册首次开启时枚举耗时未实测。
3. `photo_manager` 在 iOS 上返回的相册名以英文为主；中文设备返回本地化
   名时分类器已做繁简容差，但未经中文系统真机核实。
4. 筛选日期范围 UI 使用 `showDateRangePicker` 一次性设定起止两端；
   单边日期边界（只设最早或只设最晚）在数据模型与测试中均支持，
   UI 上可用“最早日期 ~ 很远的未来”表达。
5. ~~本次未做 `uploadAssetEntity` 重试退避~~ 已做（第十二节 UP-10）：
   500ms 指数退避、上限 8s、0–249ms 抖动；Linux 上重试循环本身因
   photo_manager 平台断言无法执行验证，见第十二节未验证项。

## 十一、Go 服务端修复（2026-11-02，独立于 Dart 改动的修复 pass）

相对基线 `cd1bb38` 的 `server/` 改动（无新依赖，`go.mod`/`go.sum` 未变，
无新加密设计；GCM/CFB 方案不变，仅修复安全与正确性问题）：

- **安全**：独立版默认只绑 loopback（`127.0.0.1:50051` / `127.0.0.1:8000`，
  pprof 同样 loopback），gRPC reflection 仅调试模式启用；嵌入式路径
  （`server/run`）为 loopback-only，威胁模型写入注释。浏览路径
  （`ListDrive*Dir` 的 `Dir`/`Share` 与三后端 `SetRootPath`）经
  `util.CleanDirPath`/`CleanShareName` 校验，拒绝任何 `..` 元素，
  保留 `.`/`/` 根拼写。
- **崩溃/越界**：GCM 头 `chunkSize` 在使用前校验（0 拒绝，上限 16 MiB）；
  `DecryptedContentSize` 永不返回负数，尺寸计算使用头内 chunkSize；
  HTTP Range 边界统一（`start >= size` → 416，`end < start` 与畸形 Range
  → 400，未知方法 → 405，chunked 上传 → 411）；三后端
  `DownloadWithOffset` 统一约定（`offset == size` 返回空流+总大小，
  `offset > size` 报错）。
- **正确性**：`FilterNotUploaded` 出错时返回 `Success=false` 且不发伪造
  列表，保留请求顺序并上报重名；`Delete` 聚合后端逐路径错误；
  `SetDrive*` 先完整配置（含网络校验）再替换旧驱动，失败保留旧驱动；
  加密 Live Video（`.mp4.aes`）可被 `/live/` 路径发现；GCM Range
  Content-Type 修正；Content-Type 解析统一为 `util` 助手并新增
  `.heic`/`.heif`/`.dng`；`RangeByDate` 零日期/类型 02 目录检查/错误
  传播/early-stop 传播修正；上传三 handler 与 `genPath` 共用同一生效日期；
  上传失败删除残缺文件（三后端一致，含 SMB/NFS 的 Close 错误）；
  SMB/NFS 句柄加锁 + 在途引用计数，SMB 下载锁持有至流关闭；
  `ImgManager.Close()` 幂等并排空待删队列；删除一批死代码
  （`decodeName`、`GetImageMetadata`、GCM/CFB 尺寸辅助、CFB 死分支）。
  四份 `server/**/AGENTS.md` 按修复后代码重写（此前 RPC 数、接口方法数、
  工作池、KDF 等描述与代码不符）。`server/api/encrypt_test.go` 的 CFB
  断言按当前意图行为修正：CFB 加密上传被拒绝，旧 CFB 文件解密仍支持，
  测试改为直接在 share 上写入 legacy CFB 文件验证。
- **行为变化**（相对原版）：上述 loopback 默认与 reflection 调试限定、
  `FilterNotUploaded` 错误语义、`Delete` 错误聚合、416/400 Range 语义、
  `SetDrive*` 配置后交换、遍历路径拒绝、chunked 上传 411，均有回归测试
  覆盖，见 `server/imgmanager/fixes_regression_test.go`、
  `server/api/http_behavior_test.go`、各后端 `*_path_test.go` 与
  `server/util/util_test.go`。

验证（Linux VM，Go 1.26.10）：`go vet ./server/...` 干净；
`go test -race` 在 SMB/NFS/WebDAV/imgmanager/api 触及包上干净；
不依赖 Docker 的单元测试全部通过。Docker 集成套件（`make test`）
在本 VM 无法运行：Docker Hub 镜像拉取 TLS 握手超时（dockerd 与 crane
均无法到达 `registry-1.docker.io`），`make test` 在
`docker compose up` 一步失败；SMB/NFS/WebDAV 集成测试与 CFB
`encrypt_test.go` 改写部分因此未经执行验证。`TestEmbeddedBindsLocalhost`
为既有环境失败（本 VM 上非 loopback IP 能连通 127.0.0.1 监听器），
与本次改动无关。

测试工具安装记录（均装于用户目录，未改系统路径；仅供本机测试使用）：
Docker 27.3.1 静态二进制（`https://download.docker.com/linux/static/stable/x86_64/docker-27.3.1.tgz`，
`~/docker/bin/`，数据目录 `~/docker-data`，vfs 驱动、无桥接网络）；
Docker Compose v2.29.7（GitHub `docker/compose` releases，
`~/.docker/cli-plugins/docker-compose`）；protoc 27.1（GitHub
`protocolbuffers/protobuf` releases，`~/tools/protoc/`）；
`protoc-gen-go` v1.27.1 与 `protoc-gen-go-grpc` v1.1.0
（`go install`，`~/go/bin/`，与 Makefile `prebuild` pin 一致）；
crane v0.20.6（`go install`，`~/go/bin/`，仅用于尝试拉取镜像，未成功）。
Protobuf 再生检查（仅 Go 输出）：`protoc` + 上述插件重生成
`proto/*.pb.go`，与已提交文件仅 protoc 版本戳一行之差
（v3.21.12 → v5.27.1），已还原，未留改动；Dart 输出未跑。

## 十二、全部审查项修复（2026-11-02，用户下令“都修”）

全项目逐行审查（FK-1–FK-23、UP-1–UP-15、I-01–I-30、U1–U10）发现的
问题已全部处理：修复、或经核查确认不构成缺陷、或明确列为未修遗留
（见末尾）。锁定语义未动：UP-4 的 `failedTimes > 10` 阈值只改了注释；
B1/B2 修复与测试保持原样；未新增加密功能（UP-15 仅记录现状）。

### Fork 问题（FK）

- **FK-1**（`lib/sync_body.dart`）：计数路径改与上传路径同一异步
  `extension(await asset.name())` 解析并按资产缓存；标题未到前先按空
  扩展名计数、回填后重建修正（瞬态行为已在代码中注明）。
- **FK-2**（`lib/sync/background_runner.dart`）：`runSyncOnce` 边界跳过
  `local == null` 资产（记日志、不计数）；`shouldSyncAsset` 文档修正为
  真实回退语义；可达路径行为不变。
- **FK-3**：双排除全开时设置页给警告横幅（`filter_settings_route.dart`）
  且同步页给提示行（`sync_body.dart`）；`allows()` 保持纯谓词。
- **FK-4 / FK-10 / FK-12**（`lib/state_model.dart`）：筛选 setter 保留并
  修好——全部经串行化保存链持久化；`filterTypeMap` 仍返回 live map
  （锁定测试依赖，文档已注明）并新增只读快照 getter；`enableFilter`
  归一为 `setFilterSwitch` 的委托；`setFilterBefore` 保持原始 bound
  语义（锁定测试边界用例依赖），仅 `setUploadFilter` 对非午夜 `before`
  做上界归一化；过期 Step 注释已修正。
- **FK-5**（`lib/global.dart`、`background_sync_entrypoint.dart`）：fork
  配置只在 `Platform.isIOS` 时加载，Android 上即使备份恢复出 prefs
  也用默认值；`shouldSyncAsset` 本身不设门（测试宿主需要）。
- **FK-6**：新增 `shouldUploadManually()` guard；手动上传两处调用点
  （`gallery_body.dart:uploadSelected`、`gallery_viewer_route.dart:upload`）
  已接线，被筛选排除/已上传的手动上传会被跳过并提示（新增文案
  `skippedByUploadFilter`）。行为变化，见下。
- **FK-7**（`lib/gallery_body.dart`、`lib/asset.dart`）：选择改以稳定资产
  ID（`Asset.stableKey()`）为键，动作时对当前列表解析、丢弃过期 ID、
  删除按实际删除结果同步模型、远端删除失败不再误删。行为变化，见下。
- **FK-8**（`lib/gallery_viewer_route.dart`）：浏览列表随模型变化重算并
  clamp 索引，全部索引访问加 guard，`_videoController` 正确处置，删除
  失败对话框不再卡死，HEVC 对话框改用自身 context。
- **FK-9**（`lib/filter_settings_route.dart`）：保存加 in-flight guard；
  日期倒置或双排除全开时禁用保存并给警告；倒置配置下选择器初始范围
  不再坍缩为单日。
- **FK-11**：分类器文档修正（精确匹配/fail-open、iOS 上
  `isCameraAlbumName` 难触发、相册名作用于整列表）；相机开关先刷新
  排除集再翻标志，截图不再闪现；匹配规则未扩大。
- **FK-13**：`_save` 丢弃既有 `true` 条目属语义中性（未列出即允许），
  已在代码注释中说明；多点扩展名（`tar.gz`）round-trip 限制已注明。
- **FK-14**（`lib/storage/storage.dart`）：上传日期改调共享
  `effectiveCreateDate`，内联 1990 副本已删。
- **FK-15**：死键 `filterAfter`/`filterBefore` 已从双 arb 删除并重生成。
- **FK-16**：已在上一轮订正（§七数字），本次复核无误。
- **FK-17**：`Makefile` 的 `ipa` 目标加 `--export-method development`
  （Flutter 自动生成 `ExportOptions.plist`）；§八已同步修正。
- **FK-18**：`.github/workflows/ios-build.yml` 改为仅
  `workflow_dispatch`、gomobile 按 `go.mod` pin、构建前加 analyze+test。
- **FK-19**：`Makefile` 明确 `test`/`test-go` 为 Go+Docker，新增
  `test-flutter` 目标；`protobuf` 目标注明会重写生成文件与插件版本。
- **FK-20**：测试侧弃用 API 已迁移；生产侧 Radio API 与未用 import
  经核查已无问题。
- **FK-21**：wifi-off 测试重写为 mock connectivity + 真实 per-tick
  guard 断言（d1–d5），过期 NOTE 已删。
- **FK-22**：B2 换算补 Feb-29/非闰 Feb-28/边界 instant 用例与 picker
  往返 widget 测试（Flutter 3.47 的 `showDateRangePicker` 无 Cancel
  按钮，取消走 barrier-dismiss，测试据此编写）。
- **FK-23**：Go worker 池注释已修正（池只处理异步删除）。

### 上游 Dart 问题（UP）

- **UP-1**：信号量释放在 finally，回调错误记日志不计入上传失败。
- **UP-2**：`syncPhotos` 加 try/finally，UI 状态必复位、错误走 SnackBar。
- **UP-3**：定时器加 in-flight guard，运行中跳过 tick。
- **UP-4**：仅注释修正为净失败语义，阈值未动。
- **UP-5**：`scheduleBgTaskViaChannel` 返回 `bool` 并记日志；新增
  `cancelBgTaskViaChannel`，关闭后台同步时调用；原生侧
  `AppDelegate.swift` 新增 `cancelBgTask` 处理（取消已提交任务）。
- **UP-6**：`parallelCount <= 0` 钳制为 1；扩展名每资产只解析一次；
  breaker 检查移至 permit 获取后（串行语义与锁定测试一致）。
- **UP-7（blocker）**：后台入口本体包进 try/catch/finally，
  `complete` 与重调度必定各执行一次；`ports`/`encryptionType`
  解析加防御校验。
- **UP-8**：无 drive 配置时提前返回，不再清空 `syncedIDs`。
- **UP-9**：Wi-Fi 门前移至 server 刷新之前；`last_bg_sync_time`
  改在 server 成功启动后写。
- **UP-10**：重试加 500ms 指数退避（上限 8s、抖动），删除重复的
  `finishUpload(id, false)` 调用。
- **UP-11**：URL 改走 `pathSegments` 逐段编码，`#`/`?`/空格标题不再
  被截断改名；`asset.dart:videoDuration` 同类问题一并修复。
- **UP-12**：channel 只在构造器建一个，新增幂等 `close()`，替换全局
  storage 时关闭旧实例。
- **UP-13**：死代码 `uploadXFile` 删除（含接口方法与生成 mock 桩）。
- **UP-14**：`checkServer` 单 in-flight future 串行化，单次上传内
  base URL 快照；`global.dart` 两处 `int.parse(ports)` 改防御解析。
- **UP-15**：仅记录——凭证明文存 SharedPreferences、经不安全 gRPC 与
  `Image-Encrypt-Password` 头传往 loopback 服务，日志中无凭证值；
  未改存储与传输，未新增加密。
- **UP-16**：`main.dart` 注册 lifecycle observer、取消 connectivity
  订阅，`SharedPreferences.then` 回调加 mounted 检查。
- **UP-17**：EXIF 解析加 guard，orientation 维度交换修正为仅 5–8 换。
- **UP-18**：`mimeTypeByExtension` 归一化键，video MIME 不再恒 null。
- **UP-19**：locater 空列表/除零/`mouthLocList[0]` 越界加 guard。
- **UP-20**：月/年跳转分组计数修正为每桶恰好计一次。
- 其余 UI/state 小项：dispose 顺序、`refresh` await 化、`ChooseAlbumRoute`
  mounted 检查与单相册失败隔离、死代码 `SettingBody` 删除、About
  硬编码版本移除、`newpath!`/`local!` 加 guard、`AssetModel` eventBus
  订阅可取消、排序 tie-break、手势 offset guard，均已处理。

### 上游 Go 问题（I，详见第十一节）

I-01–I-30 全部已修（第十一节已有分项说明）：GCM `chunkSize` 校验
（blocker）、探针连接关闭、`FilterNotUploaded`/`Delete` 错误语义、
三后端 partial 清理与 Close 错误、`.aes` live video 发现、Content-Type
修正、句柄加锁与下载锁持有至关闭、Range 416/400 统一约定、
`SetDrive*` 配置后交换、loopback 默认与 reflection 调试限定、
`sanitizePath` 遍历拒绝、405/400 状态修正、`DecryptedContentSize`
钳制、死代码删除、`Close()` 幂等、四份 AGENTS.md 重写、listener
泄漏与 Shutdown 关 drive、单一生效日期、请求顺序与重名上报、
Content-Type 解析统一、chunkSize 传入尺寸计算、`RangeByDate` 修正、
chunked 上传 411。`DeleteSingleImgAsync` 保留：它是 worker 池唯一的
入队入口，删除会 orphan 池；其发送已改为 close-safe。CFB 测试按
“加密上传拒绝、旧文件解密支持”的当前意图修正。

### 测试与配置问题（U）

- **U1**：`bg_task_scheduler_test` 按生产“吞错返回 false”的既定契约
  重写（测试原先期待抛错，与生产设计矛盾）。
- **U2**：`storage_test` harness 修正（`useRemoteServer = true` +
  显式 `grpcPort` + `HttpOverrides.global = null`），6 个测试全过。
- **U3**：onboarding 测试按真实 UI 重写——生产根本没有权限步骤
  （3 页介绍 → 存储步骤），7 个测试全过。
- **U4**：gallery 白色 overlay 列入颜色门禁白名单（生产颜色正确）；
  golden 按当前主题 token 重生成，像素比较限 Linux。
- **U5**：三组空洞测试全部改走真实生产路径（`runSyncOnce` 失败记账、
  真实 prefs 加载 + `shouldSyncAsset`、真实 `RemoteImage.thumbnail`
  重试 + 退避确定性）。
- **U6**：`gallery_viewer_test` 改驱真实 `GalleryViewerRoute`（Provider
  注入 + photo_manager 通道 mock）。
- **U7**：dedup 测试改向真实 `receiveResponses` 喂重复输入；setter
  本身不去重、去重在调用点，行为已锁定为现状。
- **U8**：生成 mock 已重生成（`uploadXFile` 桩已除），
  `sync_logic_test` 改用生成 mock，手写 mock 删除。
- **U9**：`go_test.yml` 更新至 `ubuntu-latest` / checkout@v4 /
  setup-go@v5（`go-version-file: go.mod`）。
- **U10**：41 个死键（含 3 个元数据不一致键）从双 arb 删除，
  `gen-l10n` 重生成并校验字节一致；116 个键保留且中英一致。
- `Makefile`/`ios-build.yml` 见 FK-17–FK-19；`pubspec.yaml` 与
  `pubspec.lock` 零漂移（`flutter pub get` 的传递 pin 漂移已还原）。

### 行为变化总表（相对原版，全部有回归测试）

Dart：手动上传过筛选（FK-6）；选择按稳定 ID（FK-7）；后台入口失败
必重调度 + `complete(false)`、无 drive/Wi-Fi 不符提前完成（UP-7/8/9）；
信号量/定时器/状态复位语义（UP-1/2/3）；调度 API 返回 bool 与取消
（UP-5）；`parallelCount<=0` 视为 1（UP-6）；重试退避与去重调用
（UP-10）；`#`/`?` 标题真实上传（UP-11）；旧 storage 关闭（UP-12）；
`uploadXFile` 删除（UP-13）；`checkServer` 去重与 base URL 快照
（UP-14）；Android 上 fork 配置不加载（FK-5）；video MIME 返回
（UP-18）；EXIF 维度修正（UP-17）；月/年跳转计数修正（UP-20）。
Go：见第十一节行为变化段。测试：U1–U8 的期望按“生产设计为准”
调整（见上），锁定阈值与 B1/B2 语义未动。

### 验证（协调方独立复验，2026-11-02）

- `flutter analyze`：94 issues，0 error、17 warning、77 info。
- `flutter test`：**203 通过 / 0 失败**（含全部此前通过测试与新增
  回归测试；`TMPDIR` 改用家目录，避开 512M `/tmp` 写满）。
- `go vet ./server/...` 干净；`gofmt` 干净；`go test ./server/...`
  不依赖 Docker 的包全部通过；Docker 集成套件与 `make test` 因
  Docker Hub 不可达未执行（第十一节）；`TestEmbeddedBindsLocalhost`
  为既有环境失败，与改动无关。
- 协调方抽查了各区关键文件 diff、复读了
  `background_sync_entrypoint.dart` 全文，复核 B1/B2 代码原样，并补修了
  收尾遗留：FK-6 两处接线、Swift `cancelBgTask`、FK-3 同步页提示、
  `global.dart` 端口防御解析、`videoDuration` URL 编码、
  `state_model.dart` 过期注释。

### 未验证与遗留（不宣称已完成）

- macOS/Xcode 构建与签名、CI 工作流运行、真机行为（并行速度、后台
  封顶、筛选一致性、截图隐藏、中文相册名）均未验证，与此前结论一致。
- Docker 集成套件、`make test`、`make protobuf` 的 Dart 输出未跑
  （原因见第十一节与 Area 报告）。
- `uploadAssetEntity` 重试循环在 Linux 上因 photo_manager 平台断言
  无法执行验证，复现方法见 `storage_test.dart` 注释，需 macOS/真机。
- 遗留未修（均有明确记录，需另行定夺）：`enalble_encrypt` 迁移逻辑
  内联两份未抽为可测函数（`global.dart`，后台入口只读新 key 的不对称
  未确认）；`setSyncedPhotos` 不去重（去重在调用点，现状已锁定）；
  `reloadAutoSyncTimer` 无 Wi-Fi 门（guard 在 per-tick，现状已锁定）；
  UP-15 凭证明文存储与传输现状（仅记录，不新增加密）。
- 测试工具安装记录见第十一节（Docker/protoc/crane，均在用户目录）。

---

## 十二、手动上传分目录（2026-11-02，本地实现，未推送）

手动上传与自动同步分目录存放：手动上传去设置里定一次的固定
目录（其下按类型分 `video/`/`image/`，不按日期分子目录），自动
同步继续用驱动根目录 + 日期目录。仅 iOS 入口；不改协议
（proto 未动）、不加密、不改筛选/B1/B2 与既有 FK/UP/I 修复。

### 行为

- 设置：主设置页（远程存储行之后，仅 iOS）一行
  “手动上传目录”，副标题显示当前生效目录；点进设置页
  （`lib/manual_upload_folder_route.dart:18`）可手填或点浏览
  打开文件夹选择器。留空 = 未设置，手动上传用默认子目录
  `manual`（分离在未配置时也成立），文案已写明。
- 布局（服务端）：`<dest>/video/<name>`（视频）、
  `<dest>/image/<name>`（照片）；Live Photo 的照片进
  `<dest>/image/<name>`，伴生视频进
  `<dest>/image/live_<base>/<video-name>`——live_ 子目录留在
  照片旁边、位于 image 目录内，绝不进 video/（`GetLiveVideoOffset`
  按照片所在目录找伴生视频）。缩略图镜像为
  `.thumbnail/<dest>/image/<name>`，与原件同布局。加密 `.aes`
  后缀行为不变。自动同步不带目标头，布局不变。
- 改手动目录不移动已上传的文件，也不重传：发现逻辑覆盖任意
  一级相册目录（不限当前配置），旧目录下的文件仍被发现为
  “已上传”（见“发现”一节与测试）。
- 选择器只读浏览（只调目录列举 RPC），不创建任何目录；目录
  在首次上传时由各 drive 的 `Upload` 经 `MkdirAll` 创建
  （`server/drive/*` 既有行为，未改）。

### 逐项改动

- `server/imgmanager/imgmanager.go:163`：`Options` 新增
  `DestDir` 字段；`:189` `WithDestDir` 选项；`:203`
  `SanitizeDestDir`（与目录浏览/根路径相同的清理规则：拒
  绝反斜杠、绝对路径、`..`/`.` 元素、空段、首段 `live` /
  `.thumbnail`、首段日期目录形状；空串 = 未指定，合法）。
- `server/imgmanager/imgmanager.go:274` `genPath`：`DestDir`
  非空时前缀 dest + 类型目录（`util.IsVideo` 判视频；
  `IsLivePhoto` 强制 image，保证伴生视频与照片同目录），
  无日期元素；`DestDir` 为空时原日期目录布局不变；`:312`
  `validateDestDir` 在 `Upload` / `UploadThumbnail` /
  `UploadLiveVideo` 生成路径前校验，非法值直接报错，绝不
  静默回落到根目录。
- `server/api/http.go:25`：头常量 `Image-Dest-Dir`；`:31`
  `destDirFromHeader`（缺省 ""，非法返回 400）；三个上传
  handler（`:115` 原件、`:179` 缩略图、`:239` Live 视频）均
  读头、传 `WithDestDir`，三个子请求带同一个头才落在同一
  目录。Live 视频 handler 保持 `IsLivePhoto(true)`。
- `server/imgmanager/imgmanager.go:1000` `RangeByDate`：日期
  目录遍历之后（提前停止语义保留：回调返回 false 即停，
  不再进相册阶段）追加相册目录阶段 `:1030`
  `rangeAlbumDirs` + `:1060` `walkAlbumDir`（深度上限
  `albumWalkMaxDepth = 4`，`:1058`）。相册根按名字排序；
  跳过根部 `live` 与 `.thumbnail` 目录、跳过日期目录形状
  （避免重复访问）；任意一级相册目录内的文件及下一层
  （`video/`/`image/` 类型目录、`live_*` 子目录）均纳入，
  不论传入的 date 截止（相册文件按编码文件名匹配，截止不
  得丢弃它们）；`live_` 内非视频文件报 `IsLivePhoto: true`，
  伴生视频不单独上报（与日期阶段语义一致）；`.thumbnail`
  子目录在任何一层都跳过；已有日期目录遍历、排序、
  live_ 处理、零日期归一化均未动。调用方不变：
  `FilterNotUploaded`（`server/api/img.go`）与 `ListByDate`
  均经同一 `RangeByDate`，均未改。设计决定：`RangeByDate`
  不为相册文件解析日期、不用零日期占位——`FilterNotUploaded`
  按编码文件名匹配，与日期截止无关；`ListByDate` 不按日期
  分组，只按流式顺序返回 `Path`（日期目录在前、相册目录
  在后），云端视图的日期取自编码文件名（既有行为）。后果：
  相册文件在云端列表流中排在全部日期目录文件之后、按相
  册名排序，不按文件名日期与日期目录文件交错；分页
  （Offset/MaxReturn）同样把它们当作流尾条目。
- `lib/sync/manual_upload_folder.dart`（新文件）：prefs key
  `manual_upload_folder`（`:13`）、默认 `manual`（`:16`）、
  `normalizeManualUploadFolder`（`:26`，规则与服务端
  `SanitizeDestDir` 镜像）、`manualFolderRelativeToRoot`
  （`:58`，把选择器原生路径换算为相对根路径）、选择器拼写
  纯函数 `pickerNativeRoot` / `pickerChildPath` /
  `pickerParentPath`（`:85/:95/:104`，SMB 相对拼写、
  WebDAV/NFS `/` 开头 `/` 结尾拼写，上一级不越过浏览根）、
  `load/saveManualUploadFolder`（`:118/:124`）。
- `lib/state_model.dart:252`：`SettingModel.manualUploadFolder`
  原始值 + `setManualUploadFolder`；`:264`
  `manualUploadDestDir`（归一化结果，未设置/非法时默认
  `manual`）。
- `lib/global.dart:127`：iOS 加载块内读 prefs 写入
  `SettingModel`（与筛选/并行数同一门控）。
- `lib/storage/storage.dart:36` `destDirHeaders`（空值不产生
  头）；`:125` 接口方法 `uploadAssetEntity` 签名未动（仍走
  默认布局，保护 `RemoteStorageClient` mock 生成文件与测试
  fake）；`:131` 新增类级方法 `uploadAssetEntityToDest`（三
  个子请求共用 `destDirHeaders`，经内部 `:139`
  `_uploadAssetEntity` 实现）。
- `lib/gallery_body.dart:555` 与
  `lib/gallery_viewer_route.dart:464`：两处手动上传调用点经
  `shouldUploadManually`（FK-6 未动）后调
  `uploadAssetEntityToDest(entity, settingModel.manualUploadDestDir)`；
  `finishUpload`/`syncedIDs` 处理未动。自动同步
  （`background_runner.dart` 的 `runSyncOnce`）、后台入口、
  `FilterNotUploaded` 请求均不带该头、不传手动目录。
- `lib/manual_upload_folder_route.dart:18` 设置页（内存态改
  革、保存时一次性写回 `SettingModel` + prefs，非法输入禁
  用保存）与 `:149` 选择器页：按当前 drive 类型分发
  `ListDriveSMBDir` / `ListDriveWebdavDir` /
  `ListDriveNFSDir`（与各 storageform 的 `rootPathDialog`
  同一接口、同一路径拼写），浏览根植于当前 drive 的
  rootPath（prefs：SMB `share`/`rootPath`、WebDAV
  `webdav_root_path`、NFS `nfs_root_path`），选根本身返
  回 ""（未设置）。
- `lib/settings_route.dart:59`：主设置页 iOS 专属入口行（副
  标题为生效目录，返回后刷新）。
- l10n：`lib/l10n/app_en.arb:121` 与 `app_zh.arb` 新增 10 个
  键（label/说明/提示/浏览/空值/非法/未设存储/选择器标题/
  当前目录/驱动根），`flutter gen-l10n` 已重新生成
  `lib/l10n/app_localizations*.dart` 并核对一致。
- `README.md`：功能列表加一 bullet（手动上传分目录）与
  fork 说明“三项”改“四项”；工作流未动，未推送。

### 验证（2026-11-02，本地）

- `flutter analyze`：95 issues，0 error、17 warning（与基线
  一致，均为既有 warning）、78 info。
- `flutter test`：**221 通过 / 0 失败**（基线 203 + 新增 18：
  `test/unit/manual_upload_folder_test.dart` 14 个——归一化/
  相对换算/选择器拼写/默认值与持久化往返/头生成；
  `test/widget/manual_upload_folder_route_test.dart` 4 个——
  回填与保存、留空默认、非法禁用保存、未设存储时浏览提示）。
- `go vet ./server/...` 干净；`gofmt` 干净。
- `go test -count=1 ./server/imgmanager/`：48 通过 / 0 失败
  （含新增 5 个：`server/imgmanager/destdir_test.go`——
  `SanitizeDestDir` 接受/拒绝表、`genPath` 类型布局与
  live 布局、加密后缀、`Upload` 系列落点与非法拒绝、
  `RangeByDate` 相册发现与提前停止）。
- `go test ./server/api/ -run TestUploadDestDir|TestUploadWithoutDestDir`：
  3 通过（头落点：照片 image/、视频 video/、Live 视频
  image/live_/、缩略图镜像；`../evil` 400 且零写入；无头
  时保持日期目录布局）。`./server/api` 完整包与
  `drive/{smb,nfs}`、`drive`、`run` 包的其余失败均为既有
  环境失败（需 live SMB/NFS 服务或 Docker 容器，本 VM 无；
  `TestEmbeddedBindsLocalhost` 为既有网络沙箱行为），与
  本改动无关（改动文件不含这些包）。
- 未验证：真机选择器行为（各 drive 的目录列举实测）、NAS
  上手动目录的首次创建、真机手动上传落点与重传行为。

## 十三、文件页签（按文件夹浏览云端，2026-11-05）

底部导航“云端”旁新增“文件”页签，按文件夹浏览云端已同步的
照片/视频；点文件夹进入子目录，点文件打开与云端页签相同的
查看器；系统返回/左上角返回键在子目录时先退回上一级。

- 树完全在客户端由云端页签已有的远端列表
  （`AssetModel.remoteAssets`，`remote.path`）拼出，不改动
  Go 服务端、proto 与同步协议；空文件夹与非照片/视频文件
  不在树里（服务端 `RangeByDate` 只返回已同步的照片/视频）。
- 新文件 `lib/files_body.dart`（页签 UI：面包屑标题、下拉刷新、
  空态/未设存储提示、文件夹行、文件行缩略图+大小+视频角标）、
  `lib/files_tree.dart`（纯函数：路径归一化、单层文件夹视图、
  递归文件计数、文件夹/文件名降序）。
- `lib/main.dart`：导航加第四个目的地（`Icons.folder`，`l10n.files`），
  `IndexedStack` 内“云端”后插入 `FilesBody`；同步页顺延一位，
  其余索引引用均为通用 `_selectedIndex`，无硬编码序号。
- l10n 新键 `files` / `noFiles` / `folderFileCount`（中英），
  `flutter gen-l10n` 已重新生成；`Colors.white` 一处（缩略图上
  的视频播放角标）按既有 overlay 豁免理由加入
  `theme_consistency_test.dart` 白名单。
- `README.md` / `README_EN.md`：功能列表加“文件页签”一项，
  fork 功能计数“四项”改“五项”。

### 验证（2026-11-05，本地）

- `flutter analyze`：0 error（98 issues，均为既有 info）。
- `flutter test`：**228 通过 / 0 失败**（基线 221 + 新增 7：
  `test/unit/files_tree_test.dart`——根目录、递归计数、逐级
  下钻、叶目录排序、manual 的 video/image/live_ 划分、前导
  斜杠与反斜杠归一化、空列表与未知前缀）。
- Go 服务端未动，未跑 `go vet`/`go test`。
- 未验证：真机页签切换、文件夹下钻、文件打开查看器、空态与
  未设存储提示、下拉刷新。

## 十四、文件页签 v2：返回导航、服务端列目录、建文件夹、上传（2026-11-05）

用户反馈 v1 三个缺口：只能下钻、没有返回上一级；没有手动创建
文件夹；没有上传功能。本节全部补齐，数据源改为服务端列目录。

- 返回导航：header 改为可点面包屑栏（根“文件”+ 各级段，点某段
  直接跳到该级）+ 保留返回箭头 + 保留 PopScope 系统返回处理。
  v1 header 没有 SafeArea，顶行在真机上会被状态栏/Dynamic Island
  遮挡，返回箭头够不着——这是用户报“没有返回”的最可能原因
  （无真机，无法直接证实）；v2 header 包在 SafeArea 内，并以
  widget 测试覆盖下钻后面包屑与返回箭头均可见且能回上一级。
- 服务端列目录：`server/api/http.go` 新增 POST `/__dir/list` 与
  POST `/__dir/mkdir`（在下载/上传分支之前拦截，GET 返回 405），
  请求体 `{"dir": "..."}`（相对于驱动根目录，`""` = 根）。
  `imgmanager.ListDir`（单层 `StorageDrive.Range`，跳过
  `.thumbnail`）与 `MkdirDir`（新 `StorageDrive.MkdirAll` 方法：
  SMB/WebDAV 补实现，NFS 复用已有逐级建目录原语——原两参
  `MkdirAll(path, perm)` 改名未导出 `mkdirAll`，调用处同步改名）。
  路径校验用新 `SanitizeBrowseDir`（复用 `util.CleanDirPath` 的
  遍历防护 + 拒首段 `.thumbnail`），与 `SanitizeDestDir` 的区别是
  允许日期形状首段（日期文件夹必须能浏览、能建子目录、能作为
  精确上传目标）；绝对路径、反斜杠、`..` 一律 400 且零次触及驱动。
- 精确目录上传：新头 `Image-Dest-Exact: 1` + 新选项
  `WithExactDestDir`，`genPath` 在 DestDir 已设 + 精确模式时只产
  `<dest>/<name>`（Live Photo 的 `live_` 子目录规则不变，仍相对
  于 dest；DestDir 为空时落在根目录）；默认仍为原有 video/image
  类型分目录（云端手动上传不受影响）。Dart 新增
  `uploadAssetEntityToExactDir`，三个子请求都带两个头。
- Dart 客户端：`RemoteStorage.listDirEntries` / `createDir`（共享
  `httpClient` + `storageHttpUri` + `checkServer`，POST JSON，
  非 200 抛带服务端消息的异常）；`lib/storage/storage.dart` 现有
  公开方法签名未动，只新增方法；不改 proto。
- UI：`lib/files_body.dart` 重写数据源为服务端列表（切文件夹与
  下拉刷新时刷新；文件夹在前、文件在后，均名降序，与 v1 相同）；
  照片/视频条目按完整相对路径匹配 `AssetModel.remoteAssets` 取
  缩略图与查看器（`GalleryViewerRoute useLocal:false`），非媒体条目
  通用图标 + 大小，点击 snackbar 提示仅照片/视频可预览；
  `remoteAssets` 为空时沿用 `_maybeLoad` 触发加载。header 加新建
  文件夹动作（对话框 + 客户端单段校验，镜像服务端规则）与上传
  动作（新 `lib/folder_upload_picker_route.dart`：本地照片多选网格
  + 确认按钮，逐张经精确目录上传到当前文件夹，复用云端手动上传
  的反馈：筛选/`syncedIDs` 跳过计数、每次失败 `uploadFailed`
  snackbar、完成后 `RemoteRefreshEvent` + 刷新列表与远端列表）。
  新文件 `lib/files_data_source.dart`（`FilesDataSource` 抽象 +
  默认存储实现，供 widget 测试注入 fake）。`lib/files_tree.dart`
  及其测试已删除（客户端拼树不再使用）。
- l10n 新键 `emptyFolder` / `createFolder` / `createFolderTitle` /
  `createFolderHint` / `createFolderInvalid` / `uploadToFolder` /
  `previewNotSupported`（中英），`flutter gen-l10n` 已重新生成，
  生成文件仅新增新键。`folder_upload_picker_route.dart` 的 1 处
  `Colors.white`（缩略图视频播放角标）按既有 overlay 豁免理由
  加入 `theme_consistency_test.dart` 白名单。
- `README.md` / `README_EN.md`：文件页签 bullet 改为浏览 + 建
  文件夹 + 上传，注明空文件夹经服务端列表可见。

### 验证（2026-11-05，本地）

- `flutter analyze`：0 error（98 issues，与基线持平，均为既有
  info/warning）。
- `flutter test`：**223 通过 / 0 失败**（基线 228 − 删除的
  `files_tree_test.dart` 7 项 + 新增 2 项
  `test/widget/files_body_test.dart`——下钻后面包屑/返回箭头可见
  且能回上一级、面包屑段跳转到该级）。
- `go vet ./imgmanager/ ./api/ ./drive/...`：干净；`gofmt` 干净。
- `go test ./imgmanager/`：全过（含新增 `browse_test.go`：
  `SanitizeBrowseDir` 接受/拒绝表、精确布局 genPath、ListDir/
  MkdirDir 单层/`.thumbnail` 隐藏/非法零触及、精确模式校验分支）。
- `go test ./api/` 单元测试：全过（含新增 `http_dir_test.go`：
  列表单层、非法 400 零触及、405、建目录、畸形体、精确上传
  六条路径）；5 个 Docker 集成 suite 与基线一致失败
  （`git stash` 对照：无 Docker/测试服务端不可达，环境原因，
  与本次改动无关）。`go test ./drive/...` 同样与基线一致
  （9 项失败，均为测试 NFS/SMB 服务端不可达）。
- 未验证：真机页签切换、面包屑/返回箭头实际可点性（无真机，
  仅 widget 测试覆盖）、新建文件夹与上传的真机行为、服务端列
  目录在 SMB/WebDAV/NFS 真实驱动上的行为（仅 fake 驱动测试）。
