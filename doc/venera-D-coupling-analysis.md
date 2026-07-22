# venera-D 耦合度分析报告（thorough 级）

> 分析对象：`D:\CodingProjects\venera-D`（venera 1.6.3 fork）
> 规模：lib/ 共 135 个 Dart 文件，约 47.9k 行（foundation 9,305 / network 2,538 / pages 23,773 / components 8,731 / utils 3,337）；test/ 仅 1 个文件。
> **2026-07 更新**：层级倒置改造已部分完成（原 6 处 → 现存 4 处）：`js_engine→components` 已通过 `JsUiHandler` 接口委托解除，`favorites→follow_updates_page` 已通过静态回调解除，`init.dart` 的 settings_page import 已通过 `App.appUpdateUiHandler` 回调解除。reader 大库行数等统计数字已按当前代码重新核实。

---

## 一、总体评估

**结论先行：耦合度为"中高"，但耦合有明确的中心——`appdata` 与 `App` 两个全局对象 + 一组工厂单例。**
问题不在"到处乱连"，而在于：(1) 领域层反向 import UI 层形成 4 组 import 循环；(2) 大库（part 机制）让私有成员在数千行内共享，形成隐形上帝对象；(3) 没有任何抽象接口，单例不可替换，测试被结构性封死。

核心数字：

| 指标 | 数值 | 证据 |
|---|---|---|
| `App`（服务定位器）被引用文件数 | **73**（pages+components 43 / foundation 13 / network 4 / utils 11） | `final App = _App()` 定义于 `lib/foundation/app.dart:112` |
| `appdata` 被引用文件数 | **47**；`appdata.settings` 全项目引用 **240 处**，其中 lib/pages 内 **129 处** | `final appdata = Appdata._create()` 定义于 `lib/foundation/appdata.dart:169` |
| `appdata.settings[...] =` 直接写入点 | **51 处**（无中间层），`appdata.saveData()` 调用 34 处 | 散布于 5 个 settings 文件 + 阅读器等 |
| `App.rootContext`（全局 BuildContext）使用文件数 | **36** | `app.dart` 的 `rootNavigatorKey` |
| `ComicSource.find()` 静态注册表使用文件数 | **28** | `comic_source.dart:113` |
| import 循环依赖组 | **4 组**（见下） | 静态 import 图分析 |
| foundation/network 反向 import pages/components | **4 处**（原有 6 处，已修复 js_engine、favorites 两处；见下） | 层级倒置 |
| 单元测试 | test/ 仅 `channel_test.dart`，只测了 `utils/channel.dart` 这一个无依赖工具类 | — |

---

## 二、全局状态/单例耦合（问题 1）

### 2.1 单例清单与引用分布

| 单例 | 定义位置 | 实现方式 | 被引用文件数 | 其中 UI 层 |
|---|---|---|---|---|
| `appdata` | `foundation/appdata.dart:169` | 顶层 `final` 全局变量 | 47 | 34 |
| `App` | `foundation/app.dart:112` | 顶层 `final _App()`，服务定位器（持有 `data`/`history`/`favorites`/`local` + navigator keys + `rootContext`） | 73 | 43 |
| `CacheManager()` | `foundation/cache_manager.dart:90` | factory + static instance | 11 | 5 |
| `HistoryManager()` | `foundation/history.dart:186` | factory 单例 + ChangeNotifier | 13 | 7 |
| `LocalFavoritesManager()` | `foundation/favorites.dart:206` | factory 单例 + ChangeNotifier | 21 | 12 |
| `LocalManager()` | `foundation/local.dart:176` | factory 单例 + ChangeNotifier | 22 | 11 |
| `ComicSourceManager()` | `foundation/comic_source/comic_source.dart:42` | factory 单例 + ChangeNotifier | 10 | 4 |
| `JsEngine()` | `foundation/js_engine.dart:60` | factory 单例 | 9 | 2 |
| `ComicSource.find()` | `comic_source.dart:113` | 静态注册表（全局可查） | 28 | 大量 |
| `GlobalState` | `foundation/global_state.dart:4` | **全局 Widget State 注册表**（`static _state` 列表，find 任意页面的 State 对象） | 3 页（explore / follow_updates / reader gesture） | — |

### 2.2 UI 层直接读写 foundation 全局状态——确认属实

