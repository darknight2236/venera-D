# venera-D 层级倒置改造清单（6 处 foundation/network → UI 反向依赖）

> 基于《venera-D 耦合度分析报告》P0 项展开。项目：`D:\CodingProjects\venera-D`
> 目标：消除 foundation/ 与 network/ 对 pages/ 和 components/ 的全部 import，使领域层可独立编译、可被 headless 与单元测试复用。
> 通用原则：沿用项目现有风格——`App.rootContext.to(...)`（`lib/foundation/context.dart`）、`App.registerForceRebuild(...)` 式的静态注册回调（`lib/foundation/app.dart:104-108`）；不引入 DI 框架、不引入新包。
> 统一注册点约定：凡需“UI 向 foundation 注册回调”的，注册代码放在 `lib/pages/main_page.dart` 的 `_MainPageState.initState`（:41，App 根 UI，早于一切用户交互）；仅 JS UI 委托例外（见第 2 条，须更早）。
>
> **进度（2026-07）**：#2、#3、#4、#6a、#6b 已完成；剩余：#1、#5、#6c。
> 已知遗留：`foundation/context.dart:2` import `components/components.dart`（`showToast`），验收 grep 会命中，需豁免或将 `showMessage` 移出 context.dart。

---

## 1. comic_source → pages：PageJumpTarget.jump() 在数据模型里 new 页面

### a) 精确 import
`lib/foundation/comic_source/comic_source.dart:14-15`：
```dart
import 'package:venera/pages/category_comics_page.dart';
import 'package:venera/pages/search_result_page.dart';
```

### b) 反向依赖的实质
`PageJumpTarget`（`models.dart:456`）是从漫画源配置解析出的"页面跳转目标"（纯数据：sourceKey/page/attributes），但它的 `jump()` 方法直接构造页面 Widget 并导航（`models.dart:537-560`）：
```dart
void jump(BuildContext context) {
  if (page == "search") {
    context.to(
      () => SearchResultPage(
        text: attributes?["text"] ?? attributes["keyword"] ?? "",
        sourceKey: sourceKey,
        options: List.from(attributes?["options"] ?? []),
      )
    );
  } else if (page == "category") {
    var key = ComicSource.find(sourceKey)!.categoryData!.key;
    context.to(
      () => CategoryComicsPage(
        categoryKey: key,
        category: attributes?["category"] ?? (throw ArgumentError(...)),
        ...
```
调用链（全在 UI 层，且都持有自己的 context）：
- `lib/pages/categories_page.dart:251` `c.target.jump(context)`
- `lib/pages/comic_details_page/actions.dart:301` `target?.jump(context)`
- `lib/pages/explore_page.dart:445` `part.viewMore!.jump(context)`

### c) 拆法：扩展方法下沉到 UI 层（调用语法零变化）
1. 新建 `lib/pages/page_jump.dart`（约 35 行）：把 `jump()` 原方法体搬入 `extension PageJump on PageJumpTarget`，import 两个页面 + `foundation/context.dart`（`context.to` 扩展来自这里）+ `foundation/log.dart`。
2. `models.dart:537-560`：删除整个 `jump()` 方法。
3. `comic_source.dart:14-15`：删除两个 import。
4. 三个调用点文件顶部各加 `import 'package:venera/pages/page_jump.dart';`——`x.jump(context)` 调用点**一行不用改**。
改动量：净 ~60 行（删 27 + 新文件 35 + 3 行 import）。风险最低的一项。

### d) 风险点
- Dart 中**成员方法优先于扩展方法**：必须确认 models.dart 里的 `jump` 已删干净，否则扩展静默失效。改完全局再 grep 一次 `\.jump(`（当前仅 3 个调用点 + 1 个定义，已核实）。
- 3 个调用点若漏加 import，编译期即报错，不会静默出错——安全。
- `PageJumpTarget.parse` 等解析工厂保留在 foundation，不动。

