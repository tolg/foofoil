# 历史记录搜索功能实施计划

## 1. 文档目的

本文档定义 Flamina 历史记录搜索功能的完整实施方案，作为后续编码、测试和验收的依据。

本方案已经确认以下核心决策：

- 取消历史记录 30 条上限，历史数量不设硬性条数限制。
- 历史记录与全文索引全部使用系统原生 SQLite，不使用 SwiftData 和第三方数据库依赖。
- 新版 SQLite 历史库从空库开始，不读取、不解析、不导入原有 `UserDefaults.historyConfigs` 历史记录。
- 历史元数据、内容分块和全文索引放在同一个 SQLite 数据库中，保证删除与更新可以在同一事务内完成。
- 文本、Markdown、网页正文和文字型 PDF 支持正文搜索。
- 普通图片在打开并显示后进入后台 OCR，不允许 OCR 阻塞图片展示。
- 扫描型 PDF 仅 OCR 封面；不 OCR 内页。
- 文字型 PDF 按页增量提取和索引，支持书籍规模，不把整本 PDF 一次性加载成巨型字符串。
- 搜索界面是独立于内容窗口的 Spotlight 风格面板。
- 搜索结果最多显示 10 条。

## 2. 产品范围

### 2.1 搜索字段

每条历史记录可参与搜索的字段如下：

| 内容类型 | 标题 | URL | 正文来源 | 备注 |
| --- | --- | --- | --- | --- |
| 普通文本笔记 | 是 | 否 | `AppState.text` | 编辑后增量更新索引 |
| 文本文件 | 是 | 否 | 缓存文本文件内容 | 支持现有编码探测逻辑 |
| Markdown | 是 | 否 | Markdown 原文 | 第一版不额外生成“去语法”版本 |
| CSV/代码等文本文件 | 是 | 否 | 文件文本内容 | 沿用现有文本文件识别范围 |
| 图片 | 是 | 否 | Vision OCR 文本 | 图片显示后后台处理 |
| 网页 | 是 | 是 | DOM 可见正文快照 | 使用主文档 `innerText`，不索引网页截图 OCR |
| 文字型 PDF | 是 | 否 | PDFKit 逐页文字 | 搜索结果保留命中页码 |
| 扫描型 PDF | 是 | 否 | 封面 OCR | 不处理内页 |

标题、URL 和正文采用不同权重。标题精确匹配和标题前缀匹配优先级最高，正文命中其次，最近使用时间只作为同等相关度下的排序条件。

### 2.2 不在本期范围内

- 云端 OCR、云端同步和跨设备搜索。
- 扫描型 PDF 内页 OCR。
- 网页 iframe、Canvas、视频字幕及图片内文字识别。
- 模糊拼写纠错、同义词、语义搜索和向量搜索。
- 在 PDF 窗口中自动跳转到命中页。数据库会保留页码，为后续功能预留能力，但本期打开历史项时仍按现有恢复行为处理。
- 超过 10 条结果的“查看更多”界面。查询内部可以获取更多候选用于去重和排序，但 UI 最终只展示 10 条。

## 3. 交互规格

### 3.1 搜索入口

搜索功能有三个等价入口，最终都调用同一个 `HistorySearchWindowController.show()`：

1. 历史记录菜单顶部增加“搜索历史记录…”菜单项。
2. 空白窗口底部历史记录横向列表的最后增加搜索卡片。
3. 全局应用菜单快捷键 `⌘F`。

历史记录菜单结构调整为：

```text
搜索历史记录…        ⌘F
──────────────
最近历史记录 1
最近历史记录 2
…最多 10 条
──────────────
清空历史记录…
```

即使当前没有历史记录，搜索入口仍然可用；菜单中在分隔线后显示“无历史记录”。

空白窗口的历史列表继续只加载最近 30 条，避免无限历史全部进入内存。搜索卡片始终放在最近历史卡片之后；无历史时也显示搜索卡片。卡片使用 `magnifyingglass` SF Symbol，并可在按住 Command 时显示 `⌘F` 提示。

### 3.2 搜索面板

搜索窗口采用独立 `NSPanel`，由单例式 `HistorySearchWindowController` 持有：

- 不作为任何 Flamina 内容窗口的 sheet 或 child window。
- 无边框、带阴影、圆角、悬浮层级，视觉接近 macOS Spotlight。
- 屏幕居中偏上显示；位置根据当前鼠标所在屏幕或当前 key window 所在屏幕确定。
- 可加入所有 Space，并支持全屏辅助显示。
- 面板成为 key window 后，搜索框立即成为 first responder。
- 重复按 `⌘F` 不创建第二个面板；将现有面板置前并重新聚焦搜索框。

