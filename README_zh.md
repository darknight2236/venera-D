<p align="center">
  <img src="assets/app_icon.png" width="120" alt="Venera-D 应用图标"/>
</p>

# venera-D

[English](README.md) · **简体中文**

[![flutter](https://img.shields.io/badge/flutter-3.47.6-blue)](https://flutter.dev/)
[![License](https://img.shields.io/github/license/darknight2236/venera-D)](https://github.com/darknight2236/venera-D/blob/master/LICENSE)
[![stars](https://img.shields.io/github/stars/darknight2236/venera-D?style=flat)](https://github.com/darknight2236/venera-D/stargazers)

一款支持阅读本地与网络漫画的跨平台漫画阅读器。

> **关于本 fork**
> `venera-D` 是 [venera](https://github.com/venera-app/venera) 的 fork；上游不仅已停止维护，仓库本身也已
> **归档**（2026 年 4 月起转为只读），不会再有任何新改动从上游流入。
> 本 fork 在保留全部原有功能的同时，一方面持续进行**代码质量治理**（降低耦合、增加可测试性、令设置层类型安全，
> 详见 [架构与解耦](#架构与解耦)），另一方面在上游基础上**主动添加新功能**（见 [venera-D 新增功能](#venera-d-新增功能)）。

## 功能

- 阅读本地漫画 —— 可从目录、压缩包（`cbz` / `zip` / `7z` / `cb7`）与图片型 PDF 导入
- 使用 JavaScript 创建并加载网络漫画源
- 阅读来自网络源的漫画
- 管理收藏漫画（本地收藏夹与网络收藏夹）
- 下载漫画以供离线阅读
- 在源支持时查看评论、标签、评分等元数据
- 在源支持时登录以进行评论、评分等交互
- 提供 Headless 模式，用于无 GUI / 服务端场景

## venera-D 新增功能

在上游基础上新增的功能：

**阅读体验**

- 画廊模式默认对大幅图片降采样以获得更流畅的翻页（可在阅读设置中关闭）
- 左右阅读模式下可点击屏幕上下半区翻页
- 连续模式可设置固定的点击翻页滚动距离（适合条漫）
- 可选的翻页白屏刷新，减少墨水屏残影
- 首页历史缩略图显示阅读进度角标（当前章节页码，看完显示对勾），与历史页保持一致
- 列表缩略图显示收藏状态，网络收藏与本地收藏使用不同标识
- 宽屏与手机横屏下，折叠侧栏仍显示当前页面标题

**导入与格式**

- 图片型漫画 PDF 导入：每个 PDF 导入为一本漫画，JPEG 页逐字节直通、Flate 压缩页转换为 PNG。仅处理页面图片——
  纯文字或矢量页会给出明确提示，而不是导入成一本坏漫画。
- 支持加密 PDF（标准安全处理器 R2–R6：RC4-40/128、AES-128、AES-256）；用户密码为空的文件静默打开、不弹窗。
- 图片扩展名判断统一为大小写不敏感，目录扫描、封面查找与压缩包导入共用同一份列表

**管理与便捷**

- 历史记录搜索
- 本地收藏可按收藏时间或手动顺序排序
- 长按菜单可局部复制标题
- 可将漫画标题转换为简体中文显示

**稳定性**

- 下载管线加固：请求超时、单图失败容错、任务去重、重新下载时跳过已下载章节
- 本地收藏搜索统一简繁归一，简体关键词可匹配繁体内容

## 支持平台

Android · iOS · Windows · Linux · macOS

## 下载

每个 [Release](https://github.com/darknight2236/venera-D/releases/latest) 都会附带全平台的预构建产物：
Android（通用 APK，另有 `arm64-v8a` / `armeabi-v7a` / `x86_64` 三个分包）、Windows（`.zip` 与安装包 `.exe`）、
macOS（`.dmg`）、Linux（Debian `.deb` 与 Arch `.pkg.tar.zst`，均含 amd64 与 arm64）、iOS（`.ipa`）。

iOS 版本还会同步发布为 **AltStore 源**，无需本机重新构建即可安装与更新：在 AltStore 中添加下面的地址作为源，
然后安装 **Venera-D**。

```
https://raw.githubusercontent.com/darknight2236/venera-D/master/alt_store.json
```

该文件在每次发版后由流水线自动重写，始终指向最新构建。

## 从源码构建

1. 克隆本仓库。
2. 安装 Flutter —— 参见 [flutter.dev](https://flutter.dev/docs/get-started/install)（Flutter `3.47.6`，Dart SDK `>=3.8.0`）。
3. 安装 Rust —— 参见 [rustup.rs](https://rustup.rs/)。
4. 若要构建 Android，请安装 JDK 17 或更高版本。
5. 确认 `flutter pub get` 能取到打过补丁的 fork 依赖。其中三个以 SSH 方式锁定
   （`ssh://git@ssh.github.com:443/…`），原因是维护者的网络访问 github.com 的 HTTPS 不稳定。这三个都是
   **公开**仓库，因此如果你的环境用不了 443 端口的 SSH，执行一次下面的重写即可让 pub 匿名走 HTTPS 拉取：

   ```bash
   git config --global url."https://github.com/".insteadOf "ssh://git@ssh.github.com:443/"
   ```

6. 针对目标平台构建，例如：
   - Android：`flutter build apk`
   - Windows：`flutter build windows --release`
   - Linux：`flutter build linux --release`
   - macOS：`flutter build macos --release`
   - iOS：`flutter build ipa`

## 文档

- [创建漫画源](doc/comic_source.md) —— 如何编写 JavaScript 漫画源
- [JS API 参考](doc/js_api.md) —— 提供给漫画源的 JavaScript 桥接 API
- [导入漫画](doc/import_comic.md) —— 导入本地漫画文件，含 PDF 支持范围与已知不支持的页面/图片编码
- [Headless 模式](doc/headless_doc.md) —— 以无 GUI 方式运行

## 架构与解耦

本 fork 以渐进、低风险的方式推进重构，目标是长期可维护性（项目为单人维护的 fork，
因此原则是"只解会咬人的耦合"，而非追求架构纯净）：

- **消除层级倒置** —— `foundation`/`network` 不再反向 import UI 层，恢复了独立编译能力，
  并为 `headless` 模式与测试解锁。
- **测试接缝** —— `Appdata` 与 `App` 两个全局单例提供仅供测试的构造函数/设值入口，
  使单元测试无需触发 I/O 副作用。
- **类型安全的设置** —— 所有 settings key 现已收敛为编译期常量（`SettingKeys`），
  拼写错误从运行时静默失败升级为编译期错误。

完整状态与细节见 [耦合度分析报告](doc/venera-D-coupling-analysis.md) 与
[层级倒置重构计划](doc/layer-inversion-refactor-plan.md)。

## 致谢

### 标签翻译

漫画标签的中文翻译来自 [EhTagTranslation](https://github.com/EhTagTranslation/Database)。
