# foofoil（浮箔）扩展系统实施方案

## 1. 目标

foofoil 的核心定位是轻量、以内容为中心的桌面内容容器。基础程序优先使用
macOS
原生能力；需要额外第三方运行库、编解码器、渲染器或模拟器的能力，以第一方扩展按需安装。

扩展不只用于支持 Core 无法打开的新文件类型，也可以增强或替换已有内容能力。例如，
Core 已能播放 MP3，安装 Hi-Fi 后仍可让 Hi-Fi 接管 MP3 会话，并提供播放列表、音频动效、
输出设备选择和音乐专用菜单。扩展系统因此应围绕“能力贡献”设计，而不能只围绕“文件后缀
到 Viewer”设计。

目标：

-   基础安装包长期保持轻量；
-   用户只安装自己需要的能力；
-   安装、升级、卸载全部在 foofoil 内完成；
-   用户无需自行寻找、下载或复制扩展包；
-   扩展独立开发、独立 Release、独立升级；
-   主程序版本、Extension API 版本、扩展版本彼此解耦；
-   不建设开放的第三方插件市场；
-   不考虑 Mac App Store 限制；
-   官网与 GitHub Release 为发行渠道。

典型体验一：增加新内容类型。

``` text
打开 foo.dsf
    ↓
Core 无法处理
    ↓
Registry 确认 Hi-Fi 可处理
    ↓
提示“安装 Hi-Fi 扩展”
    ↓
下载 → 验证 → 安装 → 加载
    ↓
继续打开原文件
```

典型体验二：增强已有内容能力。

``` text
打开 foo.mp3
    ↓
Core 与已安装扩展都可处理
    ↓
Provider Resolver 按用户选择和稳定优先级选用 Hi-Fi
    ↓
创建包含播放队列、音频 Pipeline 和设备路由的 Session
    ↓
Core 根据 Session Contributions 展示音乐菜单、播放列表与动效入口
    ↓
Hi-Fi 不可用时按声明回退 Built-in Audio Provider
```

## 2. 功能分层

### Core

基础 foofoil 只包含：

-   窗口、悬浮与通用交互；
-   Content Request / Provider Resolver；
-   Content Provider / Content Session 生命周期；
-   扩展贡献点、命令和宿主 UI 协调；
-   通用导航面板及其桌面伴随窗口、全屏覆盖层；
-   Extension Manager；
-   macOS 系统原生支持的内容能力；
-   通用 UI 和状态管理。

原则：macOS 已提供成熟能力的格式，优先使用系统
Framework，不为了统一技术栈重复携带 codec/runtime。

``` text
图片       → ImageIO / AppKit
PDF        → PDFKit
网页       → WebKit
普通音频   → AVFoundation / CoreAudio
普通视频   → AVFoundation
文本       → 系统能力
```

### Extensions

按"能力域"划分，不按单个格式拆插件：

``` text
Hi-Fi
├── DSF / DFF
├── SACD ISO / DST
├── APE / WavPack
├── 增强 MP3 / AAC / ALAC / FLAC 等已有音频
├── 播放列表与播放队列语义（由 Core 通用导航面板呈现）
├── DoP
├── DSD → PCM fallback
├── 音效 / 可视化
├── CoreAudio HAL
├── 输出设备选择
├── Exclusive / Hog Mode
└── 音乐专用菜单与设置

EPUB
├── EPUB parser
└── EPUB renderer

Video+
├── MKV
├── RM / RMVB
├── 系统不支持的容器/codec
└── FFmpeg / 精简 libav*

Retro
├── ROM 类型
├── Emulator Core
├── Controller
└── Game Viewer
```

## 3. 总体架构

``` text
                          foofoil.app
                               │
             ┌─────────────────┴──────────────────┐
             │                                    │
      Extension Manager                    Contribution Host
             │                                    │
      Registry / Installer       Content Request / Provider Resolver
             │                                    │
       Loader / Services                Primary Content Provider
             │                                    │
             └─────────────────┬──────────────────┘
                               │
                        Content Session
                  ┌────────────┼────────────┐
                  │            │            │
           Session Features  Commands   Shared Services
                  │            │            │
                  └────────────┼────────────┘
                               │
                        Host Presentation
```

Core 不需要知道什么是 DSD、EPUB、MKV 或 NES mapper，但必须理解少量稳定的通用概念：