本计划默认以下关闭行为：

- `Esc` 关闭搜索面板。
- `⌘W` 关闭搜索面板。
- 打开任意搜索结果后关闭搜索面板。
- 应用失去激活状态时关闭搜索面板。
- 每次重新打开搜索面板都清空上次关键词、结果和选择状态。

面板初始仅显示搜索输入框，不预展示最近历史，也不显示空结果提示。只有出现非空关键词后才开始搜索。

### 3.3 输入与结果更新

- 输入内容去除首尾空白后为空：取消未完成查询，清空结果，不显示列表。
- 非空输入采用约 120–180ms 防抖，避免每个按键都立即访问数据库。
- 每次新查询带递增 generation；旧查询晚返回时必须丢弃，避免结果倒序覆盖。
- 查询在数据库专用后台队列执行，主线程只接收最多 10 条轻量结果模型。
- 新结果非空时，默认高亮第一项。
- 关键词变化并产生新结果时，将选择重置到第一项。
- 没有匹配结果时显示本地化的“未找到结果”，但不显示历史推荐。

### 3.4 结果列表项

每个结果项包含：

- 左侧缩略图。
- 内容类型 SF Symbol。
- 标题。
- 可选的单行命中摘要；若加入摘要，不得挤掉用户明确要求的缩略图、类型和标题。

建议布局：

```text
┌──────────────────────────────────────┐
│ [缩略图]  [类型图标] 标题             │
│           命中摘要（可选）             │
└──────────────────────────────────────┘
```

类型图标沿用或明确扩展现有映射：

| 类型 | SF Symbol |
| --- | --- |
| 网页 | `globe` |
| 图片 | `photo` |
| PDF | `text.document` |
| Markdown | `arrow.down.document` |
| CSV | `tablecells` |
| 普通文本/笔记 | `note.text` |

缩略图加载必须异步进行，并设置内存缓存，禁止在列表 `body` 或主线程同步解码原始大图。建议预生成固定像素尺寸的搜索缩略图：

- 图片：由图片缓存降采样生成。
- 网页：复用已有网页截图并降采样。
- PDF：渲染封面低分辨率缩略图。
- 文本/Markdown：使用统一底色和类型占位图，不为每条文本生成位图。

### 3.5 键盘和鼠标操作

结果列表支持：

| 输入 | 行为 |
| --- | --- |
| `↓` | 高亮下一项 |
| `↑` | 高亮上一项 |
| `⌃N` | 高亮下一项 |
| `⌃P` | 高亮上一项 |
| `Return` / `Enter` | 在新窗口打开高亮项 |
| 单击结果 | 在新窗口打开该项 |
| `Esc` | 关闭搜索面板 |

选择到达边界时保持在第一项或最后一项，不循环跳转。

键盘事件建议由自定义 `NSPanel.sendEvent(_:)` 或面板控制器统一截获，再转发给 SwiftUI 搜索状态，确保 `⌃P`、`⌃N` 不先被文本输入系统作为光标命令消费。输入法组合态期间不得把 Return 当作打开结果；应先让输入法完成候选确认。

### 3.6 打开结果

搜索结果与当前历史菜单行为不同：

- 无论当前是否存在空白窗口，搜索结果始终在一个新的 Flamina 窗口中打开。
- 回车和点击共用同一个 `openSearchResultInNewWindow(_:)` 方法。
- 新窗口使用历史记录保存的尺寸和位置；若原记录没有位置，则按现有窗口偏移/居中规则处理。
- 打开成功后更新该历史项 `last_opened_at`，并关闭搜索面板。
- 如果缓存文件已经丢失，保留历史记录但展示明确错误，不允许静默创建空窗口。

### 3.7 右键删除

搜索结果的右键菜单仅包含“删除”：

```text
删除
```

不显示“修改标题”、复制、打开方式等其他项目。

删除行为沿用当前历史卡片的即时删除习惯，不额外弹确认框。删除事务必须同时完成：

- 删除历史元数据。
- 删除正文分块和 FTS 索引。
- 取消对应的 OCR/PDF/网页索引任务。
- 在没有其他记录和活跃窗口引用时删除应用缓存文件和缩略图。

删除后重新执行当前查询：

- 优先高亮原位置的下一项。
- 如果删除的是最后一项，则高亮新的最后一项。
- 如果没有结果，清空选择并显示“未找到结果”。

## 4. 总体架构

建议增加以下边界清晰的组件：