---

## 2. js_engine → components：JsEngine mixin 了 UI 对话框能力 —— ✅ 已完成

实现与原方案一致，并采纳了风险点中的全部缓解建议：
1. `lib/foundation/js_engine.dart:40-46`：`abstract class JsUiHandler { dynamic handleUIMessage(Map<String, dynamic> message); void onEngineReset() {} }`——按风险点建议加了可选 `onEngineReset()`。
2. `js_engine.dart:66`：`static JsUiHandler? uiHandler;`；`:194-200` `case "UI":` null 分支为 `Log.warning` + 返回 null（可观测降级）。
3. `js_engine.dart:79`：`reset()` 内调用 `uiHandler?.onEngineReset()`。
4. `components/js_ui.dart:11`：`class JsUiApiImpl implements JsUiHandler`，`onEngineReset()` 关闭全部遗留 loading dialog 并清空 map。
5. 注册：`main.dart:34` `JsEngine.uiHandler = JsUiApiImpl();`——位于 `await init()` **之前**（按风险点缓解方案：init 期间漫画源加载即可能执行 JS 发 UI 消息）。
6. headless 模式不注册，`uiHandler` 为 null 走 warning 降级路径（比原先 `App.rootContext` null 崩溃更健壮）。

实施中发现并修复的 bug：接口定义后漏掉了注册步骤（`uiHandler` 从未被赋值），导致所有 JS UI 请求被静默丢弃——已补上 main.dart 注册。

---

## 3. favorites → follow_updates_page：收藏管理器直接调页面刷新函数 —— ✅ 已完成

实现与原方案一致：
1. `favorites.dart:214`：`static void Function()? onFollowUpdatesChanged;`
2. `favorites.dart:977-979`：`if (followUpdatesFolder == folder) { onFollowUpdatesChanged?.call(); }`，页面 import 已删除。
3. 注册：`main_page.dart:47` `_MainPageState.initState` 中 `LocalFavoritesManager.onFollowUpdatesChanged = updateFollowUpdatesUI;`（按统一注册点约定）。dispose 未置 null——赋值的是顶层函数，重复赋值无害。

原方案分析保留供参考：`updateFollowUpdatesUI()` 定义于 `follow_updates_page.dart:594-597`，通过 `GlobalState.findOrNull` 刷新页面私有 State，因此无法搬入 foundation，只能回调反转。第 6c 项（FollowUpdatesService 迁入 foundation）将复用此回调字段，前置条件已满足。

---

## 4. local → reader：本地漫画管理器直接构造阅读器页面（已完成）

> ✅ **已完成（2026-07）**：按 c) 方案实施。`local.dart` 新增纯数据类 `ReaderLaunchData`（10 字段）与静态回调 `LocalComic.readerLauncher`；`read()` 的全部计算逻辑保留在 foundation，末尾改为 `launcher(ReaderLaunchData(...))`（null 分支 `Log.warning` 后 return）；`:13` 的 reader import 已删除（local.dart 已无任何 pages/components import）。UI 侧新增 `lib/pages/reader/reader_launcher.dart` 提供 `launchReader()`；`main_page.dart` 的 initState 注册 `LocalComic.readerLauncher = launchReader;`。两个调用点（`comic_page.dart:121`、`local_comics_page.dart:322`）因调用的 `read()` 签名不变而无需改动。`flutter analyze` 通过。

### a) 精确 import
`lib/foundation/local.dart:13`：
```dart
import 'package:venera/pages/reader/reader.dart';
```