- **Settings 没有任何中间层**。设置页直接 `appdata.settings['key'] = value`，例如 `lib/pages/settings/reader.dart:78`、`:209`、`:211`；5 个 settings 文件（app/appearance/explore_settings/network/reader + setting_components）全部直接读写。Settings 是一个 60+ 个字符串 key 的 `Map<String, dynamic>`（`appdata.dart:174-240`），key 是魔法字符串，值为 dynamic，编译期无法检查。
- **阅读器是重灾区**：`lib/pages/reader/` 8 个文件中对全局单例/管理器的引用共 **56 处**，其中 `appdata.settings` 直接引用 **38 处**（含预读数 `preloadImageCount`：`images.dart:158`、`:682`）。
- **网络层也直接读全局设置**：`network/app_dio.dart` 在请求路径上直接读 `appdata.settings`（proxy `:179`、sni `:194`、证书 `:195`、DNS 覆盖 `:201-204`）；`network/cloudflare.dart` 8 处引用 appdata。
- 状态变更通知靠 `Settings` 是 ChangeNotifier + `notifyListeners()`（`appdata.dart:246-251`），但全项目只有 4 个页面真正 `addListener`（categories/explore/side_bar/search），其余页面靠进入时重读或手动 setState——**通知模型不一致**，是典型的单例蔓延症状。

### 2.3 特殊隐患

- **~~两个同名的 `JsEngine` 单例类~~（已解决，2026-07）**：原 `foundation/js_engine.dart:59`（漫画源 JS 引擎）与 `utils/image.dart:196`（自定义图片处理引擎）同名，都包 FlutterQjs、都是 factory 单例。后者已重命名为 `ImageProcessEngine`（仅 `utils/image.dart` 内部使用；`network/images.dart:8`、`utils/pdf.dart:7` 虽 import 该文件但不引用此类）。`foundation/image_provider/reader_image.dart:5` import 前者。
- **JS 引擎有自己独立的网络栈**：`js_engine.dart` 自建 `AppDio`（`resetDio()`）、自建 cookie jar，并通过 `_messageReceiver` 暴露 **50 个桥接方法**（`case "..."` 计数），其中直接读写 `ComicSource.find(key)` 的持久化数据（`js_engine.dart:132-173`）。Dart 侧与 JS 侧共享可变状态，无边界。

---

## 三、跨模块 import 分析（问题 2）

### 3.1 层级倒置：foundation/network 反向 import UI 层（现存 1 处，原有 6 处，5 处已解除）

| 倒置点 | 位置 | 用途 | 状态 |
|---|---|---|---|
| ~~`foundation/comic_source/comic_source.dart:14-15`~~ | ~~import `pages/category_comics_page.dart` + `pages/search_result_page.dart`~~ | ~~领域模型 `PageJumpTarget.jump()` 直接 new 页面 Widget 并跳转（`models.dart:537-560`）~~ | **已解除**：`PageJumpTarget.jump()` 移至 pages 侧扩展 `pages/page_jump_target_ext.dart`（#1），comic_source.dart 不再 import pages |
| ~~`foundation/js_engine.dart:25`~~ | ~~import `components/js_ui.dart`~~ | ~~`JsEngine` mixin 了 `JsUiApi`~~ | **已解除**：改为 `JsUiHandler` 抽象接口（`js_engine.dart:40-46`）+ `components/js_ui.dart` 的 `JsUiApiImpl` 实现，`main.dart` 启动时注册 |
| ~~`foundation/favorites.dart:12`~~ | ~~import `pages/follow_updates_page.dart`~~ | ~~收藏管理器反向依赖页面~~ | **已解除**：改为 `static void Function()? onFollowUpdatesChanged` 回调（`favorites.dart:214`），`main_page.dart:47` 注册 |
| ~~`foundation/local.dart:13`~~ | ~~import `pages/reader/reader.dart`~~ | ~~本地漫画管理器依赖阅读器页面~~ | **已解除**：改为纯数据 `ReaderLaunchData`（local.dart:22）+ `LocalComic.readerLauncher`，由 UI 层消费，foundation 不依赖 pages |
| `network/cloudflare.dart:9` | import `pages/webview.dart` | Cloudflare 绕过直接开 WebView 页面 | **豁免**：#5 因无 Linux 测试环境取消改造，作为已知豁免保留 |
| ~~`init.dart:14-15`~~ | ~~import 2 个 pages 文件（原有 3 个）~~ | ~~初始化层依赖 UI~~ | **已解除**：3 个 pages import 全部经回调反转（settings_page 经 `App.appUpdateUiHandler` 等），init.dart 不再 import pages |