```text
AppState / AppDelegate / SwiftUI Views
                 │
                 ▼
          HistoryRepository
                 │
                 ▼
          HistoryDatabaseActor
                 │
                 ▼
        SQLite（单连接串行写入）
          ├─ history_items
          ├─ search_chunks
          ├─ search_fts
          └─ schema_meta / PRAGMA user_version

ContentIndexCoordinator
  ├─ ImageOCRIndexer
  ├─ WebContentIndexer
  ├─ PDFTextIndexer
  └─ TextContentIndexer

HistorySearchWindowController
  └─ HistorySearchViewModel
       └─ HistoryRepository.search(...)
```

### 4.1 线程模型

- SQLite 由一个 actor 或严格串行队列拥有，不跨线程共享 statement 和连接。
- UI 不直接调用 sqlite3 C API，只依赖 `HistoryRepository`。
- 搜索读取和索引写入都通过数据库 actor 调度。
- 使用 WAL 允许读写更平滑，但仍保持应用层单写者。
- Vision、PDFKit 提取、图片缩放和网页文本处理在数据库 actor 外执行；仅最终批量写入时进入 actor。
- 不把耗时 OCR 或 PDF 页面循环放在主线程或数据库 actor 内。

## 5. SQLite 方案

### 5.1 数据库位置和连接配置

建议数据库路径：

```text
~/Library/Application Support/Flamina/history.sqlite3
```

连接初始化至少执行：

```sql
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
PRAGMA foreign_keys = ON;
PRAGMA busy_timeout = 3000;
```

要求：

- 所有 SQL 使用预编译 statement 和绑定参数。
- 所有多表修改使用显式事务。
- 数据库错误统一转换成项目内 `HistoryDatabaseError`。
- Debug 构建提供可控 SQL 日志，但日志中不得输出完整网页正文、OCR 文本或用户笔记。
- 数据库 schema 使用 `PRAGMA user_version` 管理，禁止依赖“运行时发现缺列后临时补列”。

### 5.2 历史主表

建议初始 schema：

```sql
CREATE TABLE history_items (
    id TEXT PRIMARY KEY NOT NULL,
    content_kind INTEGER NOT NULL,
    display_title TEXT NOT NULL DEFAULT '',
    original_filename TEXT,

    image_path TEXT,
    text_path TEXT,
    web_url TEXT,
    actual_web_url TEXT,
    image_source INTEGER,
    inline_text TEXT NOT NULL DEFAULT '',

    is_pinned INTEGER NOT NULL DEFAULT 0,
    opacity REAL NOT NULL DEFAULT 1.0,
    window_frame TEXT,
    show_border INTEGER NOT NULL DEFAULT 1,
    image_scale REAL NOT NULL DEFAULT 1.0,
    text_font_size REAL NOT NULL DEFAULT 16.0,
    is_markdown_preview INTEGER NOT NULL DEFAULT 0,
    svg_color TEXT,
    background_color_hex TEXT,

    created_at REAL NOT NULL,
    updated_at REAL NOT NULL,
    last_opened_at REAL NOT NULL,

    source_fingerprint TEXT,
    index_status INTEGER NOT NULL DEFAULT 0,
    index_version INTEGER NOT NULL DEFAULT 0,
    index_error TEXT,
    thumbnail_path TEXT
);

CREATE INDEX idx_history_last_opened
ON history_items(last_opened_at DESC);

CREATE INDEX idx_history_created
ON history_items(created_at DESC);

CREATE INDEX idx_history_kind
ON history_items(content_kind);

CREATE INDEX idx_history_actual_web_url
ON history_items(actual_web_url)
WHERE actual_web_url IS NOT NULL;

CREATE INDEX idx_history_web_url
ON history_items(web_url)
WHERE web_url IS NOT NULL;

CREATE INDEX idx_history_fingerprint
ON history_items(source_fingerprint)
WHERE source_fingerprint IS NOT NULL;
```

`content_kind` 必须成为真实字段，不能继续依赖 `originalImageName` 后缀推导。`display_title` 和 `original_filename` 分离，解决用户修改标题后 PDF/Markdown 类型失效的问题。

`inline_text` 主要保存可编辑笔记的权威正文。大型导入文本可以继续以缓存文件为权威来源，避免主表出现超大行；具体由 `content_kind` 和 `text_path` 决定。

### 5.3 搜索分块表

```sql
CREATE TABLE search_chunks (
    id INTEGER PRIMARY KEY,
    history_id TEXT NOT NULL,
    chunk_kind INTEGER NOT NULL,
    ordinal INTEGER NOT NULL,
    page_number INTEGER,
    original_text TEXT NOT NULL,
    normalized_text TEXT NOT NULL,
    FOREIGN KEY(history_id) REFERENCES history_items(id) ON DELETE CASCADE,
    UNIQUE(history_id, chunk_kind, ordinal)
);

CREATE INDEX idx_search_chunks_history
ON search_chunks(history_id);
```

