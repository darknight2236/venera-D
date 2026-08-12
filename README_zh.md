<p align="center">
  <img src="assets/app_icon.png" width="120" alt="Venera-D 应用图标"/>
</p>

# venera-D

[English](README.md) · **简体中文**

[![flutter](https://img.shields.io/badge/flutter-3.44.6-blue)](https://flutter.dev/)
[![License](https://img.shields.io/github/license/darknight2236/venera-D)](https://github.com/darknight2236/venera-D/blob/master/LICENSE)
[![stars](https://img.shields.io/github/stars/darknight2236/venera-D?style=flat)](https://github.com/darknight2236/venera-D/stargazers)

一款支持阅读本地与网络漫画的跨平台漫画阅读器。

> **关于本 fork**
> `venera-D` 是 [venera](https://github.com/venera-app/venera) 的 fork（上游已停止维护）。
> 本 fork 在保留全部原有功能的同时，一方面持续进行**代码质量治理**（降低耦合、增加可测试性、令设置层类型安全，
> 详见 [架构与解耦](#架构与解耦)），另一方面在上游基础上**主动添加新功能**（见 [venera-D 新增功能](#venera-d-新增功能)）。

## 功能

- 阅读本地漫画
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
- 直接打开有进度的漫画（不经过详情页）时可选择「从头开始」或「继续上次阅读」（详情页本身已有 Start/Continue 按钮）
- 可选的翻页白屏刷新，减少墨水屏残影

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

## 从源码构建

1. 克隆本仓库。
2. 安装 Flutter —— 参见 [flutter.dev](https://flutter.dev/docs/get-started/install)（Flutter `3.44.6`，Dart SDK `>=3.8.0`）。
3. 安装 Rust —— 参见 [rustup.rs](https://rustup.rs/)。
4. 针对目标平台构建，例如：
   - Android：`flutter build apk`
   - Windows：`flutter build windows --release`
   - Linux：`flutter build linux --release`
   - macOS：`flutter build macos --release`
   - iOS：`flutter build ipa`

## 文档

- [创建漫画源](doc/comic_source.md) —— 如何编写 JavaScript 漫画源
- [JS API 参考](doc/js_api.md) —— 提供给漫画源的 JavaScript 桥接 API
- [导入漫画](doc/import_comic.md) —— 导入本地漫画文件
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
