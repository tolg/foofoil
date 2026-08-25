//
//  MarkdownTextView.swift
//  foofoil
//
//  Created by tolg on 2026/7/10.
//

import SwiftUI
import AppKit

private final class MarkdownCopyButton: NSButton {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

private final class MarkdownNSTextView: NSTextView {
    private var codeBlockTrackingArea: NSTrackingArea?
    private var hoveredCodeBlockRange: NSRange?
    private var copyFeedbackReset: DispatchWorkItem?
    private lazy var copyCodeButton: NSButton = {
        let button = MarkdownCopyButton()
        button.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        button.imagePosition = .imageOnly
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = NSLocalizedString("Copy", comment: "")
        button.setAccessibilityLabel(NSLocalizedString("Copy", comment: ""))
        button.target = self
        button.action = #selector(copyHoveredCodeBlock)
        button.isHidden = true
        return button
    }()

    override func draw(_ dirtyRect: NSRect) {
        drawInlineCodeBackgrounds(in: dirtyRect)
        drawCodeBlockFrames(in: dirtyRect)
        super.draw(dirtyRect)
        updateCopyButtonFrame()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let codeBlockTrackingArea {
            removeTrackingArea(codeBlockTrackingArea)
        }
        if copyCodeButton.superview == nil {
            addSubview(copyCodeButton)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        codeBlockTrackingArea = trackingArea
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        let hoveredRange = codeBlockRangesAndFrames().first { $0.frame.contains(point) }?.range
        guard hoveredRange != hoveredCodeBlockRange else { return }
        hoveredCodeBlockRange = hoveredRange
        copyCodeButton.isHidden = hoveredRange == nil
        updateCopyButtonFrame()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoveredCodeBlockRange = nil
        copyCodeButton.isHidden = true
    }

    func resetCodeBlockHover() {
        hoveredCodeBlockRange = nil
        copyCodeButton.isHidden = true
    }

    @objc private func copyHoveredCodeBlock() {
        guard let hoveredCodeBlockRange,
              let textStorage,
              NSMaxRange(hoveredCodeBlockRange) <= textStorage.length else { return }
        let blockText = (textStorage.string as NSString).substring(with: hoveredCodeBlockRange)
        guard let firstLineBreak = blockText.firstIndex(of: "\n") else { return }
        let code = String(blockText[blockText.index(after: firstLineBreak)...])
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        showCopySuccessFeedback()
    }

    private func showCopySuccessFeedback() {
        copyFeedbackReset?.cancel()
        copyCodeButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        copyCodeButton.contentTintColor = .systemGreen

        let reset = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.copyCodeButton.image = NSImage(
                systemSymbolName: "doc.on.doc",
                accessibilityDescription: nil
            )
            self.copyCodeButton.contentTintColor = .secondaryLabelColor
        }
        copyFeedbackReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: reset)
    }

    private func updateCopyButtonFrame() {
        guard let hoveredCodeBlockRange,
              let blockFrame = codeBlockFrame(for: hoveredCodeBlockRange) else { return }
        copyCodeButton.frame = NSRect(
            x: blockFrame.maxX - 32,
            y: blockFrame.minY + 5,
            width: 24,
            height: 24
        )
    }

