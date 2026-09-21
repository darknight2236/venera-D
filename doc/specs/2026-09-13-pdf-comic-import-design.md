# 图片型漫画 PDF 导入 — 设计规格

日期：2026-09-13
状态：已确认（用户批准）
关联：上游 issue venera-app/venera#431（无维护者回应，仓库已归档）

## 1. 背景与目标

venera-D 目前只支持从目录与归档（cbz/cb7/zip/7z）导入本地漫画；PDF 能力只有导出侧
（`lib/utils/pdf.dart`，手写 PDF 写出器）。用户有导入图片型漫画 PDF 的真实需求，
且其 PDF 存在**用户密码加密**（打开需输入密码）的情况。

目标：在**不引入任何新依赖**的前提下，支持图片型漫画 PDF 导入（含加密 PDF），
行为与现有 cbz 导入对齐。

## 2. 需求（已澄清）

| 维度 | 决定 |
|------|------|
| PDF 类型 | 图片型漫画 PDF（每页一张扫描图/插画） |
| 导入粒度 | 与 cbz 对齐：单个 PDF = 一部无章节漫画；批量 = 选目录，每个 PDF 各成一部 |
| 加密支持 | C 档全量：R2/R3/R4（RC4、AES-128）+ R5/R6（AES-256）；密码输入 UI + 错误重试；空用户密码（权限加密）静默通过 |
| 平台 | 全平台一致（纯 Dart，无原生依赖），headless 可复用解析核心 |

## 3. 技术路线决策

三个候选（详见会话记录）：

1. **纯 Dart 自研图片提取器**（✅ 选定）：解析 PDF 子集，DCTDecode（JPEG）字节直通、
   FlateDecode 转 PNG；零二进制成本、无损、契合项目手写格式先例（pdf.dart 写出器）。
2. pdfrx（PDFium）逐页渲染：每平台 +10-20MB 二进制、Windows CI 开发者模式风险、
   JPEG 重编码损质——被否。
3. 混合（1 起步 + PDFium 兜底）：兜底部分推迟到真实需求出现（YAGNI）。

加密支持的依赖核实：`crypto ^3.0.6`（MD5/SHA 系列）与 `pointycastle ^4.0.0`
（AES-CBC/RC4/RSA，JS 引擎 Convert API 已在用）**均已在 pubspec**，零新增依赖。
GPL-3.0 项目排除专有许可方案（Syncfusion）。

## 4. 模块布局

```
lib/utils/pdf/objects.dart    （新增）PDF 对象模型 + 词法/语法解析器
lib/utils/pdf/document.dart   （新增）PdfDocument：xref（传统+流）、对象获取、页树遍历
lib/utils/pdf/security.dart   （新增）标准安全处理器：密钥推导、RC4/AES、U/Perms 校验
lib/utils/pdf/images.dart     （新增）图片解码管线 + extractPdfImages 公共 API 与异常类型
lib/utils/pdf/png_encoder.dart（新增）手写 PNG 编码器（IHDR/IDAT/IEND + CRC32）
lib/utils/pdf_import.dart     （新增）PdfComic.import()：提取图片到缓存目录 → 共用尾段注册
lib/utils/cbz.dart            （修改）抽出共用尾段 comicFromCacheDir()
lib/utils/import_comic.dart   （修改）ImportComic 增加 pdf()/multiplePdf() + passwordProvider 注入
lib/pages/home_page.dart      （修改）导入对话框增加两个 PDF 选项（含既有 type 索引调整）+ 密码对话框
lib/components/message.dart   （修改）showInputDialog 增加 obscureText 参数
lib/foundation/local.dart     （修改）补 LocalManager.forTesting() 测试接缝（六单例中唯一缺失的）
assets/translation.json       （修改）新增 zh_CN / zh_TW 键
doc/import_comic.md           （修改）补 PDF 章节
test/helpers/pdf_builder.dart （新增）测试内构建合法 PDF 的迷你写出器
test/fixtures/pdf/            （新增）离线生成的加密 fixture PDF（含生成脚本）
test/pdf_*_test.dart          （新增）各层单测 + 端到端导入集成测试
```