``` text
ContentRequest → Provider Resolution → ContentSession → Presentation

Extension Contributions
├── ContentProvider       增加新的内容类型
├── ProviderOverride      增强或替换已有 Provider
├── SessionFeature        播放列表、音效、字幕、控制器等
├── ApplicationService    音频设备、后台任务等共享服务
├── CommandContribution   菜单、快捷键和宿主 UI 命令
└── NavigatorContribution 列表/树形导航数据及动作，不携带自定义 View
```

第一版不追求任意第三方扩展之间的自由组合。贡献点只覆盖已有真实需求，并由 Core 使用确定性
规则完成选择和协调。

## 4. 扩展性质

扩展是第一方 Optional Components，而不是开放插件平台：

-   全部由 foofoil 官方开发和发布；
-   全部由官方 Developer ID 签名；
-   全部进入官方 Extension Registry；
-   不允许任意第三方二进制成为受信扩展；
-   暂不承诺第三方 SDK 或 ABI；
-   用户界面统一称"扩展 / Extensions"。

扩展内部可以使用 Swift、Objective-C、C、C++、FFmpeg、codec
library、emulator core 等，内部实现不能泄漏到 Core。

## 5. 项目与 Release 组织

建议独立仓库：

``` text
foofoil/foofoil
foofoil/foofoil-extension-kit
foofoil/foofoil-extension-hifi
foofoil/foofoil-extension-epub
foofoil/foofoil-extension-video
foofoil/foofoil-extension-retro
foofoil/foofoil-extension-registry
```

各扩展独立维护：

-   Git history；
-   CI；
-   Semantic Version；
-   Release；
-   Changelog。

Hi-Fi 修复 DSD bug 时，不要求重新发布 foofoil、EPUB 或 Video+。

## 6. 版本模型

三个版本维度必须独立：

``` text
foofoil              2.3.1
Extension API            2
Hi-Fi Extension       1.7.4
```

禁止人为同步版本号。

### Extension API

例如：

``` text
foofoil 1.x → API 1
foofoil 2.x → API 1 + API 2
foofoil 3.x → API 2
```

扩展声明：

``` json
{
  "extensionAPI": {
    "min": 1,
    "max": 2
  }
}
```

Host 与扩展都应声明支持的 API 版本集合。兼容条件为：

``` text
intersection(host.supportedAPIs, extension.supportedAPIs) != empty
```

加载时选择双方共同支持的最高版本，并把选定的精确版本传给扩展入口。`min` / `max`
只有在中间所有版本都兼容时才可作为集合的紧凑表示，不能把 Host 能力建模成单个版本数字。

推荐主程序在 API 换代时保留一代兼容窗口，使各第一方扩展不必与 Core
同日发布。

## 7. ABI 设计

不要把复杂 Swift protocol 直接当作长期二进制 ABI。

推荐：

``` text
Swift / SwiftUI Core
        ↓
    Stable ABI Layer
        ↓
     Extension
        ↓
Swift / C++ / codec / emulator
```

如果需要长期跨独立 Release 保持二进制兼容，边界应尽可能薄，可采用
versioned C ABI / function table。Function table 必须带有精确 API 版本和结构体大小，新增字段
只能追加，调用方必须先检查结构体大小和函数指针是否存在。

概念入口：

``` c
FoofoilExtensionInterface *
foofoil_extension_create(uint32_t negotiated_api_version);
```

Swift protocol、SwiftUI View、`NSView`、`NSMenu` 和进程内对象不能成为长期 ABI，也不能假设
它们未来可以透明跨越 XPC。Core 与扩展之间传递稳定标识、值类型、事件和可序列化状态；
进程内 Viewer 如确有必要，应作为明确受限的 presentation adapter，而不是整个 Extension API
的基础。

ExtensionKit 负责：

-   ABI header；
-   API version；
-   manifest schema；
-   capability identifiers；
-   compatibility fixtures；
-   测试工具。

## 8. Capability Negotiation

不要每增加一个功能就升级 API。

Capability 只负责声明“有什么”，每个可调用能力还必须有对应 contract。第一版建议按作用域
区分：

``` text
Application Scope
├── ApplicationService?
├── DeviceSelector?
└── SettingsProvider?

Session Scope
├── Seekable?
├── MediaPlaybackQueue?
├── AudioEffects?
├── Visualization?
├── Subtitle?
└── ControllerInput?

Presentation Scope
├── CommandProvider?
├── ControlContribution?
├── NavigatorContribution?
└── PresentationAdapter?
```

每个 capability 应定义：

-   稳定 identifier 和 contract version；
-   application / window / session 作用域；
-   supported、available、active、failed 等运行状态；
-   依赖的 capability 和失败降级行为；
-   状态、事件、线程和实时性约束。

