//
//  MarkdownTextView.swift
//  foofoil
//
//  Created by tolg on 2026/7/10.
//

import SwiftUI
import AppKit

struct MarkdownTextView: NSViewRepresentable {
    let attributedText: NSAttributedString
    @Binding var calculatedHeight: CGFloat

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear

        let contentSize = scrollView.contentSize

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: contentSize.width, height: contentSize.height))
        textView.minSize = NSSize(width: 0.0, height: contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = .width
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = true

        textView.textContainer?.containerSize = NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        if let textView = nsView.documentView as? NSTextView {
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
            let neededHeight = usedRect.height

            DispatchQueue.main.async {
                if self.parent.calculatedHeight != neededHeight {
                    self.parent.calculatedHeight = neededHeight
                }
            }
        }
    }
}
