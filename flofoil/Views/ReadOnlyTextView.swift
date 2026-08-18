//
//  ReadOnlyTextView.swift
//  flofoil
//
//  Created by tolg on 2026/7/13.
//

import SwiftUI
import AppKit

struct ReadOnlyTextView: View {
    let text: String
    let fontSize: Double

    var body: some View {
        ReadOnlyTextNSView(text: text, fontSize: fontSize)
    }
}

struct ReadOnlyTextNSView: NSViewRepresentable {
    let text: String
    let fontSize: Double

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
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isEditable = false // 只读
        textView.isSelectable = true // 可选择

        textView.textContainer?.containerSize = NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0

        // 字体样式（圆角设计）
        let systemFont = NSFont.systemFont(ofSize: CGFloat(fontSize))
        if let roundedDescriptor = systemFont.fontDescriptor.withDesign(.rounded) {
            textView.font = NSFont(descriptor: roundedDescriptor, size: CGFloat(fontSize))
        } else {
            textView.font = systemFont
        }
        textView.textColor = .labelColor

        textView.textContainerInset = .zero

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        if let textView = nsView.documentView as? NSTextView {
            if textView.string != text {
                textView.string = text
            }
            let systemFont = NSFont.systemFont(ofSize: CGFloat(fontSize))
            let updatedFont = systemFont.fontDescriptor.withDesign(.rounded).flatMap {
                NSFont(descriptor: $0, size: CGFloat(fontSize))
            } ?? systemFont
            if textView.font?.pointSize != CGFloat(fontSize) {
                textView.font = updatedFont
            }
        }
    }
}