### b) 反向依赖的实质
`LocalComic.read()`（`local.dart:110-158`）：前 ~30 行是纯业务逻辑（`HistoryManager().find` 查进度、按分组/平铺计算首个已下载章节），最后把结果塞进 `Reader` 的 11 个构造参数并导航（`local.dart:139-157`）：
```dart
App.rootContext.to(
  () => Reader(
    type: comicType,
    cid: id,
    name: title,
    chapters: chapters,
    initialChapter: history?.ep ?? firstDownloadedChapter,
    initialPage: history?.page,
    initialChapterGroup: history?.group ?? firstDownloadedChapterGroup,
    history: history ?? History.fromModel(model: this, ep: 0, page: 0),
    author: subtitle,
    tags: tags,
  )
);
```
调用方仅两处（都在 UI 层）：`comic_details_page/comic_page.dart:121`、`local_comics_page.dart:322`。

### c) 拆法：数据类 + 启动回调
1. `local.dart` 定义纯数据类 `ReaderLaunchData`（字段 = 上述 10 个参数），并加 `static void Function(ReaderLaunchData data)? readerLauncher;`。
2. `read()` 的全部计算逻辑（含 `History.fromModel` 构造）**保留在 foundation**，末尾改为 `readerLauncher?.call(ReaderLaunchData(...))`；删 `:13` import。章节选择逻辑从此可单测。
3. UI 侧新增小函数（放 `lib/pages/reader/reader.dart` 尾部或新文件 `reader_launcher.dart`，~8 行）：`void launchReader(ReaderLaunchData d) => App.rootContext.to(() => Reader(type: d.type, ...));`
4. 注册：`main_page.dart` 的 `_MainPageState.initState`（:41）加 `LocalComic.readerLauncher = launchReader;`。
改动量：~50 行（数据类 15 + read() 改造 10 + launcher 8 + 注册 2 + import 调整）。

### d) 风险点
- 注册时机安全：`read()` 只能由用户点击触发（两个调用点都是按钮回调），那时 main_page 早已初始化。
- **字段同步成本**：今后 `Reader` 增删构造参数时，需同步改 `ReaderLaunchData` 和 `launchReader` 两处——在两处各加一行互相指引的注释即可；这是用“少量维护成本”换“foundation 不再依赖 5,455 行 reader 库”，划算。
- `App.rootContext` 的用法不变（本就在 foundation/context.dart 合法）。
- 若 `readerLauncher` 为 null（理论上只有 headless 调 read() 才会发生），改为 no-op + Log.warning，与现状（headless 调 read 会崩）相比是改善。

---

## 5. cloudflare → webview：网络层直接开 WebView 页做人机验证

### a) 精确 import
`lib/network/cloudflare.dart:9`：
```dart
import 'package:venera/pages/webview.dart';
```
（连带 `:4` 的 `flutter_inappwebview` import 也只为这两段 UI 代码服务。）

### b) 反向依赖的实质
`passCloudflare(CloudflareException e, void Function() onFinished)`（`cloudflare.dart:101+`）：收到 403 challenge 后需要**交互式 WebView** 让用户过人机验证。两段 UI 依赖：
- Linux 分支（:124-161）：`DesktopWebview`（定义于 `pages/webview.dart:239`）轮询 `document.head/body.innerHTML` 检测 `#challenge-success-text`；
- 桌面/移动分支（:162-221）：`App.rootContext.to(() => AppWebview(...))`（`AppWebview` 定义于 `pages/webview.dart:55`），含 `onTitleChange`/`onLoadStop` 检查、UA 捕获写 `appdata.implicitData`、cookie 保存、成功后 `App.rootPop()`。
调用方：仅 `components/loading.dart:66`（错误弹窗的 “Verify” 按钮）。`network/app_dio.dart` 的拦截器只负责抛出 `CloudflareException`（不调用本函数）；`pages/aggregated_search_page.dart:162` 仅字符串匹配异常用于展示。