分块原则：

- 笔记、OCR 图片：通常一个 chunk。
- 网页正文：按自然段合并到约 16–32KB 一个 chunk。
- 大型文本/Markdown：按自然段或行边界切到约 16–32KB。
- PDF：原则上每页一个 chunk；极短连续页可合并，但必须保留可定位的起始页码。
- 禁止一个 chunk 保存整本书。

### 5.4 中文与任意子串索引

默认 FTS tokenizer 不适合两个汉字的任意子串检索。方案采用应用层标准化和二元组 token：

```text
历史记录搜索
→ 历史 / 史记 / 记录 / 录搜 / 搜索
```

为避免标点、空格和特殊字符破坏 FTS 查询，每个二元组编码为安全 ASCII token，并区分 title/body 前缀。

建议 FTS 表为 contentless 索引，rowid 与 `search_chunks.id` 对齐：

```sql
CREATE VIRTUAL TABLE search_fts USING fts5(
    title_terms,
    body_terms,
    content = '',
    detail = column,
    tokenize = 'unicode61'
);
```

contentless FTS 不会随 `search_chunks` 的外键级联自动删除。每次替换或删除 chunk 时，必须在删除 `search_chunks` 行之前，根据原始标题和 `original_text` 重新生成相同 token，并在同一事务中先执行 FTS5 的 `delete` 特殊命令，再删除 chunk。禁止只删除主表后遗留不可达的 FTS posting。

如果阶段 0 原型确认所有支持系统的 SQLite 版本均提供 `contentless_delete=1`，可以采用该模式简化更新与删除；否则使用兼容性更高的显式 `delete` 命令。无论采用哪种模式，都必须提供 FTS 完整性检查和全量重建测试。

索引规则：

- 标题生成 unigram 和 bigram，保证只输入一个字符时也能快速找到标题。
- 正文只生成 bigram，控制书籍正文索引体积。
- 一个字符的查询只搜索标题，不扫描所有正文。
- 两个及以上字符搜索标题和正文。
- 查询先通过 n-gram 找候选，再用 `normalized_text` 验证完整连续子串，排除 n-gram 假阳性。
- 多个空格分隔关键词默认采用 AND 语义，每个关键词都必须在同一历史项的标题或任意正文块中命中。
- 多关键词不能简单要求全部关键词命中同一个 chunk。应分别查询每个关键词的候选 `history_id`，在历史项维度求交集，再选择相关度最高的命中 chunk 生成摘要。
- 用户输入永远不直接拼接进 `MATCH` SQL；只允许标准化、编码后的安全 token 通过绑定参数进入查询。

在最终编码前必须做一个独立原型，验证目标 macOS 系统 SQLite 的 `ENABLE_FTS5` 编译选项和 contentless FTS 行为；若缺失则启动时明确失败并记录诊断，不能静默退化为无限历史全表扫描。

### 5.5 搜索查询和排名

查询分两阶段：

1. FTS 获取最多约 100–200 个候选 chunk。
2. 关联 `history_items`，按 `history_id` 聚合，每条历史只保留最佳 chunk，应用层验证原文并重新排序，最终返回 10 条。

建议排序权重：

1. 标题完全等于关键词。
2. 标题以前缀开始。
3. 标题包含完整关键词。
4. URL 包含完整关键词。
5. 正文包含完整关键词。
6. FTS 相关度。
7. `last_opened_at` 较新。

搜索结果 DTO 不返回完整正文，只返回：

```swift
struct HistorySearchResult: Identifiable, Sendable {
    let id: UUID
    let title: String
    let contentKind: HistoryContentKind
    let thumbnailPath: String?
    let matchedSnippet: String?
    let matchedPageNumber: Int?
    let score: Double
}
```

### 5.6 去重

现有网页 URL 去重和普通内容去重逻辑必须转为 SQL 查询与事务，不再对全量数组执行 `removeAll`。

- 网页优先以 `actual_web_url` 去重，并保留初始 URL。
- 本地文件和图片优先使用后台生成的内容指纹；指纹尚未完成时使用规范化缓存路径、文件大小和修改时间作为临时键。
- 可编辑笔记不按完整正文全局去重，以稳定 UUID 为准。
- 去重合并历史项时，同一事务迁移或重建搜索索引，并安全处理缓存文件引用。

## 6. 新存储启用计划

### 6.1 旧历史处理原则

首次启用 SQLite 历史库时直接创建空数据库。必须遵守：