补充（✅ 已解决，2026-07）：原 `foundation/context.dart:2` import `components/components.dart`（`showToast`）。已将 `showMessage` 移至 `components/message.dart` 的 `ToastExtension`，context.dart 不再 import components（调用方 `utils/io.dart` 补 import components，与 import_comic.dart 先例一致）。**至此 foundation/ 对 pages 与 components 的反向 import 全部清零。**

补充（✅ 已解决，2026-07）：原 `headless.dart:7` import `pages/comic_source_page.dart`（仅为调用静态方法 `ComicSourcePage.update(source, false)`）。已将该方法的纯逻辑下沉为 `ComicSourceManager.updateSource()`（foundation/comic_source，含 URL 校验/拉取/解析/写文件，可选 `isCancelled` 轮询供 UI 取消），headless 改调 `updateSource()` + `reload()`；`ComicSourcePage.update` 保留为 UI 包装（loading dialog/toast/forceRebuild）。headless 不再 import pages。

后果（✅ 已大幅缓解，2026-07）：原 foundation/network 反向 import UI 层使其无法脱离 UI 复用/测试，headless 也被迫拖入 `pages/comic_source_page.dart`。经 §3.1 各项解除，foundation/ 已零反向 import，headless 亦不再依赖 pages。**反向 import 仅剩 `network/cloudflare.dart:9`（#5 因无 Linux 环境取消，已知豁免）。**

### 3.2 import 循环依赖（4 组）

1. `foundation/app.dart` <-> `foundation/local.dart`
2. `foundation/app.dart` -> `foundation/local.dart` -> `foundation/history.dart` -> `app.dart`
3. `foundation/app.dart` <-> `foundation/favorites.dart`
4. `foundation/comic_source/comic_source.dart:22` <-> `foundation/js_engine.dart:33`

第 4 组最关键：**漫画源解析器与 JS 引擎互相 import**——parser 跑 JS 需要引擎，引擎的桥接 API 又要回查 ComicSource 数据（`js_engine.dart:132-173`）。两者事实上是一个不可分割的整体。

### 3.3 上帝文件

**被依赖最多（fan-in）**：`foundation/app.dart` **53**（含相对 import）、`comic_source/comic_source.dart` **32**、`utils/translations.dart` 27、`utils/ext.dart` 26、`foundation/appdata.dart` 25、`foundation/log.dart` 24、`utils/io.dart` 24、`components/components.dart` 22。

**依赖别人最多（fan-out）**：`pages/reader/reader.dart`（库）**43** 个 import、`components/components.dart` 26、`comic_details_page/comic_page.dart` 23、`favorites/favorites_page.dart` 23、`home_page.dart` 20、`comic_source.dart` 17。

**pages 之间互相 import**：存在且不少（约 17 条边），如 home_page import 7 个其他页面、favorites <-> comic_details 互引、search_page <-> search_result_page 互引。这是 Flutter 页面跳转的常见模式，不算病态，但叠加在层级倒置之上加剧了循环。

### 3.4 part 大库 = 扩大版上帝文件

Dart 的 `part/part of` 让多个文件共享同一个私有作用域。项目中 4 个大库：

| 库 | 文件数 | 总行数 | 风险 |
|---|---|---|---|
| `pages/reader/reader.dart` | 8 | **5,455** | `_ReaderState` 有 **~78 个可变状态字段**（grep 统计），所有 part 通过 `context.reader` 扩展（`reader.dart:62-67`）直接读写彼此的私有成员（`reader._page`、`reader.images`、`reader.isLoading`...），**零封装** |
| `pages/settings/settings_page.dart` | 10 | 3,246 | reader.dart:35 import 整个 3,246 行 settings 库只为打开设置子页 |
| `foundation/comic_source/comic_source.dart` | 6 | 2,698 | parser.dart 一个文件 1,301 行 |
| `components/components.dart` | 19 | ~8,700 | barrel + part 混合，改任一组件需重编译整个库 |

---

## 四、UI 与业务逻辑混合（问题 3）

**阅读器：业务逻辑没有独立层，全部长在 Widget State 里。**

- 加载逻辑在 `_ReaderImagesState.load()`（`images.dart:37+`）——一个 State 类里直接串行调用 `LocalManager().isDownloaded()` -> `ComicSource.find()` -> `CacheManager().findCache()`（`images.dart:614`、`:1198`）-> JS 引擎，结果直接写回 `reader.images` / `reader.isLoading`。
- 预读逻辑分散在 `_GalleryModeState`（`images.dart:154-656`）和 `_ContinuousModeState`（`:657-1264`）两个 State 类中，各自重复读取 `appdata.settings["preloadImageCount"]`（`:158`、`:682`）。
- 翻页/手势/章节切换/历史记录更新交叉引用：`scaffold.dart:755,762` 在 UI 构建中调 `ComicSource.find()`；历史写入由 reader 直接调 `HistoryManager()`。
- 结论：reader 是一个 5,455 行的"UI + 状态机 + 业务逻辑"单体，拆出任何一块都会牵动私有成员网。

