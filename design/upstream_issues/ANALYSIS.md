# 上游 Issues 分析报告（改进方向）

> 数据来源：`venera-app/venera`（上游，已归档只读）的全部 **142 个 open issue**，
> 采集于 2026-07（`fetch_upstream_issues.py`，原始数据见 `open_issues.json`）。
> 构成：**100 个 enhancement + 42 个 bug**（3 个附带 help wanted）。
>
> 本报告 = A（按主题分类清单）+ B（结合 venera-D 当前代码现状的可行性分析）。
> 分析基准：venera-D 已完成 page_math 分页抽取、6 单例测试接缝、UI token、
> 依赖漂移根治等治理；架构为 Flutter part library + foundation/network/utils 三模块。

---

## 一、主题分布（A：分类清单）

| 主题 | 数量 | 说明 |
|------|------|------|
| 阅读器 / 翻页 | 52 | 最大类：翻页模式、双页、连续滚动、跳转、缩放 |
| 本地漫画 / 收藏 | 45 | 收藏夹能力、标签、排序、目录结构、导入 |
| 崩溃 / 打不开 | 35 | 稳定性 bug，跨多平台 |
| 下载 | 32 | 下载队列、通知、导出、格式转换 |
| 平台特定 | 29 | Windows/macOS/iPad/HyperOS/ColorOS/ARM |
| UI / 交互 | 17 | 全屏、菜单、手势、封面标记 |
| 同步 / WebDAV | 16 | WebDAV 挂载、云端合并、跨端 |
| 格式支持 | 10 | epub/mobi/pdf/avif/动图 |

（主题有重叠，一个 issue 可能跨多类。）

---

## 二、可行性分析（B：结合 venera-D 现状）

按「价值 × 可行性」分四档。价值参考评论数（热度）+ 影响面；可行性参考 venera-D 当前代码结构。

### 🟢 第一梯队：高价值 + 与 venera-D 现状契合（建议优先）

| Issue | 类型 | 为什么契合 venera-D |
|-------|------|---------------------|
| **#839 阅读翻页明显卡顿** | BUG | 正是 venera-D 刚重构的 page_math / gallery_mode / continuous_mode 区域，代码已梳理清晰、有 102 测试兜底，定位和改动的安全网最好 |
| **#834 墨水屏白屏闪烁选项** | ENH | 小改动高价值：阅读器加一个"翻页时闪白"设置项，墨水屏用户刚需，改动集中在 reader，风险低 |
| **#249 顶部小横条全屏下仍显示** | BUG | 10 评论老 bug，纯 UI 层（scaffold），无深层耦合 |
| **#745 关动画后滑动翻页仍有动画** | BUG | 阅读器设置与实际行为不一致，定位明确 |
| **#487 / #816 / #601 下一话/翻页设置** | ENH | 多个关于"下一章上滑长度/下一话行为"的诉求，都落在 reader 设置，可合并处理 |
| **#807 / #461 本地收藏排序/能力** | ENH | LocalFavoritesManager 刚加了测试接缝，改动有回归保护 |

### 🟡 第二梯队：高价值但需较大投入 / 需先诊断

| Issue | 类型 | 说明 |
|-------|------|------|
| **#710 报错图片不显示（23 评论，最热）** | BUG | 最高热度，但可能与网络源/JS 处理相关；需先复现诊断根因，可能已被 venera-D 的 flutter_rust_bridge 修复部分缓解——**值得先查是否仍存在** |
| **#121 / #433 本地/下载漫画打开报错** | BUG | 数据层问题，涉及 LocalManager；接缝已在，可加测试复现 |
| **#707 / #799 下载卡在"获取图像列表"** | BUG/ENH | 下载队列逻辑，中等复杂度 |
| **#114 WebDAV 挂载下载（10 评论）** | ENH | 最热的功能请求，但 WebDAV 挂载是大功能，投入大 |

### 🔵 第三梯队：平台特定，取决于你能测的平台

- **#660 win10 打不开 / #756 armwin / #653 Windows 性能回退**：venera-D 有 Windows 构建能力，你在 Windows 上，**可复现可测**
- **#446 HyperOS 小窗 / #692 ColorOS 字体**：需对应设备才能验证
  （~~#770 iPad 齿轮~~：已核实为上游 `8370d2a`（2026-03-07）修复并随基线继承，issue 仅因上游归档未关闭，见“状态复核记录”）