- 不读取 `SettingsStore.historyConfigs`。
- 不解析原有历史 JSON。
- 不将任何旧 `WindowConfig` 历史项写入 SQLite。
- 不为旧历史补建 OCR、网页、文本或 PDF 索引。
- SQLite 数据库创建成功后删除 `historyConfigs` UserDefaults 键，防止旧代码路径再次把它当作历史数据源。
- 可以清理由旧历史遗留、且未被当前活跃窗口引用的 `cached_image_*`、`cached_text_*`、`cached_web_*` 文件，避免被忽略的历史长期占用磁盘。
- 不清除透明度、置顶、窗口外观等与历史无关的用户设置。

该切换不需要历史数量校验、失败回滚或旧数据兼容映射。SQLite 初始化失败时应报告数据库错误，但也不得回退读取旧 `UserDefaults` 历史。

### 6.2 运行时 DTO 适配

`WindowConfig` 可以继续作为窗口运行时 DTO，这不代表迁移旧历史：

- `HistoryRepository` 将数据库行转换为 `WindowConfig` 供 `AppState.loadConfig` 使用。
- `AppState.toConfig()` 继续生成 DTO，但 `saveState()` 最终调用数据库 upsert。
- 所有生产路径切换到 SQLite 后，删除 `SettingsStore.historyConfigs` 和旧 `HistoryManager` 数组存储。

不建议一次提交中同时重写窗口渲染和数据库层，应先通过 DTO 适配器保持现有 `AppState` 行为。

## 7. 内容索引流程

### 7.1 任务状态

`index_status` 建议枚举：

```text
0 pending
1 running
2 completed
3 failed
4 unsupported
```

每次索引算法或标准化规则变化时递增全局 `index_version`。启动后只重建版本过期的项目，不阻塞应用启动。

所有任务都携带：

- `historyID`
- `sourceFingerprint`
- `indexVersion`
- 任务 generation

写回前重新核对，避免旧任务覆盖已经变化的内容。

### 7.2 图片 OCR

图片打开时严格遵循：

```text
缓存或确认图片路径
→ 主线程更新 AppState，窗口立即显示图片
→ 历史元数据入库并标记 pending
→ 下一轮事件循环/后台任务调度 OCR
→ OCR 完成后事务写 search_chunks + search_fts
```

实施要求：

- OCR 任务队列最大并发数为 1。
- 使用 utility/background QoS。
- 使用 ImageIO 后台降采样，不在主线程完整解码超大图片。
- 默认使用 Vision 准确模式；中文和英文语言配置需根据系统支持能力设置。
- 内容指纹和完整哈希也在后台计算，不能成为打开图片的前置条件。
- OCR 为空仍标记 completed，避免每次启动反复 OCR。
- 删除历史、替换图片或应用退出时支持取消。
- 图片打开首帧耗时不得因新增 OCR 出现可测量的同步回退。

### 7.3 网页正文

网页 `WKWebView` 导航完成并稳定后：

- 保留现有标题和截图流程。
- 通过 JavaScript 读取主 frame 的 `document.body.innerText`。
- 正文提取与截图互不依赖，任一失败不阻塞另一项。
- 去除不可见控制字符，合并异常连续空白，按块写入索引。
- 设置单页正文合理上限；达到上限时记录 truncation 状态，避免异常页面产生无限文本。
- SPA 页面在本期保存一次正文快照，不持续监听 DOM。
- 不对网页自动截图执行图片 OCR，避免重复文本和额外 CPU。
- 删除历史时正文快照、截图和 WebKit 相关清理遵守现有清理语义。

### 7.4 文本与 Markdown

- 新建笔记首次出现非空文本时创建历史项和搜索 chunk。
- 编辑采用现有约 800ms 保存防抖，同时使用内容版本避免重复重建相同索引。
- 对小文本直接替换单个 chunk。
- 对大型导入文本按 16–32KB 边界分块，在一个事务中替换该历史项所有旧 chunk。
- Markdown 第一版索引原文，标题、正文和代码块都可命中。
- 文件读取失败时保留历史元数据并标记 failed，不删除旧索引，除非确认内容已经被用户替换。

### 7.5 PDF 分类和索引

PDF 显示不等待分类与索引。索引器在后台创建独立 `PDFDocument`，不得与 UI 中的 `PDFView.document` 跨线程共享实例。

类型判断采用采样，而不是只检查封面：

- 封面后第一页。
- 前部样本页。
- 中部样本页。
- 后部样本页。
- 页数很少时对现有页去重采样。

当多个样本页能提取到足量有效文字时，归类为文字型 PDF；否则视为扫描型 PDF。

文字型 PDF：

