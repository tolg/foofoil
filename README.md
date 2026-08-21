# Flamina 浮箔

[简体中文](README.zh-CN.md)

Flamina is a lightweight reference app for macOS that keeps images, videos, documents, notes, and web content visible in minimal floating windows while you work.

The name Flamina comes from *floating lamina*: a thin layer of content that can rest anywhere in your workspace, without the visual weight of a traditional window.

In Chinese, Flamina is called 浮箔 (Fú Bó), evoking the same idea of a lightweight, paper-thin layer that stays close at hand without getting in the way.

Built with SwiftUI and AppKit, Flamina favors native macOS capabilities, fast interaction, and a small dependency footprint.

Flamina is published by Beijing Memory Vision Technology Co., Ltd. and distributed as open-source software under the MIT License.

## Features

- Open multiple independent floating windows.
- Pin a window above other apps, adjust its opacity, and show or hide its border.
- Drag, resize, zoom, and position windows across multiple displays.
- Open images, PDFs, plain text, Markdown, CSV, HTML, web archives, and web URLs.
- Paste or open an image directly from the clipboard.
- Preview Markdown, browse CSV data as a table, and navigate PDF pages.
- Zoom images and web content, fit images to a window, and customize SVG or window background colors.
- Save, copy, share, or capture displayed content using native macOS workflows.
- Restore window state and keep a local content history.
- Search history by title and content, including on-device OCR for images and extracted text from PDFs and web pages.
- Use English or Simplified Chinese throughout the interface.

## Quick Start

Launch Flamina and then use any of these methods:

- Drag a supported file, image, or text onto a Flamina window.
- Choose **File > Open** (<kbd>⌘ O</kbd>) to open a local file.
- Choose **File > Open URL** (<kbd>⌘ L</kbd>) to display a web page.
- Choose **File > Open Clipboard Image** (<kbd>⇧ ⌘ V</kbd>) to create a reference from the clipboard.
- Start typing in an empty window to use it as a note.

Right-click a window to access the most relevant actions for its current content.

## Useful Keyboard Shortcuts

| Action | Shortcut |
| --- | --- |
| New Flamina window | <kbd>⌘ N</kbd> |
| Open a file | <kbd>⌘ O</kbd> |
| Open a URL | <kbd>⌘ L</kbd> |
| Open clipboard image | <kbd>⇧ ⌘ V</kbd> |
| Search history | <kbd>⌘ P</kbd> |
| Toggle always on top | <kbd>⌘ T</kbd> |
| Toggle border | <kbd>⌘ B</kbd> |
| Zoom content in/out | <kbd>⌘ +</kbd> / <kbd>⌘ −</kbd> |
| Reset content size | <kbd>⌘ 0</kbd> |
| Reset the current window | <kbd>⌘ K</kbd> |
| Close the current window | <kbd>⌘ W</kbd> |
| Increase/decrease opacity | <kbd>⇧ ⌘ ↑</kbd> / <kbd>⇧ ⌘ ↓</kbd> |

Additional content-specific and window-position shortcuts are available from the macOS menu bar.

## Requirements

- macOS 26.5 or later, matching the current project deployment target
- Xcode with support for the configured macOS SDK

## Build from Source

1. Open `flamina.xcodeproj` in Xcode.
2. Select the `flamina` scheme and the **My Mac** destination.
3. Configure a development signing team if Xcode requests one.
4. Build and run the project.

To build from the command line:

```sh
xcodebuild build \
  -project flamina.xcodeproj \
  -scheme flamina \
  -configuration Debug \
  -destination 'platform=macOS'
```

To run the test suite:

```sh
xcodebuild test \
  -project flamina.xcodeproj \
  -scheme flamina \
  -destination 'platform=macOS'
```

## Technology

Flamina is implemented primarily with SwiftUI and uses AppKit for native floating-window, menu, text-control, and visual-effect behavior. Its content and search features use Apple frameworks including WebKit, PDFKit, Vision, ImageIO, Uniform Type Identifiers, and SQLite3. Markdown rendering uses the existing vendored cmark library.

History and cached content are stored locally in the user's Application Support directory. OCR and indexing run on the device; Flamina only requires network access when displaying remote web content.

## Development Principles

- Keep the app lightweight and responsive.
- Prefer macOS system frameworks and established project components.
- Avoid heavyweight or unnecessary third-party dependencies.
- Preserve native macOS behavior, accessibility, and localization.
- Keep persisted data backward compatible and user-owned files safe.

See [AGENTS.md](AGENTS.md) for the full contribution and implementation guidelines.

## Contributing

Contributions are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) before submitting a change.

## License

Flamina is licensed under the [MIT License](LICENSE), copyright © 2026 Beijing Memory Vision Technology Co., Ltd.

The bundled cmark library is distributed under its own permissive licenses. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for the required notices.