解析核心为纯 Dart（dart:io/typed_data/crypto/pointycastle），不 import Flutter，
headless 与单测可用；命名避开现有 `utils/pdf.dart`（导出侧写出器），读写分离。
（规划期修订：单文件 pdf_extract.dart 精化为 utils/pdf/ 子目录，对齐
foundation/comic_source/ 的子目录先例，便于按任务增量构建与测试。）

## 5. 解析器范围（lib/utils/pdf/）

### 5.1 结构解析

- 文件尾部扫描 `startxref`（最后 1024 字节）
- xref：传统交叉引用表 + PDF 1.5 交叉引用流（/Type /XRef，/W 数组解码、/Index 分段、
  增量更新的多段 xref 合并，取每对象最新条目）
- 对象解析：间接对象 `N G obj … endobj`；对象流（/Type /ObjStm，/N /First）
- 文档树：trailer/Catalog → /Pages 递归（/Kids；**注意 /Resources 可从父节点继承**）
  → /Type /Page 叶节点按树序排列
- 每页图片：/Resources → /XObject 中 /Subtype /Image 条目

### 5.2 图片提取

| 编码/属性 | 处理 |
|-----------|------|
| /Filter DCTDecode（含多重过滤末位为 DCTDecode） | 原始字节直通 → `.jpg`（无损零转码） |
| /Filter FlateDecode | dart:io zlib 解压 → Predictor 逆变换（/Predictor ≥10 PNG 预测器，
  按 /Columns /Colors /BitsPerComponent 逐行反滤波；/Predictor 2 TIFF 预测器同样支持，
  其余未知值拒绝并报错）→ 像素 → 手写 PNG 编码器 → `.png` |
| ColorSpace | DeviceRGB / DeviceGray / DeviceCMYK（含 Adobe 反色：/Decode [1 0 …]；
  CMYK→RGB 基础换算 R=255×(1−C)×(1−K)）；另兼容两种常见间接形式：
  [/ICCBased …] 按其 /N 分量数映射到 Gray/RGB/CMYK；[/Indexed base hival lookup]
  调色板展开为基色空间采样；其余（Separation/Lab 等）拒绝 |
| BitsPerComponent | 8 原生；16 降采样为 8（四舍五入） |
| /SMask | 忽略（漫画不需要透明通道） |
| /ImageMask 模板蒙版 | 忽略 |
| JPXDecode / CCITTFaxDecode / JBIG2Decode | **拒绝**：错误信息列出页码与编码名，
  建议外部转 cbz |

一页多图（罕见）：按资源名字典序排列，不解析 content stream 的 Do 调用顺序（决策点 1，已确认）。

### 5.3 手写 PNG 编码器（~100 行）

IHDR（8-bit，color type 2 RGB / 0 Gray）+ IDAT（filter 0 扫描线，dart:io zlib 压缩）
+ IEND；CRC32 手写查表实现。与 pdf.dart 写出器同风格。

### 5.4 明确不做

矢量/文字页渲染（无 /Image 则报 "No images found"）、content stream 内联图片
（BI/ID/EI）、PDF 内嵌章节结构、metadata.json 机制（不适用 PDF）。

## 6. 加密支持（C 档）

### 6.1 安全处理器

支持 V1/V2（R2/R3，RC4-40/128）、V4（R4，CF 字典：/V2 RC4 或 /AESV2，
按 /StmF /StrF 应用）、V5（R5/R6，/AESV3 AES-256-CBC）。

### 6.2 密钥推导与解密