主程序按 capability 和当前活动 Session 决定是否展示对应 UI。扩展通过 `CommandDescriptor`
贡献命令，Core 负责构造原生菜单和控件，以统一处理本地化、快捷键冲突、菜单校验、活动窗口
路由和辅助功能。

`media.playback-queue` 与 `ui.navigator` 必须分开：前者定义队列顺序、当前项目、增删、重排、
恢复和多文件授权等会话语义，后者只定义宿主如何取得可导航的列表/树快照以及如何把用户动作
送回会话。PDF 目录只需要提供 `ui.navigator`；Hi-Fi 和视频会话可以同时提供两者。不要使用
`audio.playback-queue` 作为长期通用标识，以免把视频队列错误限制在音频域。

只有发生无法向后兼容的协议/ABI 改动时才升级 Extension API major
version。

## 9. Extension Manifest

示例：

``` json
{
  "id": "app.foofoil.extension.hifi",
  "name": "Hi-Fi",
  "version": "1.4.0",
  "extensionAPI": {
    "min": 1,
    "max": 2
  },
  "system": {
    "minMacOS": "15.0",
    "architectures": ["arm64"]
  },
  "providers": [
    {
      "id": "audio.hifi",
      "role": "override",
      "fallbackProvider": "builtin.audio",
      "contentTypes": [
        {"extensions": ["dsf", "dff"], "strategy": "extension"},
        {"extensions": ["iso"], "strategy": "sniff"},
        {"utTypes": ["public.audio"], "strategy": "conforms"}
      ]
    }
  ],
  "capabilities": [
    "audio.dsd",
    "audio.dop",
    "media.playback-queue",
    "audio.effects",
    "audio.visualization",
    "audio.device-selection",
    "audio.exclusive",
    "ui.music-commands"
  ]
}
```

不能只根据文件后缀判断。例如 `.iso` 必须 content
sniffing，因为它并不必然是 SACD ISO。

`role: override` 表示扩展可处理 Built-in 已支持的内容，而不只负责新增格式。Manifest 中的声明
用于生成候选项，最终选择仍由 Provider Resolver 根据用户偏好、内容匹配程度、运行时可用性和
回退规则决定。

### Content Request 与持久化状态

`ContentRequest` 不能等同于单个文件 URL。第一版至少支持：

``` text
ContentRequest
├── singleFile(URL)
├── fileCollection([URL])
└── restoredSession(extensionID, stateReference)
```

播放列表中的每个外部文件都必须有明确的沙盒授权和安全范围书签生命周期。扩展状态由 Core
保存带 namespace、schema version 的可序列化 payload；扩展负责在兼容版本间迁移自己的
payload，Core 负责大小限制、原子写入和损坏回退。扩展被禁用、撤销或卸载后，Core 仍应能
展示可恢复的占位状态；其中普通 MP3 等内容可降级回 Built-in，扩展专属格式则给出明确提示。

### 通用导航面板

播放队列、PDF/EPUB 目录、多图浏览和视频列表拥有相近的容器交互，但领域状态并不相同。
因此 Core 提供统一的 `Navigator Panel`，Built-in Provider 与扩展 Session 只贡献数据和动作：

``` text
Built-in PDF ──────── PDF 目录
Built-in 图片 ─────── 图片集合
Hi-Fi Extension ───── 播放队列
EPUB Extension ────── 章节目录
Video+ Extension ──── 视频队列 / 章节
                         │
                         ▼
               NavigatorContribution
                         │
                         ▼
                 Core Navigator Host
                  ├── 桌面：箔片外侧伴随面板
                  └── 全屏：箔片内部覆盖层
```

`NavigatorContribution` 是 versioned、可序列化的值类型 contract，第一版只覆盖实际需求：

-   一维列表与树形目录；
-   稳定的 contribution / item identifier 和 revision；
-   内容标题、副标题、SF Symbol、badge、当前项和 enabled 状态；
-   单选或多选状态；
-   activate、remove、move 等明确声明的动作；
-   使用 parent identifier 表达层级，并校验重复 ID、悬空父节点和环；
-   允许一个 Session 提供多个 navigator，例如 PDF 的目录与缩略图、EPUB 的目录与书签；
-   大列表后续可在同一 contract 的新版加入分页或增量 diff，v1 不传递任意 Swift 数据源对象。