- 使用 `PDFPage.string` 逐页提取，禁止使用整本 `PDFDocument.string`。
- 每页或小组页面形成 chunk，保存 `page_number`。
- 每 10–25 页批量提交一次，避免超大事务。
- 数据库可在索引未完成时搜索已经提交的页面。
- 支持暂停、取消和失败后从最后完成页继续。
- 对空文字页直接跳过，不对其执行 OCR。

扫描型 PDF：

- 仅渲染第一页/封面为合理分辨率位图。
- 只执行一次封面 Vision OCR。
- OCR 结果作为一个 `pdf_cover_ocr` chunk。
- 不遍历、不渲染、不 OCR 其余页面。

混合型 PDF 按文字型处理，仅索引自带文字层的页面，不 OCR 空白或扫描内页。

## 8. 历史生命周期与磁盘管理

取消条数限制不代表磁盘无限。历史数据库、全文索引和原始缓存必须分别统计大小。

本期至少需要：

- 删除单条历史时安全删除其数据库行、索引、缩略图和未引用缓存。
- 清空历史时在保护活跃窗口缓存的前提下清理全部数据库内容和孤立文件。
- 启动时低优先级扫描孤立索引任务和明显孤立缩略图。
- 保留数据库重建全文索引的能力。
- 日志中记录索引失败原因，但不记录用户正文。

建议后续设置页展示：

- 原始内容缓存大小。
- 搜索数据库大小。
- 缩略图大小。
- “重建搜索索引”。
- “清理未引用缓存”。

不要在没有用户明确设置的情况下自动按条数或磁盘大小删除历史。

## 9. 代码改造清单

### 9.1 建议新增文件

```text
flamina/History/
  HistoryContentKind.swift
  HistoryRecord.swift
  HistoryRepository.swift
  HistoryDatabase.swift
  HistoryDatabaseActor.swift
  HistoryDatabaseError.swift
  HistoryMigration.swift
  HistorySearchQuery.swift
  HistorySearchResult.swift

flamina/History/Indexing/
  ContentIndexCoordinator.swift
  SearchTextNormalizer.swift
  SearchNGramEncoder.swift
  ImageOCRIndexer.swift
  WebContentIndexer.swift
  PDFTextIndexer.swift
  TextContentIndexer.swift

flamina/History/SearchUI/
  HistorySearchPanel.swift
  HistorySearchWindowController.swift
  HistorySearchViewModel.swift
  HistorySearchView.swift
  HistorySearchResultRow.swift
  HistorySearchThumbnailLoader.swift
```

具体目录可以根据 Xcode group 习惯调整，但数据库、索引器和 UI 不应继续堆入现有 `HistoryManager.swift`。

### 9.2 需要修改的现有文件

- `SettingsStore.swift`
  - `WindowConfig` 暂时保留为 DTO。
  - 移除 `historyConfigs` 的 UserDefaults 权威存储。
  - 不增加旧历史迁移读取入口；新版本不得导入旧历史。

- `HistoryManager.swift`
  - 先改造成 `HistoryRepository` 的兼容 facade。
  - 移除全量 `[WindowConfig]` 持久化和 30 条截断。
  - 所有删除和清空逻辑转交数据库事务与缓存引用服务。

- `AppState.swift`
  - `saveState()` 改为数据库 upsert。
  - 图片显示完成后调度 OCR。
  - 文本变化只提交必要的索引更新。
  - 显式使用 `contentKind`，不通过可编辑标题判断 PDF/Markdown。

- `WebView.swift`
  - 导航稳定后提取 DOM 正文并提交网页索引任务。

- `TextEditorModeView.swift`
  - 最近历史改为分页/限量查询结果。
  - 在历史卡片末尾加入搜索卡片。

- `FlaminaApp.swift`
  - 历史菜单顶部加入搜索项及 `⌘F`。
  - 保存并展示唯一搜索面板控制器。
  - 抽取“始终新窗口打开搜索结果”的公共方法。

- `Localizable.xcstrings`
  - 添加搜索入口、占位词、无结果、索引状态、数据库错误等中英文字符串。

- `flamina.xcodeproj/project.pbxproj`
  - 链接系统 `libsqlite3.tbd`，并确保新增源文件加入正确 target。

## 10. 测试计划

### 10.1 数据库单元测试

