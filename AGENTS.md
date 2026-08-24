# Agent Instructions for foofoil

## Project Overview

foofoil is a lightweight macOS reference app built for keeping useful content visible while working. It presents content in minimal floating windows that can be borderless, resizable, draggable, translucent, and pinned above other windows.

The app is written in Swift and uses SwiftUI for most interface code, with AppKit where direct macOS window, menu, text, or visual-effect control is required. It also uses native Apple frameworks for web content, PDFs, OCR, images, file types, and persistence.

## Core Product Principles

1. **Keep foofoil lightweight.** Favor small, focused implementations with low runtime, memory, launch-time, and binary-size costs. Do not add infrastructure that is disproportionate to the feature.
2. **Use macOS capabilities first.** Prefer SwiftUI, AppKit, Foundation, WebKit, PDFKit, Vision, ImageIO, Uniform Type Identifiers, SQLite3, and other system APIs before considering custom or third-party solutions.
3. **Avoid heavyweight dependencies.** Do not add a package, framework, service, build tool, or generated abstraction unless native APIs cannot reasonably meet the requirement. Any new dependency must have a clear benefit, a narrow scope, and an acceptable maintenance and distribution cost.
4. **Preserve the native macOS experience.** Follow platform conventions for menus, keyboard shortcuts, focus, file opening, window behavior, accessibility, appearance, and input handling, while retaining foofoil's minimal borderless design.
5. **Prefer incremental change.** Reuse existing components and patterns, keep diffs focused, and avoid unrelated refactors.

## Architecture and Implementation Guidelines

- Use SwiftUI for declarative views and ordinary state-driven UI. Bridge to AppKit only when SwiftUI does not provide the windowing or control behavior foofoil needs.
- Keep window behavior in the existing floating-window/controller layer and content state in `AppState`; avoid duplicating window lifecycle or content-mode state inside individual views.
- Use `SettingsStore` or `UserDefaults` for simple user preferences and restorable window state. Use the existing history repository and SQLite database for searchable history data; do not introduce another persistence layer for the same domain.
- Maintain backward-compatible decoding and sensible defaults when adding fields to persisted models such as `WindowConfig`. Existing user data must continue to load.
- Keep file and cache ownership explicit. Store app-managed files in the established Application Support or cache locations, and remove only files foofoil owns.
- Keep expensive I/O, indexing, OCR, PDF processing, and database work off the main thread. UI and AppKit mutations must remain on the main actor/thread.
- Respect Swift concurrency isolation. Prefer structured concurrency and existing queues over detached or unbounded background work.
- Avoid premature abstractions. Introduce a type or protocol when it clarifies an actual boundary or enables testing, not merely to wrap a native API.
- Preserve existing documentation comments. Add concise Chinese comments for new core logic, especially where window behavior, persistence, concurrency, or platform-specific workarounds are not self-evident. Do not comment obvious code.

## User Interface and Accessibility

- Preserve smooth dragging, resizing, hover feedback, fade transitions, and multi-window behavior.
- Verify changes in both light and dark appearances when they affect colors, materials, borders, or overlays.
- Prefer semantic system colors, materials, SF Symbols, standard controls, and native menus over custom replicas.
- Provide accessibility labels or help text for icon-only or otherwise ambiguous controls.
- Keep keyboard shortcuts and menu commands consistent with standard macOS behavior and ensure they target the active floating window.
- Do not sacrifice discoverability or input reliability for a borderless visual treatment.

## Localization

- All user-facing strings must be localizable. Do not hard-code visible text in Swift.
- When adding or changing UI text, update `foofoil/Localizable.xcstrings` and keep the English and Simplified Chinese translations complete.
- Update `foofoil/InfoPlist.xcstrings` when changing localized metadata from the property list.
- Avoid assembling translated sentences from fragments. Use format placeholders and translator-friendly context where needed.

## Dependencies and Assets

- foofoil source code is distributed under the MIT License. Ensure new code and assets can legally be distributed under that license, and preserve all required third-party notices.
- The default decision for a new third-party dependency is **no**. First document why Apple frameworks or a small local implementation are insufficient.
- Prefer dependencies that can be removed cleanly and that do not require a separate runtime, background service, or broad transitive dependency graph.
- Do not replace or expand the existing vendored cmark integration casually; evaluate binary size, licensing, security, and maintenance impact before changing it.
- Do not commit generated build products, test artifacts, profiling output, or machine-specific project state.
- Reuse asset-catalog resources and SF Symbols where practical. Add raster assets only when a system or vector asset cannot express the design.

## Testing and Verification

- Add or update focused tests for behavior changes, persistence migrations, parsing, history/search behavior, and regressions.
- Prefer the Swift Testing framework for unit tests already under `foofoilTests`; use XCTest for UI tests under `foofoilUITests`.
- Build the app and run the relevant tests before considering a change complete. A typical full verification command is:

  ```sh
  xcodebuild test -project foofoil.xcodeproj -scheme foofoil -destination 'platform=macOS'
  ```

- For window interaction, menus, drag and drop, keyboard handling, or visual changes that are impractical to cover with unit tests, perform a focused manual check and report what was verified.
- Treat new warnings as defects. Do not silence warnings without addressing or documenting the underlying reason.
- After completing a task that results in app code changes, run `./run` from the repository root to build and launch the app so the user can directly see the result. Skip this only if the change cannot or should not affect the running app.

## Change Discipline

- Inspect the surrounding implementation before editing and follow existing naming, formatting, and ownership patterns.
- When creating a file with a `Created by` header, use the human identity returned by `git config user.name`. Never use an agent, model, assistant, or tool name. If no Git user name is configured, ask the user for the correct attribution before creating the header; human attribution is required for accountability and traceability.
- Preserve unrelated user changes in the working tree.
- Do not change the deployment target, entitlements, sandbox permissions, file associations, signing settings, or bundle identifier unless the task explicitly requires it.
- Keep privacy-sensitive work local when native on-device APIs are available. Do not add analytics, telemetry, remote processing, or network services without explicit product requirements.
- When a tradeoff is necessary, prefer predictable behavior, data safety, and maintainability over feature breadth.

## Git Commit Guidelines

- Write commit messages in English.
- Follow Conventional Commits and keep the subject concise, for example: `feat: add PDF page navigation` or `fix: preserve pinned window state`.
- Keep each commit focused on one coherent change and do not include generated or unrelated files.