条目标题属于内容数据，不要求本地化；面板标题、空状态、菜单和其他宿主 chrome 使用本地化 key。
图片必须使用 Host 管理的资源引用，不能传递 `NSImage`、`NSView` 或 SwiftUI `View`。扩展不能自绘
列表行；Core 使用有限的声明式字段统一处理选择、键盘导航、辅助功能和外观。超出列表/树导航
范畴的音效、属性检查器或控制器界面应使用独立贡献点，不能把 Navigator 演变成任意 UI 容器。

桌面态使用独立伴随面板，不扩大 `FloatingWindow` 的内容 frame，以免改变图片/PDF 比例缩放、
窗口恢复和拖拽行为。用户可按窗口选择左/右侧、鼠标移入/始终显示及宽度；新窗口采用全局默认，
窗口覆盖值由 Core 持久化并向后兼容解码。伴随面板成为 key window 时，菜单和快捷键仍路由到
所属箔片。主窗口移动、关闭、置顶、透明度、Space 和屏幕变化必须同步处理。

全屏时隐藏外侧伴随面板，把同一个状态模型挂载为主内容之上的内侧覆盖层；从用户选择的一侧
滑入，通过边缘 hover 或宿主快捷键触发。桌面与全屏不能维护两份选择、展开或当前项状态。
所选外侧空间不足时可以临时退化为内侧覆盖，但不能静默修改用户的左右偏好。

Core 为每个箔片提供 AppKit 原生全屏 Space，`⌘⌃F` 只切换当前活动窗口。全屏是瞬时展示状态，
不写入窗口历史，也不修改 `showBorder`：无论窗口态原本有无边框，进入全屏后都使用相同的无圆角、
无阴影、无窗口边框展示；退出后恢复原有 frame、置顶层级和边框偏好。全屏期间禁止窗口拖动、
边缘缩放及屏幕 frame 持久化，避免覆盖窗口态恢复数据。

### Provider Resolution

同一内容可以同时存在多个候选 Provider。选择顺序必须稳定且可解释：

1.  用户对当前内容域的显式选择；
2.  扩展专属格式或强匹配的 content sniffing；
3.  已启用且运行时可用的增强 Provider；
4.  Built-in Provider；
5.  按 manifest 声明执行失败回退。

不能只用一个全局数字优先级隐式决定所有冲突。设置中应允许用户决定普通音频默认使用
Built-in 还是 Hi-Fi；扩展初始化或播放失败时，应在不造成状态损坏的前提下回退，并向用户
说明本次使用了哪个 Provider。

## 10. Extension Registry

GitHub Release 只负责二进制分发，Registry 负责发现、版本和兼容关系。

例如：

``` text
Hi-Fi
├── 1.4.2  API 1
├── 1.8.1  API 1-2
└── 2.0.0  API 2
```

若当前 foofoil 只支持 API 1，则安装器选择 1.8.1，而不是机械安装最新的
2.0.0。

Registry Release 信息建议包含：

``` json
{
  "version": "1.8.1",
  "api": {"min": 1, "max": 2},
  "minMacOS": "15.0",
  "architectures": ["arm64"],
  "downloadSize": 6241823,
  "sha256": "...",
  "downloadURL": "...",
  "status": "active"
}
```

状态至少包括：

``` text
active
deprecated
revoked
```

Registry 还可以承担：

``` text
content type → extension
built-in capability → optional enhancement
```

映射，使旧版 foofoil 在 API 和 contribution contract 兼容的前提下发现后来发布的新扩展。
旧版 Host 无法理解的新贡献点必须忽略，不能因为 API major 相同就默认可用。

## 11. 升级策略

正常情况下不强制升级。

目标：

``` text
旧 foofoil + 最新兼容扩展
新 foofoil + 新扩展
```

只有以下情况考虑 revoke 或强制措施：

-   严重安全漏洞；
-   数据损坏风险；
-   Extension API 已停止支持；
-   macOS 删除必要系统能力；
-   扩展存在不可接受的稳定性问题。

优先保留"当前 API
下最后一个安全兼容版本"，而不是要求所有用户升级主程序。

## 12. 发布流程

扩展独立 Release：

``` text
Extension repo
    ↓
CI build
    ↓
Release build
    ↓
codesign 全部 executable / framework / nested code
    ↓
生成待公证 archive
    ↓
notarize + staple + verify（必须）
    ↓
生成最终 archive
    ↓
SHA-256
    ↓
GitHub Release
    ↓
更新 Extension Registry
    ↓
Registry CI 校验
    ↓
发布
```

主程序无需同步发版。

## 13. App 内安装流程