- 空数据库创建和 `user_version`。
- 重复启动不重复建表。
- 存在旧 `UserDefaults.historyConfigs` 时仍以空 SQLite 历史启动，不导入旧数据。
- SQLite 初始化成功后旧 `historyConfigs` 键被移除，且与历史无关的设置保持不变。
- 旧托管缓存清理时正确保护活跃窗口仍引用的文件。
- 历史 upsert 不产生重复 UUID。
- 网页 URL 去重保持现有语义。
- 删除历史级联删除 chunk 和 FTS 行。
- 删除仍被活跃窗口引用的缓存时正确保留文件。
- 清空历史保护活跃窗口内容。
- 数据库损坏和不可写错误可诊断。

每个测试使用独立临时数据库，禁止污染用户真实 Application Support。

### 10.2 搜索正确性测试

- 标题精确、前缀、包含匹配排序。
- 中文两个字关键词正文检索。
- 中英文混合、大小写和附加符号标准化。
- 单字符只匹配标题，不扫描正文。
- 多关键词 AND 语义。
- 同一历史多个 chunk 命中只返回一条结果。
- PDF 页码保留正确。
- OCR 结果可搜索。
- URL 可搜索。
- 结果永远不超过 10 条。
- 已删除历史不会通过陈旧索引返回。

### 10.3 索引器测试

- 图片打开路径先完成显示状态，再调度 OCR。
- 相同指纹不重复 OCR。
- OCR 为空仍完成任务。
- 删除/替换时取消旧任务。
- 网页正文截断和空正文处理。
- 千页文字 PDF 按页分批提交，不生成整本字符串。
- 扫描 PDF 仅访问和 OCR 封面。
- 混合 PDF 只索引文字层页面。
- PDF 中途失败可以恢复或安全重建。

### 10.4 UI 与键盘测试

- 历史菜单顶部存在搜索入口和 `⌘F`。
- 空白窗口历史列表末尾存在搜索卡片。
- `⌘F` 只打开一个面板并聚焦输入框。
- 初始没有结果。
- 输入后展示结果并默认选中第一项。
- 上下键、`⌃P`、`⌃N` 边界行为正确。
- 输入法组合态 Return 不误打开历史。
- Return 和点击都创建新窗口。
- 右键菜单只有“删除”。
- 删除后选择位置正确。
- Esc、⌘W、失活关闭行为正确。
- 深色/浅色模式、高对比度和 VoiceOver 标签可用。

### 10.5 性能和压力测试

至少准备以下数据集：

- 10,000 条仅标题历史。
- 10,000 条混合文本、图片 OCR、网页历史。
- 100,000 个正文 chunk。
- 一本 1,000 页文字 PDF。
- 一本 1,000 页扫描 PDF，验证只处理封面。
- 多张超高分辨率图片连续打开。

建议验收目标：

- 应用启动不加载全部历史，数据库初始化不明显阻塞首个窗口。
- 搜索输入防抖结束后，常见查询在目标测试机器上 100ms 左右返回首批结果；压力数据 p95 不超过 250ms。
- 搜索过程中主线程保持流畅，连续输入不出现陈旧结果闪回。
- 图片首帧展示时间相较未启用 OCR 的基线无显著回退。
- 书籍 PDF 索引内存随单页/单批次有界，不随总页数线性累积。
- 扫描 PDF CPU 成本与总页数基本无关，只承担采样判断和封面 OCR。

性能目标需要在开发机和最低目标机型上使用 `os_signpost`、Instruments 和真实文件验证，不能只依赖单元测试。

## 11. 分阶段实施与验收

### 阶段 0：原型验证

目标：消除 SQLite FTS 和中文索引的技术风险。

- 建立临时 SQLite 原型。
- 验证系统 SQLite FTS5。
- 验证二元组编码、contentless FTS、删除和重建。
- 使用中文、英文、OCR 噪声和大段 PDF 文本测量索引体积与查询延迟。

验收：两个汉字关键词在 100,000 chunk 数据集中无需正文全表扫描即可返回正确候选。

### 阶段 1：SQLite 历史仓库

- 创建数据库层和 schema migration。
- 以空数据库启用新历史仓库，明确忽略并移除旧 `UserDefaults.historyConfigs`。
- 用 Repository 适配现有 `WindowConfig`。
- 替换增删改查、去重、清空和最近历史查询。
- 移除 30 条持久化限制，但 UI 最近列表仍限量查询。

验收：现有历史、窗口恢复和缓存清理测试全部通过；10,000 条历史下启动不全量解码。

### 阶段 2：全文索引核心

- 实现标准化、分块、n-gram 和 FTS 查询。
- 接入标题、URL、文本和 Markdown。
- 实现最多 10 条结果、排名和摘要。
- 实现索引版本、重建和孤立清理。

验收：文本类搜索正确性和压力指标通过。

### 阶段 3：搜索 UI