**settings：无中间层**（已在 2.2 说明）——设置页 = appdata 的直接投影。

---

## 五、网络层耦合（问题 4）

- **JS 引擎 <-> 网络/缓存**：JS 引擎自建独立 `AppDio` + cookie jar（`js_engine.dart` `resetDio()`），与主网络栈并行；漫画源的网络请求实际由 JS 侧发起，Dart 侧通过 50 个桥接方法兜底。缓存则由 `CacheManager()`（sqlite，构造函数直接打开 `App.dataPath` 下的 db，`cache_manager.dart:78-83`）被阅读器、图片 provider、漫画源三处共享调用。
- **comic_source <-> 下载/阅读器耦合点**：
  - `network/download.dart` import `foundation/comic_source`（`:8`）+ `foundation/local` + `foundation/appdata`，下载任务直接操作漫画源模型与本地库。
  - `foundation/image_provider/reader_image.dart` import `flutter_qjs` + `js_engine` + `network/images`，**图片 Provider 里执行 JS 脚本处理图片**（`reader_image.dart:58-62` 读 `appdata.settings['customImageProcessing']` 并 `JsEngine().runCode(...)`）。
  - `foundation/local.dart:12-13` import `network/download.dart` + `pages/reader/reader.dart`——本地库同时钩住下载层和 UI。
- 整条链路 `漫画源(JS) -> 网络(Dio/双栈) -> 缓存(sqlite) -> 图片Provider(JS) -> 阅读器` 每一环都直接实例化对方，没有接缝。

---

## 六、可测试性（问题 5）

**全局单例全部不可替换**：`Appdata`/`HistoryManager`/`LocalFavoritesManager`/`LocalManager`/`CacheManager`/`ComicSourceManager`/`JsEngine` 都是**具体类 + 私有构造 + factory 单例**，无覆盖/注入机制（foundation/network 下的 abstract 类只有 GlobalState、BaseImageProvider、DownloadTask、ImageDownloader 等少数几个，加上改造后新增的 `JsUiHandler`（js_engine.dart:40），均不覆盖状态管理器）。

为什么 test/ 几乎为空——**结构性地阻碍测试**：

1. 任何想测的类在构造/方法里直接 `appdata.settings[...]`、`App.dataPath`、`ComicSourceManager()`——测试必须先跑通 `init()`（`init.dart:41-74`），而 init 依赖 path_provider（平台 channel）、sqlite3、QuickJS native 库。
2. `CacheManager._create()` 构造函数里直接 `sqlite3.open('${App.dataPath}/cache.db')`（`cache_manager.dart:80`）——连构造都过不了。
3. 即使想 mock，也没有注入点：`appdata` 是顶层 final 变量，`App` 同理，Dart 里无法替换。
4. 唯一的测试 `test/channel_test.dart` 测的是 `utils/channel.dart`——全项目唯一一个零单例依赖的纯 Dart 组件。这不是巧合，是证据。

---

## 七、最严重的耦合点（按严重度排序）

1. **reader 大库（5,455 行，8 parts，~78 个共享可变字段）**——维护者未来 80% 的改动会落在这里，而它是全项目封装最差、全局引用最密（56 处单例引用）的地方。任何 bug fix 都要在私有成员交叉网中排雷。
2. **`appdata`/`App` 全局双核 + 无中间层**——240 处 `appdata.settings` 引用、51 处直写、73 个文件摸 `App`。字符串 key 无类型安全，改一个 key 的名字要靠全文搜索。好在它"中心化"，是唯一"乱得还算可控"的点。
3. **foundation/network -> pages 的 4 处层级倒置（原 6 处）+ 4 组 import 循环**——封死了 foundation 的独立复用与测试，也是 `headless` 模式被迫拖入 UI 的原因。其中 `comic_source <-> js_engine` 循环（`comic_source.dart:22` / `js_engine.dart:32`）让核心解析链路无法单独验证。
4. **双网络栈 + JS 桥接 50 方法**——主 AppDio 与 JS 引擎内置 Dio 并行，代理/证书/DNS 设置要在两处生效；JS 侧可读写 ComicSource 持久化数据。这里是"线上 bug 最难排查"的区域。
5. ~~**两个同名 `JsEngine` 类**~~（✅ 已解决，2026-07）：`utils/image.dart` 的已重命名为 `ImageProcessEngine`，`foundation/js_engine.dart:59` 保留 `JsEngine` 名。