``` text
用户点击安装
    ↓
Extension Manager
    ↓
读取 Registry
    ↓
Compatibility Resolver
    ↓
选择最新兼容 Release
    ↓
HTTPS Download
    ↓
SHA-256 校验
    ↓
安全解压到 staging
    ↓
Manifest / API / 系统兼容性校验
    ↓
Code Signature / notarization 校验
    ↓
Designated Requirement / Team ID / Bundle ID 校验
    ↓
全部 architecture slice、nested code 与 sealed resources 校验
    ↓
Atomic Install
    ↓
注册 Contributions
    ↓
激活（必要时等待 Session 结束或下次启动）
```

不能只依赖 SHA-256，因为 hash 只能证明下载内容与 Registry
声明一致，不能独立证明二进制来自 foofoil 官方。Registry 本身必须具备真实性、完整性、
过期时间和防回滚保护；客户端必须拒绝版本倒退、过期元数据和未受信重定向后的不匹配产物。

签名验证必须使用 Security.framework 对静态代码执行严格校验，覆盖所有 architecture slices、
nested code 和 sealed resources，并使用固定 Team ID 与允许的 Bundle ID 规则。校验后到加载前
不得给未受信代码留下替换文件的窗口；激活前应从最终不可变版本目录再次验证。

解压器必须拒绝绝对路径、`..`、逃逸 staging 的符号链接、特殊设备文件和异常膨胀的 archive，
并限制文件数量、单文件大小和总解压大小。

## 14. 安装目录

建议：

``` text
Application Support/foofoil/（实际路径通过 FileManager 获取）
├── Extensions/
│   ├── HiFi/
│   │   ├── 1.3.2/
│   │   └── 1.4.0/
│   ├── EPUB/
│   └── VideoPlus/
├── ExtensionDownloads/
└── ExtensionState/
```

不要修改 `foofoil.app` bundle，也不要硬编码用户主目录。启用 App Sandbox 时，Foundation
返回的是 App 容器内对应位置。

这样：

-   Core 升级不影响扩展；
-   扩展升级不修改主程序；
-   可独立回滚；
-   卸载简单。

## 15. 原子升级与回滚

不要覆盖当前版本。

``` text
HiFi/
├── 1.3.2/
└── 1.4.0/

ExtensionState/
└── HiFi.json  { "activeVersion": "1.4.0", "previousVersion": "1.3.2" }
```

升级流程：

``` text
下载新版本
 ↓
验证
 ↓
安装到独立目录
 ↓
静态验证 / 独立进程启动测试
 ↓
原子切换激活记录
 ↓
暂时保留上一版本
```

失败时：

``` text
activeVersion → previousVersion
```

`current` 不必实现为符号链接；可使用原子写入的状态文件记录激活版本，避免符号链接解析和
目录替换带来的额外攻击面。至少保留一个已验证的上一版本，并限制总磁盘占用。

## 16. 加载与卸载

第一阶段可以对经过验证的第一方 presentation adapter 使用进程内动态加载，但 codec、解析器、
模拟器等包含大量 native code 或处理不受信输入的部分，应优先评估独立进程：

``` text
foofoil
   ↓
Extension Loader
   ↓
HiFi / EPUB Extension
```

不要依赖 `dlclose()` 做复杂热卸载。

用户"移除"扩展时：

``` text
标记 Disabled
 ↓
停止创建新实例
 ↓
等待相关 Session 结束，或经用户确认后关闭
 ↓
下次启动不加载
 ↓
确认无代码和资源仍被使用后安全删除文件
```

对于 Hi-Fi codec、Video+、EPUB parser、Retro 等处理复杂输入或包含大量第三方 native code
的部分，独立进程/XPC 不是透明的后续实现细节，而是 Phase 0 必须验证的部署边界：

``` text
foofoil
   │ IPC
   ↓
Video+ Service
```

因此 Extension API 从一开始就不应假设 Provider 永远与 Core 同进程。Host Presentation 与
Extension Engine 应通过可序列化状态和命令通信；自定义 `NSView` / SwiftUI Viewer 只能作为
明确的进程内特例。

进程内扩展一旦加载，不依赖 `dlclose()`，同一进程中便不能可靠切换到另一个版本：

-   首次安装且尚未加载：可以立即激活；
-   已加载扩展升级：等待相关 Session 结束，并在下次 App 启动时激活；
-   已有 Session 使用期间移除：先禁止创建新 Session，旧 Session 结束后再删除；
-   独立进程扩展：完成状态保存和连接排空后重启服务，再切换版本。

## 17. Content Router 与 Provider Resolver

统一处理 Built-in、扩展新类型和对已有能力的增强：

