# 浮箔 Flamina

[English](README.md)

浮箔是一款轻量级 macOS 悬浮参考应用。它可以把图片、视频、文档、笔记和网页内容放在极简悬浮窗口中，让参考资料在工作时始终触手可及。

「浮箔」之名取自悬浮的薄片：一层可以停放在工作区任意位置的轻量内容，没有传统窗口的视觉负担。

其英文名 Flamina 源自 *floating lamina*，同样传达薄如纸片、触手可及又不碍事的轻盈之意。

浮箔使用 SwiftUI 与 AppKit 构建，优先利用 macOS 原生能力，追求快速、自然的交互和尽可能少的依赖。

## 功能特性

- 打开多个相互独立的悬浮窗口。
- 将窗口置于其他应用之上，调整其透明度，并显示或隐藏边框。
- 在多显示器间拖动、调整大小、缩放和定位窗口。
- 打开图片、视频、PDF、纯文本、Markdown、CSV、HTML 和网站。
- 直接从剪贴板粘贴或打开图片。
- 预览 Markdown、以表格方式浏览 CSV 数据，并导航 PDF 页面。
- 缩放图片和网页内容、让图片适应窗口，以及自定义 SVG 或窗口背景色。
- 使用 macOS 原生工作流保存、复制、分享或截取显示的内容。
- 恢复窗口状态，并在本地保存内容历史。
- 按标题和内容搜索历史记录，包括使用设备端 OCR 识别图片，以及提取 PDF 和网页文本。
- 完整支持英文与简体中文界面。

## 快速开始

启动浮箔后，可以通过以下任一方式添加内容：

- 将支持的文件、图片或文本拖放到浮箔窗口。
- 选择“文件 > 打开”（<kbd>⌘ O</kbd>）来打开本地文件。
- 选择“文件 > 打开 URL”（<kbd>⌘ L</kbd>）来显示网页。
- 选择“文件 > 打开剪贴板图片”（<kbd>⇧ ⌘ V</kbd>）来创建图片参考窗口。
- 在空白窗口中直接输入，将其作为便笺使用。

右键单击窗口，可以访问与当前内容最相关的操作。

## 常用快捷键

| 操作 | 快捷键 |
| --- | --- |
| 新建浮箔窗口 | <kbd>⌘ N</kbd> |
| 打开文件 | <kbd>⌘ O</kbd> |
| 打开 URL | <kbd>⌘ L</kbd> |
| 打开剪贴板图片 | <kbd>⇧ ⌘ V</kbd> |
| 搜索历史记录 | <kbd>⌘ P</kbd> |
| 切换置顶 | <kbd>⌘ T</kbd> |
| 切换边框 | <kbd>⌘ B</kbd> |
| 放大/缩小内容 | <kbd>⌘ +</kbd> / <kbd>⌘ −</kbd> |
| 恢复内容实际大小 | <kbd>⌘ 0</kbd> |
| 重置当前窗口 | <kbd>⌘ K</kbd> |
| 关闭当前窗口 | <kbd>⌘ W</kbd> |
| 增加/降低不透明度 | <kbd>⇧ ⌘ ↑</kbd> / <kbd>⇧ ⌘ ↓</kbd> |

更多与内容类型及窗口位置相关的快捷键可以在 macOS 菜单栏中查看。

## 系统要求

- macOS 26.5 或更高版本，与项目当前的部署目标一致
- 支持项目所配置 macOS SDK 的 Xcode 版本

## 从源码构建

1. 使用 Xcode 打开 `flamina.xcodeproj`。
2. 选择 `flamina` Scheme 和 **My Mac** 运行目标。
3. 如果 Xcode 提示签名问题，请配置开发者签名团队。
4. 构建并运行项目。

使用命令行构建：

```sh
xcodebuild build \
  -project flamina.xcodeproj \
  -scheme flamina \
  -configuration Debug \
  -destination 'platform=macOS'
```

运行测试：

```sh
xcodebuild test \
  -project flamina.xcodeproj \
  -scheme flamina \
  -destination 'platform=macOS'
```

## 技术实现

浮箔主要使用 SwiftUI 实现界面，并通过 AppKit 实现原生悬浮窗口、菜单、文本控件和视觉效果。内容展示与搜索功能使用了 WebKit、PDFKit、Vision、ImageIO、Uniform Type Identifiers 和 SQLite3 等 Apple 框架。Markdown 渲染使用项目现有的内置 cmark 库。

历史记录和缓存内容保存在用户的 Application Support 目录中。OCR 与内容索引均在本机完成；只有在显示远程网页时，浮箔才需要使用网络连接。

## 开发原则

- 保持应用轻量、快速响应。
- 优先使用 macOS 系统框架和项目已有组件。
- 避免引入重量级或不必要的第三方依赖。
- 保持原生 macOS 交互、无障碍支持和本地化完整性。
- 确保持久化数据向后兼容，并保护用户拥有的文件。

完整的贡献与实现规范请参阅 [AGENTS.md](AGENTS.md)。

## 参与贡献

欢迎参与浮箔的开发。提交更改前请先阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 许可证

浮箔使用 [MIT License](LICENSE)，版权所有 © 2026 北京记忆视界科技有限公司。

应用内置的 cmark 库使用其自身的宽松开源许可证，所需声明请参阅 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