- Algorithm 2（文件密钥）、Algorithm 3（/O 校验）、Algorithm 4/5（/U 校验，R2/R3/R4）
- R5/R6：Algorithm 2.A/2.B（SHA-256/384/512 哈希轮），/U[32..48] 校验 + /Perms 验证
- 每对象密钥（R2-R4）：Algorithm 1 = MD5(文件密钥 + 对象号 3 字节 LE + 代号 2 字节 LE
  [+ AES 时 "sAlT"])，密钥长度 min(n+5, 16)
- R5/R6：文件密钥直接 32 字节；每个流前 16 字节为 CBC IV
- /EncryptMetadata false：metadata 流不解密
- 字符串内容不解密（提取图片无字符串消费方，YAGNI）；只解密流；漫画标题**不**取
  PDF /Title 元数据，与 cbz 一致统一用文件名，避免 "Untitled" 类垃圾标题
- 密码编码：R2-R4 取密码字节（超 32 截断）；R6 用 UTF-8

### 6.3 解密层位置与密码提供者

`PdfSecurityHandler`（由 `setupSecurity` 建立）位于"原始字节读取"与"对象/流解析"
之间。xref 流与 `/Encrypt` 字典本身**不加密**（规范保证）：xref 在 `open()` 的 xref
循环内直接解析（早于安全处理器建立），`/Encrypt` 可先读出以推导文件密钥；此后再经
`fetch`/`streamData` 消费的普通对象流（ObjStm、图片流）才按需解密。

```dart
typedef PdfPasswordProvider = Future<String?> Function(String fileName);
```

（带 fileName 参数：UI 对话框标题需要显示是哪个文件在要密码。）

- 解析流程：检测 /Encrypt → **自动先试空密码**（权限加密静默通过）→ 失败进入
  **解析器内部的密码循环**：反复调用 passwordProvider（每次调用 = UI 弹一次框），
  拿到密码后校验 /U（或 /Perms）；错误则记日志并再次调用 provider（UI 层据此
  提示 "Incorrect password" 后重弹）；provider 返回 null 视为用户取消，抛
  PdfCancelledException 终止导入
- UI 导入：对话框 provider（标题带文件名）
- headless/测试：null（仅空密码）/ fake provider

### 6.4 UI 流程

- 单文件：加密 → 试空密码 → 弹密码框（showInputDialog + obscureText 扩展）→
  错误提示"Incorrect password"后重弹 → 取消则终止
- 批量：逐个文件同流程（对话框标题带文件名），取消 = 跳过该文件，结束汇总报告

## 7. 导入流程集成

### 7.1 共用尾段重构（cbz.dart）

CBZ.import 的"缓存目录 → LocalComic"段（标题回退文件名、查重名、数字优先排序、
cover.* 或首图作封面、复制到 `LocalManager().path/<sanitize(title)]>/`、
构建 LocalComic）抽为共用函数，CBZ 与 PDF 两侧复用。行为保持不变（回归测试兜底）。

### 7.2 PdfComic.import

```
PdfComic.import(File file, {PdfPasswordProvider? passwordProvider})
  → extractPdfImages 解析（含解密）→ 图片写入 cachePath/pdf_import/
    （JPEG 直通复制；Flate 转 PNG 写入；命名 1.jpg/2.png… 页序）
  → 共用尾段（标题 = 文件名去扩展名，与 cbz 一致）
  → LocalComic → registerComics(imported, false)
```

### 7.3 ImportComic 入口

- `pdf()`：selectFile(ext: ['pdf'])，UI provider
- `multiplePdf()`：DirectoryPicker → 过滤 .pdf → 逐个导入，失败跳过记日志，
  全败提示 "No valid comics found"（与 multipleCbz 行为一致）

### 7.4 UI（home_page.dart 导入对话框）

importMethods 在 "Multiple archive files" 后插入 **"A PDF file" / "Multiple PDF files"**
（新 index 4/5），EhViewer→6、Restore→7。同步更新：info 文案数组、selectAndImport
的 switch、`type != 4 && type != 5` 类条件（收藏夹选择/复制选项/selectedFolder 置空）
中的全部索引。