``` text
ContentRequest
   ↓
UTType / extension / content sniffing / request kind
   ↓
候选 Primary Provider
   ↓
用户偏好 / 运行时可用性 / fallback
   ↓
┌────────────────────────┐
│ Built-in Provider      │
│ Extension Provider     │
│ Extension Override     │
│ Available Extension    │
│ Unsupported            │
└────────────────────────┘
   ↓
ContentSession
   ↓
Session Features / Commands / Shared Services
```

结果：

-   Built-in：直接打开；
-   Extension Provider：由扩展处理 Core 不支持的内容；
-   Extension Override：按解析规则增强或替换 Built-in；
-   Available Extension：提示"安装并打开"；
-   Unsupported：明确提示当前没有 Provider。

Resolver 的结果应包含选中原因和 fallback 链，供日志、错误提示和测试使用。扩展安装或启用
不能无提示改变正在运行的 Session；只影响后续新建 Session，除非用户明确选择切换。

## 18. 扩展管理 UI

``` text
设置
└── 扩展
```

示例：

``` text
Hi-Fi
高级本地音频与高保真输出
DSF · DFF · SACD · APE · 增强现有音频
播放列表 · 动效 · DoP · 独占输出 · 设备选择
6.2 MB
                                  [安装]

EPUB
EPUB 电子书阅读
2.3 MB
                           [已安装] [移除]

Video+
扩展视频格式
MKV · RM · RMVB · ...
21.8 MB
                                  [安装]
```

已安装扩展显示版本和更新状态。

对增强 Built-in 的扩展，还应显示默认处理方式，例如：

``` text
普通音频默认使用：[Hi-Fi ▾]
                  Hi-Fi
                  系统播放器
```

这里的选择是内容域偏好，不是修改文件关联。扩展专属格式始终由可处理它的扩展打开。

## 19. 自动更新

推荐：

-   自动检查更新：默认开；
-   自动下载：可配置；
-   自动安装兼容的小版本：可配置；
-   永远通过 Compatibility Resolver 选择版本。

对于 `revoked`：

-   禁止新安装；
-   已安装版本停止加载；
-   自动寻找安全兼容版本；
-   没有兼容版本时明确提示。

## 20. 安全模型

下载的是 executable code，即使全部为第一方，也必须视为供应链边界。

最低要求：

1.  HTTPS；
2.  Registry 完整性保护；
3.  SHA-256；
4.  Developer ID Code Signature 与 notarization；
5.  designated requirement、Team ID、Bundle ID 校验；
6.  所有 architecture slices、nested code、sealed resources 校验；
7.  Manifest Schema 校验；
8.  API 与 contribution contract compatibility 校验；
9.  architecture / macOS compatibility 校验；
10. staging；
11. 防 TOCTOU 的原子 activation；
12. rollback；
13. Registry 签名、过期和防回滚保护。

当前 App 启用了 App Sandbox 与 Hardened Runtime。Phase 0 必须完成真实签名样机，验证沙盒
容器内安装、Library Validation、quarantine/notarization、跨进程 bookmark 传递，以及扩展所需
entitlement 是否与主程序发布方式兼容。不能等到 Hi-Fi 或 Video+ 完成后再验证这些前提。

## 21. Hi-Fi 作为首个正式扩展

Hi-Fi 很适合验证整个 Extension System，因为它同时涉及：

``` text
文件类型
DSF / DFF / SACD / APE / WavPack

增强已有内容
MP3 / AAC / ALAC / FLAC 等统一 Hi-Fi Pipeline
Built-in Audio Provider fallback

Session
播放列表 / 播放队列
当前曲目 / 播放位置 / 后台播放

播放 Pipeline
DSD → DoP
DSD → PCM fallback
音效处理 / 音频可视化

系统能力
CoreAudio HAL
Hog / Exclusive
Audio Device Selection

扩展设置
输出设备
DSD 输出模式
独占模式

UI Contributions
音乐专用菜单
播放队列数据与通用导航面板入口
```

它能验证 Extension API 是否足够支持文件
Provider、已有 Provider 增强、播放队列及其 Navigator 投影、Host Presentation、后台播放、命令与菜单、设置面板、
系统设备、native library、状态迁移、失败回退和独立升级。

音乐专用菜单由 Core 根据活动窗口对应 Session 的 `CommandDescriptor` 构建。扩展提供本地化
资源键、图标建议、快捷键建议、enabled/checked 状态和命令调用入口；Core 保留最终快捷键、
菜单位置、验证和辅助功能控制权。