    /// 按实际字形绘制行内代码背景，使文字垂直居中并保留紧凑的左右内边距。
    private func drawInlineCodeBackgrounds(in dirtyRect: NSRect) {
        guard let textStorage,
              let layoutManager,
              let textContainer,
              textStorage.length > 0 else { return }

        let origin = textContainerOrigin
        let fullRange = NSRange(location: 0, length: textStorage.length)
        textStorage.enumerateAttribute(.markdownInlineCodeBackground, in: fullRange) { value, characterRange, _ in
            guard let backgroundColor = value as? NSColor, characterRange.length > 0 else { return }
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: characterRange,
                actualCharacterRange: nil
            )
            guard glyphRange.length > 0 else { return }

            let font = (textStorage.attribute(.font, at: characterRange.location, effectiveRange: nil) as? NSFont)
                ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            let backgroundHeight = ceil(font.ascender - font.descender + 4)

            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { lineRect, _, _, lineGlyphRange, _ in
                let fragmentGlyphRange = NSIntersectionRange(glyphRange, lineGlyphRange)
                guard fragmentGlyphRange.length > 0 else { return }
                let glyphRect = layoutManager.boundingRect(
                    forGlyphRange: fragmentGlyphRange,
                    in: textContainer
                )
                let backgroundRect = NSRect(
                    x: origin.x + glyphRect.minX - 3,
                    y: origin.y + lineRect.midY - backgroundHeight / 2,
                    width: glyphRect.width + 6,
                    height: backgroundHeight
                )
                guard backgroundRect.intersects(dirtyRect) else { return }

                backgroundColor.setFill()
                NSBezierPath(
                    roundedRect: backgroundRect,
                    xRadius: 4,
                    yRadius: 4
                ).fill()
            }
        }
    }

    /// NSTextView 原生绘制圆角描边，绕过 HTML 导入器不支持 border-radius 的限制。
    private func drawCodeBlockFrames(in dirtyRect: NSRect) {
        for (_, frame) in codeBlockRangesAndFrames() {
            guard frame.intersects(dirtyRect) else { continue }

            NSGraphicsContext.saveGraphicsState()
            NSColor.separatorColor.setStroke()
            let path = NSBezierPath(roundedRect: frame, xRadius: 9, yRadius: 9)
            path.lineWidth = 1
            path.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func codeBlockRangesAndFrames() -> [(range: NSRange, frame: NSRect)] {
        guard let textStorage, textStorage.length > 0 else { return [] }
        var result: [(range: NSRange, frame: NSRect)] = []
        let fullRange = NSRange(location: 0, length: textStorage.length)
        textStorage.enumerateAttribute(.markdownCodeBlockLanguage, in: fullRange) { value, range, _ in
            guard value is String, let frame = self.codeBlockFrame(for: range) else { return }
            result.append((range, frame))
        }
        return result
    }

    private func codeBlockFrame(for characterRange: NSRange) -> NSRect? {
        guard let layoutManager, characterRange.length > 0 else { return nil }
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: characterRange,
            actualCharacterRange: nil
        )
        guard glyphRange.length > 0 else { return nil }

        var minimumY = CGFloat.greatestFiniteMagnitude
        var maximumY = -CGFloat.greatestFiniteMagnitude
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { rect, _, _, _, _ in
            minimumY = min(minimumY, rect.minY)
            maximumY = max(maximumY, rect.maxY)
        }
        guard minimumY.isFinite, maximumY.isFinite else { return nil }

        let origin = textContainerOrigin
        return NSRect(
            x: origin.x + 0.5,
            y: origin.y + minimumY - 6.5,
            width: max(0, bounds.width - origin.x * 2 - 1),
            height: maximumY - minimumY + 14
        )
    }
}

struct MarkdownTextView: NSViewRepresentable {
    let attributedText: NSAttributedString
    @Binding var calculatedHeight: CGFloat
    private let documentPadding: CGFloat = 24

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear

        let contentSize = scrollView.contentSize

        let textView = MarkdownNSTextView(frame: NSRect(x: 0, y: 0, width: contentSize.width, height: contentSize.height))
        textView.minSize = NSSize(width: 0.0, height: contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = .width
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = true
        // 留白属于可滚动文档，让滚动条贴近窗口边缘，首尾留白随内容一起滚动。
        textView.textContainerInset = NSSize(width: documentPadding, height: documentPadding)

        textView.textContainer?.containerSize = NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        if let textView = nsView.documentView as? MarkdownNSTextView {
            // 将 HTML 解析固化的纯黑/纯白前景色转换为语义化的 labelColor，使文本颜色随系统明暗外观自动切换
            // 即使 AppState 尚未完成重新渲染，也能保证暗色模式下文本可读
            let mutable = NSMutableAttributedString(attributedString: attributedText)
            let fullRange = NSRange(location: 0, length: mutable.length)
            mutable.enumerateAttribute(.foregroundColor, in: fullRange, options: []) { value, range, _ in
                guard let color = value as? NSColor,
                      let rgb = color.usingColorSpace(.deviceRGB) else { return }
                let isBlack = rgb.redComponent < 0.02 && rgb.greenComponent < 0.02 && rgb.blueComponent < 0.02 && rgb.alphaComponent > 0.95
                let isWhite = rgb.redComponent > 0.98 && rgb.greenComponent > 0.98 && rgb.blueComponent > 0.98 && rgb.alphaComponent > 0.95
                if isBlack || isWhite {
                    mutable.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
                }
            }
            textView.layoutManager?.replaceTextStorage(NSTextStorage(attributedString: mutable))
            textView.resetCodeBlockHover()
            context.coordinator.updateHeight(nsView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject {
        var parent: MarkdownTextView

        init(_ parent: MarkdownTextView) {
            self.parent = parent
        }

        func updateHeight(_ scrollView: NSScrollView) {
            guard let textView = scrollView.documentView as? NSTextView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }

            layoutManager.ensureLayout(for: textContainer)
            let usedRect = layoutManager.usedRect(for: textContainer)
            let neededHeight = usedRect.height + textView.textContainerInset.height * 2

            DispatchQueue.main.async {
                if self.parent.calculatedHeight != neededHeight {
                    self.parent.calculatedHeight = neededHeight
                }
            }
        }
    }
}