### 7.5 i18n（translation.json，zh_CN + zh_TW）

新增键：A PDF file、Multiple PDF files、Select a PDF file (image-based comics)、
Select a directory which contains PDF files.、Enter password for @f、
Incorrect password、The PDF is encrypted、
PDF page @p uses an unsupported image encoding (@e)、No images found in the PDF。

## 8. 错误处理

| 场景 | 行为 |
|------|------|
| 不支持的图片编码 | 报错含页码与编码名，建议转 cbz |
| 加密 + 用户取消 | 终止该文件，提示已取消 |
| 无图片（纯文字/矢量 PDF） | "No images found in the PDF" |
| 重名 | 与 cbz 一致："Comic with name X already exists" |
| 结构损坏（xref 不可解析等） | 带对象号/偏移上下文的错误 + Log.error 全堆栈 |
| 批量中单文件失败 | 跳过继续，结束汇总 |

## 9. 测试策略

- **fixture**：Python pypdf/qpdf 离线生成小 PDF 提交至 test/fixtures/pdf/：
  plain_jpeg / flate_rgb / flate_gray / flate_cmyk / encrypted_rc4_128 /
  encrypted_aes128 / encrypted_aes256_r6 / owner_only_empty_user_pw /
  wrong_password_case / no_images / jpx_reject / xref_stream_15 / objstm
- **读写互证**：项目自有 utils/pdf.dart 写出器以 `/FlateDecode` + DeviceRGB 8bit 嵌入
  原始像素（已核实），测试内用它生成 PDF → 提取器走 Flate 路径转 PNG → 解码后
  像素与原图逐一相等；DCTDecode（JPEG 直通）路径由外部 fixture 覆盖
- **密码学**：密钥推导用 PDF 32000 规范附录算例；AES/RC4 原语抽查 NIST 向量
  （pointycastle 本体已充分测试）
- **单测**：传统/压缩 xref、ObjStm、Predictor 逆变换、16→8bit 降采样、
  CMYK 换算（含 Adobe 反色）、PNG 编码器（结构 + ui.instantiateImageCodec 可解码）、
  fake passwordProvider（正确/错误后重试成功/取消）
- **集成**：PdfComic.import 端到端（temp App.dataPath + LocalManager.forTesting，
  遵循 ensureSqlite3ForTests skip 惯例），验证落盘目录结构与 LocalComic 字段
- **回归**：CBZ.import 共用尾段重构后现有 cbz 行为不变
- 架构约束：`lib/utils/pdf/` 解析核心不 import Flutter（architecture_test 现有规则不覆盖
  utils，但保持 headless 可用性是自检项）

## 10. 规模估计

解析器 ~600 行 + PNG 编码器 ~100 行 + 加密层 ~300 行 + 导入集成/UI/i18n ~230 行
+ 测试与 fixtures ~450 行 ≈ **1700-1800 行**。

## 11. 决策记录

| 决策点 | 选择 | 理由 |
|--------|------|------|
| 技术路线 | 纯 Dart 提取（方案一） | 零依赖零构建风险、JPEG 无损直通、headless 可用 |
| 加密范围 | C 档全量（R2-R6 + 密码 UI） | 用户真实需求即用户密码加密；crypto/pointycastle 已在依赖中，边际成本低 |
| 一页多图排序 | 资源名字典序 | 漫画 PDF 几乎一页一图，解析 content stream 不值 |
| CMYK | 基础换算支持 | 印刷来源偶见，~30 行 |
| R5 | 支持 | 与 R6 共用 V5 流程，增量 ~30 行 |
| 内联图片 BI/ID/EI | 不支持 | 漫画 PDF 用 XObject，罕见路径不做 |
| headless CLI | 本期不加导入命令 | 现有 headless 无导入命令族，避免范围膨胀；核心已 headless-ready |