音频实时线程不得执行内存分配、文件 I/O、网络、锁等待或 UI 更新。设备拔插、默认设备变化、
采样率切换、Hog Mode 获取失败和扩展进程崩溃都必须有明确状态机，并保证退出时释放设备。

## 22. EPUB 迁移

如果 EPUB 当前已经编入 Core，Extension System 稳定后迁出：

``` text
Core
 ↓
EPUB Extension
 ↓
EPUB renderer
```

升级旧用户时应检测既有使用情况，必要时自动安装或明确提示，不能让原本能打开的
EPUB 无解释失效。

## 23. Video+

系统能播放：

``` text
AVFoundation → Built-in
```

系统不能播放：

``` text
MKV / RM / exotic codec
        ↓
      Video+
        ↓
 FFmpeg / libav*
```

即使 Video+ 增加几十 MB，没有安装它的用户也不承担这些体积。

## 24. Retro / Game

``` text
foo.nes
   ↓
Content Router
   ↓
Retro Extension
   ↓
Emulator Core
   ↓
Content Session + Host Presentation
```

因此 API 不应命名为 `DocumentPlugin` 或 `MediaPlugin`，更适合：

``` text
ContentProvider
ContentSession
SessionFeature
PresentationAdapter
```

避免未来被文档或音视频模型限制。

## 25. 实施阶段

### Phase 0：ExtensionKit

完成：

-   Manifest Schema；
-   Extension API v1；
-   ABI 边界；
-   ContentRequest（单文件、文件集合、恢复状态）；
-   ContentProvider；
-   ProviderOverride 与稳定的 Resolver / fallback；
-   ContentSession；
-   capability negotiation；
-   CommandDescriptor 与宿主菜单样机；
-   `ui.navigator` v1 contract、校验、动作路由与宿主伴随面板样机；
-   所有箔片共用的原生全屏切换，以及 Navigator 从伴随面板到内侧覆盖层的无状态迁移；
-   一维列表和树形目录 Test Extension fixture，证明扩展不传递自定义 View；
-   namespaced、versioned extension state；
-   Extension Loader；
-   本地 Test Extension；
-   真实签名、notarization、App Sandbox、Hardened Runtime 和跨进程样机。

验收：

``` text
Test.foo → TestExtension → ContentSession → Host Presentation
         → NavigatorContribution（flat + outline）→ Core Navigator Panel

Test.mp3 → Built-in / AudioEnhancer 候选
         → 选择 AudioEnhancer
         → 增加 Session 命令和测试菜单
         → AudioEnhancer 失败后回退 Built-in
```

第二条验收必须存在，否则只能证明“新增文件类型”，不能证明扩展系统可以增强原有能力。
Navigator 样机还必须验证旧 Session 缺少 contribution 字段时可正常解码、非法层级被拒绝、
条目动作可沿既有值消息/XPC 边界路由，以及伴随面板获得焦点后活动窗口命令仍指向所属箔片。

### Phase 1：Extension Manager

完成：

-   Registry；
-   Compatibility Resolver；
-   下载；
-   SHA-256；
-   notarization、严格 Code Signature、Team ID / Bundle ID；
-   archive 安全解压与资源限制；
-   staging；
-   atomic install；
-   update；
-   rollback；
-   uninstall；
-   扩展设置页。

验收：从 App 内安装测试扩展，无需用户处理扩展包即可打开对应文件或增强已有 Provider；升级、
撤销、回滚和卸载不破坏已有 Session 与持久化状态。

### Phase 2：Hi-Fi

实现：

-   DSF / DFF；
-   SACD ISO / DST；
-   APE / WavPack；
-   增强 MP3 / AAC / ALAC / FLAC 等已有音频；
-   Built-in fallback 与默认 Provider 设置；
-   `media.playback-queue` 播放列表 / 播放队列语义及多文件授权恢复；
-   向 Core `Navigator Panel` 提供一维播放队列投影，不实现扩展私有侧栏；
-   DoP；
-   DSD → PCM fallback；
-   音效 / 可视化；
-   Audio Device Selection；
-   Exclusive / Hog；
-   音乐专用菜单与命令。

作为第一块正式扩展验证完整架构。

重点验收：

-   MP3 在 Built-in 与 Hi-Fi 间切换，失败时正确回退；
-   播放列表重启后恢复，缺失文件和失效 bookmark 可解释、可重新授权；
-   播放队列与 PDF 树形目录由同一个 Core Navigator Panel 呈现；
-   活动窗口切换时音乐菜单、快捷键和 enabled 状态同步；
-   输出设备拔插、默认设备变化和采样率变化不中断其他窗口；
-   Hog Mode 获取失败、Session 关闭和进程异常退出时可靠释放设备；
-   扩展升级、禁用或撤销时，正在播放与后续新建 Session 行为明确。