- **#843 Winget / #576 rpm 包**：分发渠道增强，与 venera-D 的打包流程相关

### ⚪ 第四梯队：大功能 / 低契合 / 建议暂缓

- **#312 epub / #369 mobi / #431 pdf / #371 fodt**：格式支持是独立大模块，逐个都是不小的工程
- **#831 以图搜图 / #347 搜图 bot / #833 GPU 加速 / #634 Bangumi 追踪**：功能宏大，偏离"维护性 fork"定位
- 各种 WebDAV 高级玩法（#628/#675/#811/#568）：叠加在已很复杂的同步模块上

---

## 三、给 venera-D 的建议路线

结合你的定位（*fix what bites, not architectural purity* + 单人维护 fork + 有 Windows/iPad 测试环境）：

1. **先摘"契合刚完成的重构"的果实**：#839 翻页卡顿、reader 设置类（#487/#601/#816/#745）——这些正好在你刚梳理干净、有测试保护的 reader 区域，投入产出比最高。
2. **#834 墨水屏白屏**：典型的"小改动、特定人群刚需、好实现"，适合快速交付一个亮点。
3. **热门 bug 先诊断再决定**：#710（23 评论）、#121——先在 venera-D 当前代码上确认是否仍复现（部分可能已被你的依赖修复顺带解决），避免修一个已经不存在的问题。
4. **平台 bug 挑你能测的**：Windows（#660/#756）你有环境，其余（HyperOS/ColorOS）缺设备难验证，可暂缓。
5. **大功能（WebDAV 挂载、格式支持、以图搜图）**：明确记录但不主动做，除非你个人有强需求——它们与"维护性 fork"定位不符。

---

## 四、状态复核记录（持续更新）

> 上游 venera-app/venera 已归档（read-only），issue 无人维护关闭，因此 open 清单中混有**已修复但未关闭**的历史 issue。挑选任何候选前，应先用 `git log -S` / `git log --oneline -- <相关文件>` 核查上游是否已修复，避免在已解决的问题上投入。

| Issue | 复核结论 | 证据 |
|-------|---------|------|
| #770 iPad 齿轮抽屉弹出即收回 | ✅ 已修复，venera-D 已继承 | 上游 commit `8370d2a`（2026-03-07，含于 v1.7.0 tag）消息明确“restore reader sidebar stability on iPad by preventing auto-dismiss (#770)”；iPad mini 6 实机（v1.7.3）不复现 |
| #461 本地收藏过滤 | ✅ 上游已实现 | Filter 按钮支持 All/UnCompleted/Completed，venera-D 继承 |
| #710 打开漫画图片全黑报错 | ✅ 源配置层已修复，venera-D 无需改动 | 根因是拷贝漫画源 JS 内部 API 版本过旧（3.0.0 失效，报 `loadEp` TypeError），非 app 代码 bug；上游 venera-configs 的 copy_manga.js 已更新至 3.0.6（`User-Agent: COPY/3.0.6`），venera-D 默认源列表自动拉取，用户不再受影响 |
| #660 Win10 中文路径打不开 | ⚠️ 实为 Flutter 引擎 bug，官方已修（`r: fixed`），venera-D 高版本 Flutter 大概率已免疫 | 根因是非 app 代码：Flutter 3.38+ Windows 在非 ASCII 路径启动引擎静默崩溃（联 Kazumi#1538 同源）；官方 flutter/178896 已标 `r: fixed`（2025-12-10 关闭）；venera-D 钉死 Flutter 3.44.6 远高于受影响版本，建议在 Windows 中文路径实机启动一次确认 |

---

## 附：数据与脚本

- `open_issues.json` — 142 个 open issue 的结构化原始数据（number/title/labels/comments/body/url）
- `fetch_upstream_issues.py` — 采集脚本（只读 GitHub API，可重跑刷新）
- `_triage.py` / `_themes.py` — 统计与主题聚类脚本

重跑采集（数据会随上游而变，但上游已归档，基本静止）：`python design/upstream_issues/fetch_upstream_issues.py`