- 实现独立 Spotlight 风格 `NSPanel`。
- 接入菜单顶部入口、空白窗口末尾卡片和 `⌘F`。
- 实现结果行、缩略图、类型图标和默认选择。
- 实现键盘导航、回车/点击新窗口打开和仅删除右键菜单。

验收：全部 UI 交互规格和键盘测试通过。

### 阶段 4：图片与网页索引

- 实现单并发后台图片 OCR。
- 接入异步缩略图。
- 实现网页 DOM 正文快照。
- 完成取消、指纹校验和失败状态。

验收：图片打开速度无明显回退，网页与图片 OCR 可搜索，删除无孤立索引。

### 阶段 5：PDF 索引

- 实现采样分类。
- 文字 PDF 逐页增量索引。
- 扫描 PDF 仅封面 OCR。
- 支持页码、批量提交、取消和恢复。

验收：千页文字书可后台完成索引；千页扫描 PDF 不处理内页。

### 阶段 6：收尾和发布准备

- 全量本地化。
- 数据库 schema 升级回归和旧历史忽略行为回归。
- 数据库/缓存空间统计。
- 性能分析、崩溃恢复和索引重建验证。
- 更新用户说明和版本发布说明。

## 12. 风险与控制

| 风险 | 影响 | 控制措施 |
| --- | --- | --- |
| n-gram 索引体积过大 | 长期磁盘增长 | contentless FTS、正文只存 bigram、分块基准测试、空间统计 |
| SQLite C API 使用错误 | 崩溃或数据损坏 | 单连接 actor、prepared statement、事务、临时库测试 |
| 旧 UserDefaults 历史被意外重新导入 | 用户明确要求忽略的数据重新出现 | 不实现导入器、初始化后移除旧键、加入回归测试 |
| OCR 阻塞图片显示 | 核心体验回退 | 显示完成后调度、单并发、后台降采样、性能 signpost |
| 书籍 PDF 内存过高 | 卡顿或崩溃 | `PDFPage.string` 逐页、短事务、不拼接整本 |
| PDF 类型误判 | 漏搜或误触发大量处理 | 多页采样、混合型只取文字层、扫描型严格封面 OCR |
| 网页内容包含隐私 | 本地敏感数据扩大 | 仅本机存储、日志脱敏、删除级联、清空历史同步清理 |
| 两次快速查询乱序 | UI 显示旧结果 | 防抖、generation 校验、取消旧 Task |
| 删除时后台任务写回 | 被删记录复活或孤立索引 | cancellation + UUID/指纹复核 + 外键事务 |
| 无限历史导致缓存失控 | 占满磁盘 | 空间统计、手动清理、重建索引，不静默删历史 |

## 13. 工作量预估

以一名熟悉 Swift、AppKit、SQLite、Vision 和 PDFKit 的开发者估算：

| 工作包 | 预估 |
| --- | --- |
| FTS/n-gram 原型 | 2–3 人日 |
| SQLite 封装、schema、Repository | 4–6 人日 |
| 全文分块、索引、排名、摘要 | 4–6 人日 |
| Spotlight 风格搜索 UI 与键盘交互 | 3–5 人日 |
| 图片 OCR 与缩略图 | 2–4 人日 |
| 网页正文索引 | 1–2 人日 |
| PDF 分类、逐页索引和封面 OCR | 3–6 人日 |
| 本地化、数据库升级、性能和压力测试 | 4–5 人日 |

总计约 **23–37 人日**。该估算不包含任何旧 `UserDefaults` 历史迁移工作；新版历史从空 SQLite 数据库开始。如果只实现界面和小数据搜索会更短，但无法满足本文的长期性能与可靠性目标。

## 14. 完成定义

只有同时满足以下条件，历史搜索功能才视为完成：

- 历史记录不再受 30 条持久化限制，也不再整体保存于 UserDefaults。
- 原有 `UserDefaults.historyConfigs` 未被读取或导入，新版历史从空 SQLite 数据库开始。
- 10,000 条历史下启动、最近历史和菜单不全量加载。
- 标题、文本、Markdown、图片 OCR、网页正文和 PDF 规定范围均可搜索。
- 文字型书籍 PDF 按页索引；扫描 PDF 只 OCR 封面。
- 图片 OCR 不阻塞图片显示。
- `⌘F`、两个可见入口、独立搜索面板和全部键盘操作符合交互规格。
- 结果最多 10 条，默认选中第一项，回车和点击始终新建窗口。
- 右键菜单只有“删除”，删除后数据库、索引、任务和缓存一致。
- 数据库初始化/升级、搜索、索引器、UI 和压力测试通过。
- 新增界面字符串全部进入 `Localizable.xcstrings` 并包含中文本地化。