### c) 拆法：交互验证回调注入
1. `cloudflare.dart` 加：`static Future<void> Function(String url, void Function(Map<String, String> cookies) saveCookies, void Function(String ua) saveUa, void Function() onFinished)? interactiveVerifier;`（cookie/UA 回写是网络/数据层职责，以回调参数传入，避免 webview.dart 依赖 cookie_jar）。
2. 把 :124-161 与 :162-221 共 ~90 行原样移到 `pages/webview.dart` 新顶层函数 `cloudflareVerifyInteractive(...)`，内部继续使用 `DesktopWebview`/`AppWebview`；`cloudflare.dart` 同时删 `:4`、`:9` 两个 import。
3. 注册：`main_page.dart` initState `CloudflareInterceptor.interactiveVerifier = cloudflareVerifyInteractive;`（或挂在 `passCloudflare` 所在顶层，按实际代码组织放）。
4. `passCloudflare` 主体保留：challenge 检测、cookie 域处理（:107-121 的 `saveCookies`）、`onFinished` 编排，仅在需要交互时调用 `interactiveVerifier`；为 null 时直接 `onFinished()` + Log.warning。
改动量：~110 行（移动 ~90 + 胶水 ~15 + 注册 2）。**清单中最大的一项。**

### d) 风险点
- **触发时序**：Dio 拦截器在任意请求 403 时触发。启动早期（main_page init 之前）若已有请求命中 Cloudflare（如自动检查漫画源更新），verifier 尚未注册——回退分支必须定义清楚（建议：直接 `onFinished()` 并记日志，让用户重试，优于崩溃）。当前代码在无 WebView 环境下同样会失败，不算回退。
- **成功路径的原子性**：现有代码里 cookie 保存、UA 写入、`rootPop`、`onFinished` 的顺序（先存 cookie 再 pop 再回调）必须在搬迁时逐行保持，改完用真实 CF 站点回归一次（这是唯一无法用编译器验证的项）。
- Linux 分支的 `success` 标志与用户手动关窗（`onClose`）路径要完整迁移——漏掉会让用户关窗后永远卡住。
- `DesktopWebview.isAvailable()`（webview.dart:241）检查留在 UI 侧，cloudflare 不再感知平台差异——反而更干净。

---

## 6. init → pages：初始化层调用页面类的静态方法（6a/6b 已完成）

### a) 精确 import
`lib/init.dart:14-15`（原有 3 个，settings_page 已通过 6b 解除）：
```dart
import 'package:venera/pages/comic_source_page.dart';
import 'package:venera/pages/follow_updates_page.dart';
```

### b) 反向依赖的实质（三个子项）
- **6a** ✅ 已完成：原 `ComicSourcePage.checkComicSourceUpdate()`（纯逻辑：`AppDio` 拉取源列表 → `compareSemVer`（`parser.dart:4` 顶层函数，同属 comic_source 库）比对 → `updateAvailableUpdates`）已移入 `ComicSourceManager.checkUpdates()`（`comic_source.dart`，为此新增 `appdata`、`network/app_dio` 两个 import，均为合法的正向依赖，不产生新循环）。三处调用点（`init.dart`、`comic_source_page.dart`、`headless.dart`）已改调 `ComicSourceManager().checkUpdates()`，`init.dart` 的 comic_source_page import 已删除。
- **6b** ✅ 已完成（实现与原方案不同）：未移到 main_page.initState，而是新增 `App.appUpdateUiHandler` 回调字段（`foundation/app.dart:113`），`main.dart:77` `_MyAppState.initState` 注册 `App.appUpdateUiHandler = checkUpdateUi;`，`init.dart:114-116` 改为 `await App.appUpdateUiHandler?.call(false, true);`。init.dart 的 settings_page import 已删除。注册（:77）早于 `checkUpdates()`（:80），时序安全。
- **6c** `init.dart:121` `FollowUpdatesService.initChecker()`——服务类定义在 `follow_updates_page.dart:537-591`，但它的全部业务依赖（`updateFolder`）本就在 `foundation/follow_updates.dart:172`，服务类只是被错放在页面文件里；它还调 `updateFollowUpdatesUI()`（:575）和 `DataSync().addListener(updateFollowUpdatesUI)`（:585）。
调用链：`main.dart:80` → `checkUpdates()`（init.dart:119-122）→ 6a/6c。