### Phase 3：EPUB

把 EPUB 重型依赖从 Core 迁出，验证 renderer/resource-heavy
类型扩展和旧功能迁移。EPUB 扩展贡献树形目录数据与跳转动作，由 Core Navigator Panel 呈现，
不携带扩展私有列表 View。

### Phase 4：Video+

加入 FFmpeg / libav\*、MKV、RM/RMVB 等，并依据 Phase 0 结果将高风险解码放入独立进程。
视频队列复用 `media.playback-queue`，列表与章节复用 `ui.navigator`。

### Phase 5：Retro

验证 Emulator Core、Controller、高交互 ContentSession 和独立进程模型。

## 26. 第一版 API 应保持克制

API v1 只解决已有真实需求：

``` text
Extension
├── Metadata
├── ContentRequest
├── ContentProvider
├── ProviderOverride?
├── ContentSession
├── SessionFeature?
├── ApplicationService?
├── CommandProvider?
├── PresentationAdapter?
├── SettingsProvider?
├── Content Type / Enhancement Registration
└── Capability Declaration
```

先用 Hi-Fi、EPUB、Video+ 三种差异明显的扩展验证抽象。即使扩展均为第一方，也不在 v1
支持任意 Swift/SwiftUI 类型穿过 ABI、任意菜单注入、任意扩展互相依赖或任意多 Provider
装饰链。

在此之前不为假想的第三方生态增加复杂度。

## 27. 技术决策汇总

  项目                            决策
  ------------------------------- -----------------------------
  基础 App                        尽可能只依赖 macOS 系统能力
  扩展                            第一方、按需安装
  App 内安装                      必须
  用户手工安装                    不需要
  第三方插件市场                  不做
  Mac App Store                   不考虑
  官网 / GitHub Release           正式发行渠道
  扩展独立 repo                   是
  扩展独立 Release                是
  扩展独立版本                    是
  与 foofoil 同步发版             否
  Extension API 独立版本          是
  主程序兼容多代 API              建议，按版本集合协商
  Capability Negotiation          是
  增强 Built-in Provider          是，支持 override 与 fallback
  多文件 / 播放列表               ContentRequest 原生支持
  列表 / 树形目录呈现              Core Navigator Panel + versioned contribution
  菜单与快捷键                    Core 根据 CommandDescriptor 构建
  持久化扩展状态                  namespaced + schema version
  Registry                        统一
  Registry 保留历史兼容 Release   是
  自动选择最新兼容版本            是
  普遍强制升级                    否
  安全版本 revoke                 是
  校验                            Registry + SHA-256 + 严格签名 + notarization
  安装                            staging + atomic activation
  回滚                            是
  强制热卸载动态库                否
  高风险扩展进程隔离              Phase 0 验证，按风险采用
  首个正式扩展                    Hi-Fi

## 28. 最终架构原则

``` text
                     foofoil
                       │
             “内容 → 桌面上的一层”
                       │
       ┌───────────────┼───────────────┐
       │               │               │
   Built-in        Extensions       Registry
       │               │               │
 macOS native     新能力与增强     发现/版本/兼容
                       │
              ┌────────┼────────┬────────┐
              │        │        │        │
            Hi-Fi     EPUB    Video+   Retro
```

新增重型能力时：

``` text
macOS 原生能力足够？
       │
   ┌───┴───┐
   │       │
  Yes      No
   │       │
 Core   属于已有扩展能力域？
           │
       ┌───┴───┐
       │       │
      Yes      No
       │       │
 扩展现有组件   评估新 Extension
```

核心约束：

> foofoil Core
> 不随着支持格式和增强能力越来越多而无限膨胀。用户只为自己实际安装的能力承担下载体积、
> 依赖和运行成本。

同时遵守以下原则：

-   扩展既可以增加新内容类型，也可以增强已有能力；
-   Core 保留窗口、生命周期、命令路由、持久化边界和原生交互控制权；
-   Provider 选择、失败回退、状态迁移和卸载降级必须稳定、可测试、可解释；
-   扩展内部实现可以独立演进，但新增 Host 不理解的贡献点仍需要 Host 支持，独立 Release 不等于
    功能契约可以脱离 Core 演进；
-   安全和进程边界在 Phase 0 通过真实发布条件验证，不作为后续实现细节处理。
