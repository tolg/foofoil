# foofoil 浮箔

**Anything, right where you need it.**
**给你的桌面降维。**

[简体中文](README.zh-CN.md)

foofoil is a lightweight reference app for macOS that keeps images, videos, audio, documents, notes, and web content visible in minimal floating windows — called foils — while you work.

The name **foofoil** combines *foo* — the familiar placeholder for anything or arbitrary content — with *foil*, a thin sheet that carries whatever you put on it. It reflects a simple idea: whatever the content is, keep it lightweight and right where you need it.

Built with SwiftUI and AppKit, foofoil favors native macOS capabilities, fast interaction, and a small dependency footprint. Formats that need extra codecs, renderers, or runtimes ship as optional first-party extensions and are installed from inside the app.

## Features

- Open multiple independent floating windows.
- Pin a window above other apps, adjust its opacity, and show or hide its border.
- Drag, resize, zoom, and position windows across multiple displays.
- Open images, videos, audio, PDFs, plain text, Markdown, CSV, HTML, and web URLs.
- Paste or open an image directly from the clipboard.
- Preview Markdown, browse CSV data as a table, and navigate PDF pages.
- Zoom images and web content, fit images to a window, and customize SVG or window background colors.
- Save, copy, share, or capture displayed content using native macOS workflows.
- Restore window state and keep a local content history.
- Search history by title and content, including on-device OCR for images and extracted text from PDFs and web pages.
- Use English or Simplified Chinese throughout the interface.
- Install optional first-party extensions from Settings when you need capabilities beyond macOS-native formats.

## Extensions

foofoil Core stays small: windows, history, and content types that macOS already handles well (images, PDF, web, ordinary audio and video, text). Additional capability domains are independent repositories with their own versioning and releases:

| Repository | Role |
| --- | --- |
| [extension-kit](https://github.com/foofoil/extension-kit) | Extension API contracts, ABI header, Manifest schema, and fixtures |
| [hifi](https://github.com/foofoil/hifi) | Hi-Fi audio extension. Requires foofoil. |

Host loading, the Extension Manager, Registry client, and UI remain in this repository. Check out sibling directories when developing locally. `./run` injects the sibling `hifi` Debug plugin when `../hifi/build-plugin` exists; Xcode ⌘R does not.

```text
foofoil/
  foofoil/
  extension-kit/
  hifi/
```

## Quick Start

Launch foofoil and then use any of these methods:

- Drag a supported file, image, or text onto a foofoil window.
- Choose **File > Open** (<kbd>⌘ O</kbd>) to open a local file.
- Choose **File > Open URL** (<kbd>⌘ L</kbd>) to display a web page.
- Choose **File > Open Clipboard Image** (<kbd>⇧ ⌘ V</kbd>) to create a reference from the clipboard.
- Start typing in an empty window to use it as a note.

Right-click a window to access the most relevant actions for its current content.

## Useful Keyboard Shortcuts

| Action | Shortcut |
| --- | --- |
| New foofoil window | <kbd>⌘ N</kbd> |
| Open a file | <kbd>⌘ O</kbd> |
| Open a URL | <kbd>⌘ L</kbd> |
| Open clipboard image | <kbd>⇧ ⌘ V</kbd> |
| Search history | <kbd>⌘ P</kbd> |
| Toggle always on top | <kbd>⌘ T</kbd> |
| Toggle border | <kbd>⌘ B</kbd> |
| Zoom content in/out | <kbd>⌘ +</kbd> / <kbd>⌘ −</kbd> |
| Zoom window in/out | <kbd>⇧ ⌘ +</kbd> / <kbd>⇧ ⌘ −</kbd> |
| Open Settings | <kbd>⌘ ,</kbd> |
| Reset content size | <kbd>⌘ 0</kbd> |
| Reset the current window | <kbd>⌘ K</kbd> |
| Close the current window | <kbd>⌘ W</kbd> |
| Increase/decrease opacity | <kbd>⇧ ⌘ ↑</kbd> / <kbd>⇧ ⌘ ↓</kbd> |

Additional content-specific and window-position shortcuts are available from the macOS menu bar.

## Requirements

- macOS 26.5 or later, matching the current project deployment target
- Xcode with support for the configured macOS SDK

## Build from Source

Check out `extension-kit` as a sibling of this repository. The Xcode project links it as a local package at `../extension-kit`.

1. Open `foofoil.xcodeproj` in Xcode.
2. Select the `foofoil` scheme and the **My Mac** destination.
3. Configure a development signing team if Xcode requests one.
4. Build and run the project.

To build from the command line:

```sh
xcodebuild build \
  -project foofoil.xcodeproj \
  -scheme foofoil \
  -configuration Debug \
  -destination 'platform=macOS'
```

To run the test suite:

```sh
xcodebuild test \
  -project foofoil.xcodeproj \
  -scheme foofoil \
  -destination 'platform=macOS'
```

## Technology

foofoil is implemented primarily with SwiftUI and uses AppKit for native floating-window, menu, text-control, and visual-effect behavior. Its content and search features use Apple frameworks including WebKit, PDFKit, Vision, ImageIO, Uniform Type Identifiers, and SQLite3. Markdown rendering uses the existing vendored cmark library.

History and cached content are stored locally in the user's Application Support directory. OCR and indexing run on the device; foofoil only requires network access when displaying remote web content.

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

foofoil is licensed under the [MIT License](LICENSE), copyright © 2026 Beijing Memory Vision Technology Co., Ltd.

The bundled cmark library is distributed under its own permissive licenses. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for the required notices.