### c) 拆法（仅剩 6c，完成后删 init.dart:14-15）
- **6a**：✅ 已完成，见 b) 节。
- **6b**：✅ 已完成，见 b) 节。
- **6c（~55 行，前置第 3 项已完成）**：`FollowUpdatesService` 整体（:537-591）移到 `foundation/follow_updates.dart`；内部两处 `updateFollowUpdatesUI()` 改为第 3 项引入的 `LocalFavoritesManager.onFollowUpdatesChanged?.call()`；`:585` 的 DataSync 监听改为 `DataSync().addListener(() => LocalFavoritesManager.onFollowUpdatesChanged?.call())`；`init.dart:121` 调用不变（foundation→foundation 合法）。注意 `updateFollowUpdatesUI()` 函数本体（:594-597）须留在页面文件。
改动量：剩余 ~55 行（6c），删 init.dart:14-15。

### d) 风险点
- 6a：✅ 已完成。**修正原方案判断**：`headless.dart:90` 仍调用 `ComicSourcePage.update(source, false)`，因此 headless 的 comic_source_page import 无法随 #6a 删除——“headless 摆脱 UI”需另行处理 `update` 方法（其含 LoadingDialog/`App.rootContext` 等 UI 依赖，超出本项范围）。
- 6b：✅ 已完成。回调注册在 main.dart:77，早于 checkUpdates()（:80），无时序问题。
- 6c：前置第 3 项已完成（回调字段已存在）。`DataSync` 监听目前就是进程级一次性注册（`_isInitialized` 守卫），搬迁后语义不变；headless 模式下 `initChecker` 也会运行（main.dart:80 → checkUpdates），此时回调为 null，安全降级。
- 删 `init.dart:15` 前确认 `follow_updates_page` 在 init 中没有其它隐式用途（已 grep，仅 :121 一处）。

---

## 推荐实施顺序（剩余项，按改动量从小到大）

| 顺序 | 项 | 改动量 | 风险 | 说明 |
|---|---|---|---|---|
| — | ~~#3 favorites → 回调~~ | ~10 行 | — | ✅ 已完成 |
| — | ~~#6b checkUpdateOnStart → App.appUpdateUiHandler~~ | ~8 行 | — | ✅ 已完成（实现与原方案不同） |
| — | ~~#2 JsEngine UI 委托~~ | ~35 行 | — | ✅ 已完成（实施中修复了注册缺失 bug） |
| — | ~~#6a checkComicSourceUpdate 入 ComicSourceManager~~ | ~35 行 | — | ✅ 已完成（headless import 因 :90 仍用 `update` 而保留） |
| — | ~~#4 LocalComic.read → ReaderLaunchData~~ | ~50 行 | — | ✅ 已完成（新增 reader_launcher.dart；章节选择逻辑从此可单测） |
| 1 | **#6c** FollowUpdatesService 入 foundation | ~55 行 | 中 | 前置 #3 已完成；含 DataSync 监听语义 |
| 2 | **#1** PageJumpTarget.jump → 扩展方法 | ~60 行 | 极低 | 语法零变化，纯体力活 |
| 3 | **#5** cloudflare 交互验证注入 | ~110 行 | 中 | 最大项；需真实 Cloudflare 站点回归 |

> 建议每项独立 commit。全部完成后跑一次 `grep -rn "import 'package:venera/pages/" lib/foundation/ lib/network/` 应为空；`grep -rn "import 'package:venera/components/" lib/foundation/ lib/network/` 会命中 `foundation/context.dart:2`（`showToast`）——作为已知项豁免，或将 `showMessage` 移出 context.dart。

*行号于 2026-07 按当前工作区代码重新核实（venera 1.6.3 fork，#2/#3/#6b 实施后）。*