---

## 八、结论与解耦建议（务实版，面向单人维护）

**是否需要解耦？需要，但只解"会咬人的"，不要追求架构纯净。** 这个项目本质是"以 `appdata`/`App` 为中心的单体"，对单人维护的 fork 来说单体不是原罪；真正伤害维护效率的是：reader 大库、层级倒置、不可测试、命名地雷。

### 值得做（按优先级）

| 优先级 | 事项 | 成本 | 收益 |
|---|---|---|---|
| **P0** | **层级倒置**（🟢 基本完成，2026-07）：原 6 处 →pages 倒置已解除 5 处（`js_engine`/`favorites`/`comic_source`/`local`/`init`，机制见 §3.1 表），foundation 对 pages 与 **components** 的反向 import 已**全部清零**（context.dart 的 `showMessage` 移至 `components/message.dart`）。**仅剩** `network/cloudflare.dart:9`→`pages/webview.dart`（#5 因无 Linux 环境取消，已知豁免）。详见 `layer-inversion-refactor-plan.md` | 1 天 | foundation/network 恢复可独立编译，headless 和未来的测试解锁 |
| ~~P1~~ | ~~重命名 `utils/image.dart` 的 `JsEngine`~~（✅ 已完成，改为 `ImageProcessEngine`） | 半天 | 消除随时会爆的混淆 |
| **P1** | **给单例加测试接缝**（🟡 两个全局对象已完成，2026-07）：`Appdata`（`forTesting()` 无 I/O 构造 + 纯 `loadFromJson()` + `appdata` getter+setter，测试见 `test/appdata_test.dart`）与 `App`（`final App` 改 getter+`@visibleForTesting` setter + `createAppForTesting()` 工厂，测试见 `test/app_test.dart`）均已落地，共 5 项测试通过。**剩余（受阻）**：factory managers（HistoryManager/CacheManager/LocalFavoritesManager/LocalManager）的接缝本身易加（已有 static 字段），但其数据逻辑测试需 sqlite，而 `flutter test` VM 无法加载 `sqlite3.dll`（已实证，error 126）——需先解决测试环境的 sqlite native 库供给（如 `open.overrideFor` 指定 dll）方能推进。不需要 DI 框架 | 1 天 | 让“为核心逻辑写回归测试”成为可能——接手停更 fork 最需要的安全网 |
| **P2** | **reader 拆 part**：先把 `images.dart` 里的加载/预读逻辑（`load()`、`preCacheCount` 两处重复）抽成普通类 `ReaderImageLoader`（依赖注入 LocalManager/CacheManager），UI State 只持有它。不必一次拆完，先切断"State 直接调 5 个单例" | 2-3 天 | 阅读器 bug 定位成本大幅下降 |
| **P3** | **Settings key 收敛**：为 `appdata.settings` 的 60+ 字符串 key 生成常量/typed getter（`appdata.dart:174-240`），逐步替换 240 处裸字符串 | 渐进 | 消除魔法字符串，重构敢动手 |

### 不建议做（过度工程）

- X 迁移到 Riverpod/Bloc：73 个文件摸 `App`、47 个摸 `appdata`，全量迁移是数周级的重写，单人维护没有收益。
- X 引入 get_it/injectable 等 DI 框架：P1 的手动接缝已够，框架只会增加学习/维护面。
- X 把 part 大库全部拆成独立库/引入 package 化：拆 reader 时顺手做掉关键一处即可，settings 库和 components 库"大而无害"，不值得专门动。
- X 追求 100% 测试覆盖：先给 comic_source parser、history、favorites 三个数据正确性最关键的模块各写几个测试，比铺开更有价值。

**一句话总结**：这个 fork 的耦合是"中心化的中等偏上耦合"——不会阻碍日常小修小补，但 reader 大库和层级倒置会在任何中等以上改动时显著放大小错误的影响面。按 P0->P3 顺序，投入约一周可以把"危险耦合"降到可接受水位，其余维持现状即可。

---

*分析方式：静态 import 图分析（135 文件）+ 单例引用 grep 计数 + 关键文件人工阅读（appdata/app/js_engine/comic_source/cache_manager/reader/images/settings 等）。2026-07 按当前代码状态复核更新。*
