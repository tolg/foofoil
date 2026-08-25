//  AppState+Markdown.swift
//  foofoil
//
//  Created by tolg on 2026/7/6.
//


import Foundation
import Combine
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import ImageIO
import SwiftUI

extension NSAttributedString.Key {
    /// 由 MarkdownTextView 绘制无底色圆角代码框，并在框内显示语言标签。
    static let markdownCodeBlockLanguage = NSAttributedString.Key("foofoil.markdownCodeBlockLanguage")
    /// 精确绘制行内代码背景，避免 AppKit 把背景扩张到整行或列表项目符号。
    static let markdownInlineCodeBackground = NSAttributedString.Key("foofoil.markdownInlineCodeBackground")
}

private enum MarkdownRenderMarker {
    nonisolated static let inlineCodeStart = "\u{F0010}"
    nonisolated static let inlineCodeEnd = "\u{F0011}"
    nonisolated static let codeBlockStart = "\u{F0012}"
    nonisolated static let codeBlockLanguageEnd = "\u{F0013}"
    nonisolated static let codeBlockEnd = "\u{F0014}"
    nonisolated static let paragraphStart = "\u{F0015}"
    nonisolated static let paragraphEnd = "\u{F0016}"
    nonisolated static let quoteStart = "\u{F0017}"
    nonisolated static let quoteEnd = "\u{F0018}"
}


extension AppState {

        // 根据当前系统外观判断是否为暗色模式，需在主线程调用
        static func isDarkMode() -> Bool {
            guard Thread.isMainThread else { return false }
            let appearance = NSApp.effectiveAppearance
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return true
            }
            // 兼容自定义外观名称
            return appearance.name.rawValue.lowercased().contains("dark")
        }

        /// 供视图层在系统明暗外观切换时主动触发重新渲染
        func refreshMarkdownRendering() {
            updateRenderedMarkdown()
        }

        func updateRenderedMarkdown() {
            // 性能防御：如果当前不是预览模式或者不是 Markdown 文档，直接跳过 markdown 解析，保证打字零开销！
            guard isMarkdownPreview && isMarkdownDocument else { return }

            renderTask?.cancel()

            let textToRender = self.text
            let fontSize = self.textFontSize
            // 在主线程捕获当前外观，避免后台任务无法正确获取有效外观
            let isDark = Self.isDarkMode()

            renderTask = Task.detached(priority: .userInitiated) {
                if Task.isCancelled { return }

                let htmlBody = Self.cmarkToHTML(textToRender)
                if Task.isCancelled { return }

                // 根据当前明暗外观显式生成对应配色的 CSS，避免依赖 @media 查询导致 NSAttributedString 在后台解析时颜色固化
                let textColor = isDark ? "#F0F3F6" : "#24292F"
                let secondaryTextColor = isDark ? "#AAB4C0" : "#57606A"
                let accentColor = isDark ? "#58A6FF" : "#0969DA"
                let borderColor = isDark ? "#3D444D" : "#D0D7DE"
                let inlineCodeColor = isDark ? "#E6EDF3" : "#1F2328"
                let inlineCodeBackground = isDark ? "#2A3038" : "#EFF1F3"
                let quoteBackground = isDark ? "#1C232C" : "#F6F8FA"
                let tableHeaderBackground = isDark ? "#212830" : "#F0F3F6"
                let tableStripeBackground = isDark ? "#1B2129" : "#FAFBFC"
                // AppKit 会把 blockquote 的 CSS 背景错误转换为逐行文字底色；单列表格能稳定生成有边界的原生富文本块。
                var styledHTMLBody = Self.markCodeRanges(in: htmlBody)
                styledHTMLBody = styledHTMLBody
                    .replacingOccurrences(
                        of: "<blockquote>",
                        with: "<table class=\"markdown-quote\"><tr><td>\(MarkdownRenderMarker.quoteStart)"
                    )
                    .replacingOccurrences(
                        of: "</blockquote>",
                        with: "\(MarkdownRenderMarker.quoteEnd)</td></tr></table>"
                    )
                    .replacingOccurrences(of: "<p>", with: "<p>\(MarkdownRenderMarker.paragraphStart)")
                    .replacingOccurrences(of: "</p>", with: "\(MarkdownRenderMarker.paragraphEnd)</p>")

                // 构建包含 CSS 的完整 HTML，支持自适应系统明暗主题与字号大小缩放
                let htmlContent = """
                <html>
                <head>
                <style>
                html, body {
                    font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
                    font-size: \(fontSize)px;
                    line-height: 1.45;
                    color: \(textColor);
                    background-color: transparent;
                }
                body {
                    margin: 0;
                    padding: 0;
                    overflow-wrap: break-word;
                }
                a {
                    color: \(accentColor);
                    text-decoration: none;
                }
                p {
                    margin-top: 0;
                    margin-bottom: 0.8em;
                }
                h1, h2, h3, h4, h5, h6 {
                    color: \(textColor);
                    font-weight: 650;
                    margin-top: 1.35em;
                    margin-bottom: 0.55em;
                    line-height: 1.22;
                }
                h1 { font-size: 1.72em; border-bottom: 1px solid \(borderColor); padding-bottom: 0.32em; }
                h2 { font-size: 1.42em; }
                h3 { font-size: 1.2em; }
                h4 { font-size: 1.08em; }
                h5, h6 { font-size: 1em; color: \(secondaryTextColor); }
                code {
                    padding: 0;
                    margin: 0;
                    font-family: "SFMono-Regular", Menlo, Monaco, Consolas, monospace;
                    font-size: 0.88em;
                    color: \(inlineCodeColor);
                    background-color: transparent;
                    white-space: pre-wrap;
                    overflow-wrap: anywhere;
                    word-break: break-word;
                }
                pre {
                    box-sizing: border-box;
                    max-width: 100%;
                    margin: 0;
                    padding: 0 14px;
                    overflow: hidden;
                    white-space: pre-wrap;
                    overflow-wrap: anywhere;
                    word-break: break-word;
                    font-family: "SFMono-Regular", Menlo, Monaco, Consolas, monospace;
                    font-size: 0.86em;
                    line-height: 1.18;
                    color: \(inlineCodeColor);
                    background-color: transparent;
                    border: 0;
                }
                pre code {
                    background-color: transparent;
                    color: inherit;
                    padding: 0;
                    margin: 0;
                    border-radius: 0;
                    white-space: inherit;
                    overflow-wrap: inherit;
                    word-break: inherit;
                }
                ul, ol {
                    padding-left: 1.65em;
                    margin: 0 0 0.9em 0;
                    line-height: 1.5;
                }
                li {
                    margin: 0.18em 0;
                }
                li::marker {
                    color: \(secondaryTextColor);
                }
                hr {
                    height: 0;
                    margin: 1.5em 0;
                    background-color: transparent;
                    border: 0;
                    border-top: 1px solid \(borderColor);
                }
                img {
                    max-width: 100%;
                    height: auto;
                }
                table {
                    box-sizing: border-box;
                    max-width: 100%;
                    width: 100%;
                    border-collapse: collapse;
                    margin: 1em 0 1.15em 0;
                    font-size: 0.9em;
                    line-height: 1.4;
                }
                th, td {
                    border: 1px solid \(borderColor);
                    padding: 8px 10px;
                    text-align: left;
                    vertical-align: top;
                    word-break: break-word;
                }
                th {
                    color: \(textColor);
                    background-color: \(tableHeaderBackground);
                    font-weight: 650;
                }
                tr:nth-child(even) td {
                    background-color: \(tableStripeBackground);
                }
                table.markdown-quote {
                    width: 100%;
                    margin: 0.85em 0 1em 0;
                    border-collapse: collapse;
                    font-size: 1em;
                    line-height: 1.55;
                }
                table.markdown-quote td {
                    padding: 10px 14px;
                    color: \(secondaryTextColor);
                    background-color: \(quoteBackground);
                    border: 0;
                    border-left: 3px solid \(accentColor);
                }
                table.markdown-quote p:last-child {
                    margin-bottom: 0;
                }
                </style>
                </head>
                <body>
                \(styledHTMLBody)
                </body>
                </html>
                """

                await MainActor.run {
                    if let data = htmlContent.data(using: .utf8),
                       let attr = try? NSAttributedString(
                           data: data,
                           options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
                           documentAttributes: nil
                       ) {
                        // HTML 导入器不会稳定保留普通段落行高；仅修正常规段落，避免覆盖引用、代码块、列表和表格的独立布局。
                        let mutableAttr = NSMutableAttributedString(attributedString: attr)

                        let fullRange = NSRange(location: 0, length: mutableAttr.length)
                        mutableAttr.enumerateAttribute(.paragraphStyle, in: fullRange, options: []) { value, range, _ in
                            let paragraphStyle = (value as? NSParagraphStyle) ?? NSParagraphStyle.default
                            let mutableParagraphStyle = paragraphStyle.mutableCopy() as! NSMutableParagraphStyle

                            if !mutableParagraphStyle.textLists.isEmpty {
                                mutableParagraphStyle.lineHeightMultiple = 1.5
                                mutableParagraphStyle.paragraphSpacing = max(
                                    mutableParagraphStyle.paragraphSpacing,
                                    fontSize * 0.22
                                )
                            } else if mutableParagraphStyle.textBlocks.isEmpty {
                                mutableParagraphStyle.lineHeightMultiple = 1.42
                                mutableParagraphStyle.paragraphSpacing = max(mutableParagraphStyle.paragraphSpacing, fontSize * 0.7)
                            }

                            mutableAttr.addAttribute(.paragraphStyle, value: mutableParagraphStyle, range: range)
                        }

                        Self.applyParagraphRangeStyles(to: mutableAttr, fontSize: fontSize)

                        // 最后处理代码样式，使原生缩进和紧凑行高不再被普通段落规则覆盖。
                        Self.applyCodeRangeStyles(
                            to: mutableAttr,
                            inlineBackground: NSColor(hex: inlineCodeBackground) ?? .quaternaryLabelColor
                        )
                        self.renderedMarkdown = mutableAttr
                    } else {
                        self.renderedMarkdown = NSAttributedString(string: textToRender)
                    }
                }
            }
        }

        /// 为正文和引用建立精确范围，避免两端对齐误用于标题、表格与代码块。
        private static func applyParagraphRangeStyles(
            to attributedString: NSMutableAttributedString,
            fontSize: CGFloat
        ) {
            applyMarkedParagraphStyle(
                to: attributedString,
                startMarker: MarkdownRenderMarker.paragraphStart,
                endMarker: MarkdownRenderMarker.paragraphEnd
            ) { style in
                style.alignment = .justified
            }

            applyMarkedParagraphStyle(
                to: attributedString,
                startMarker: MarkdownRenderMarker.quoteStart,
                endMarker: MarkdownRenderMarker.quoteEnd
            ) { style in
                style.alignment = .justified
                style.minimumLineHeight = 0
                style.maximumLineHeight = 0
                style.lineSpacing = 0
                style.lineHeightMultiple = 1.55
                style.paragraphSpacing = max(style.paragraphSpacing, fontSize * 0.65)
            }
        }

        /// 删除隐藏标记，并在其包围的原生段落上应用样式。
        private static func applyMarkedParagraphStyle(
            to attributedString: NSMutableAttributedString,
            startMarker: String,
            endMarker: String,
            update: (NSMutableParagraphStyle) -> Void
        ) {
            while let start = attributedString.string.range(of: startMarker),
                  let end = attributedString.string.range(
                      of: endMarker,
                      range: start.upperBound..<attributedString.string.endIndex
                  ) {
                let startRange = NSRange(start, in: attributedString.string)
                let endRange = NSRange(end, in: attributedString.string)
                attributedString.deleteCharacters(in: endRange)
                attributedString.deleteCharacters(in: startRange)

                let contentLength = endRange.location - NSMaxRange(startRange)
                guard contentLength > 0 else { continue }
                let contentRange = NSRange(location: startRange.location, length: contentLength)
                var styles: [(NSRange, NSMutableParagraphStyle)] = []
                attributedString.enumerateAttribute(.paragraphStyle, in: contentRange) { value, range, _ in
                    let style = ((value as? NSParagraphStyle) ?? .default).mutableCopy() as! NSMutableParagraphStyle
                    update(style)
                    styles.append((range, style))
                }
                for (range, style) in styles {
                    attributedString.addAttribute(.paragraphStyle, value: style, range: range)
                }
            }
        }

        /// 隔离 fenced code 与 inline code，避免 AppKit 的 HTML 导入器扩大背景和边框范围。
        nonisolated private static func markCodeRanges(in html: String) -> String {
            let pattern = #"<pre><code(?: class="language-([^"]+)")?>([\s\S]*?)</code></pre>"#
            guard let regularExpression = try? NSRegularExpression(pattern: pattern) else { return html }

            var result = html
            let original = html as NSString
            let matches = regularExpression.matches(
                in: html,
                range: NSRange(location: 0, length: original.length)
            )

            for match in matches.reversed() {
                let language: String
                if match.range(at: 1).location == NSNotFound {
                    language = "CODE"
                } else {
                    language = original.substring(with: match.range(at: 1)).uppercased()
                }
                let code = original.substring(with: match.range(at: 2))
                let replacement = "<pre>\(MarkdownRenderMarker.codeBlockStart)\(language)\(MarkdownRenderMarker.codeBlockLanguageEnd)<span class=\"markdown-code-content\">\(code)</span>\(MarkdownRenderMarker.codeBlockEnd)</pre>"
                guard let range = Range(match.range, in: result) else { continue }
                result.replaceSubrange(range, with: replacement)
            }

            return result
                .replacingOccurrences(of: "<code>", with: "\(MarkdownRenderMarker.inlineCodeStart)<code>")
                .replacingOccurrences(of: "</code>", with: "</code>\(MarkdownRenderMarker.inlineCodeEnd)")
        }

        /// 移除渲染标记，并把精确范围交给原生富文本与 MarkdownTextView 处理。
        private static func applyCodeRangeStyles(
            to attributedString: NSMutableAttributedString,
            inlineBackground: NSColor
        ) {
            while let start = attributedString.string.range(of: MarkdownRenderMarker.codeBlockStart),
                  let languageEnd = attributedString.string.range(
                      of: MarkdownRenderMarker.codeBlockLanguageEnd,
                      range: start.upperBound..<attributedString.string.endIndex
                  ),
                  let end = attributedString.string.range(
                      of: MarkdownRenderMarker.codeBlockEnd,
                      range: languageEnd.upperBound..<attributedString.string.endIndex
                  ) {
                let language = String(attributedString.string[start.upperBound..<languageEnd.lowerBound])
                let startRange = NSRange(start, in: attributedString.string)
                let languageEndRange = NSRange(languageEnd, in: attributedString.string)
                let endRange = NSRange(end, in: attributedString.string)
                let prefixRange = NSRange(
                    location: startRange.location,
                    length: NSMaxRange(languageEndRange) - startRange.location
                )

                let originalCodeLength = endRange.location - NSMaxRange(languageEndRange)
                let label = language.uppercased()
                let blockSpacer = "\u{200B}\n"
                let blockSpacerLength = (blockSpacer as NSString).length
                let labelLine = "\(label)\n"
                let labelLineLength = (labelLine as NSString).length

                attributedString.deleteCharacters(in: endRange)
                // 独立间隔行位于边框范围外，避免 paragraphSpacing 被 AppKit 算进代码块内部。
                attributedString.replaceCharacters(in: prefixRange, with: blockSpacer + labelLine)

                let blockLocation = prefixRange.location + blockSpacerLength
                let codeLocation = blockLocation + labelLineLength
                var codeLength = originalCodeLength
                // cmark 会在 fenced code 末尾保留换行；不把它纳入边框范围，避免底部出现一整行空白。
                let renderedString = attributedString.string as NSString
                while codeLength > 0 {
                    let finalCharacter = renderedString.character(at: codeLocation + codeLength - 1)
                    guard finalCharacter == 0x0A || finalCharacter == 0x0D else { break }
                    codeLength -= 1
                }
                let blockRange = NSRange(
                    location: blockLocation,
                    length: labelLineLength + codeLength
                )
                if blockRange.length > 0 {
                    if let value = attributedString.attribute(
                        .paragraphStyle,
                        at: prefixRange.location,
                        effectiveRange: nil
                    ), let spacerStyle = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle {
                        spacerStyle.minimumLineHeight = 10
                        spacerStyle.maximumLineHeight = 10
                        spacerStyle.lineHeightMultiple = 1
                        spacerStyle.lineSpacing = 0
                        spacerStyle.paragraphSpacing = 0
                        spacerStyle.paragraphSpacingBefore = 0
                        let spacerParagraphRange = (attributedString.string as NSString).paragraphRange(
                            for: NSRange(location: prefixRange.location, length: 0)
                        )
                        attributedString.addAttribute(
                            .paragraphStyle,
                            value: spacerStyle,
                            range: spacerParagraphRange
                        )
                    }
                    attributedString.addAttribute(
                        .markdownCodeBlockLanguage,
                        value: label,
                        range: blockRange
                    )
                    attributedString.addAttributes(
                        [
                            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold),
                            .foregroundColor: NSColor.secondaryLabelColor
                        ],
                        range: NSRange(location: blockLocation, length: (label as NSString).length)
                    )

                    // HTML 导入器会忽略 pre 的 padding；用原生缩进提供稳定的左右留白和紧凑行高。
                    var paragraphStyles: [(NSRange, NSMutableParagraphStyle)] = []
                    attributedString.enumerateAttribute(.paragraphStyle, in: blockRange) { value, range, _ in
                        let style = ((value as? NSParagraphStyle) ?? .default).mutableCopy() as! NSMutableParagraphStyle
                        style.minimumLineHeight = 0
                        style.maximumLineHeight = 0
                        style.lineSpacing = 0
                        style.lineHeightMultiple = 1.08
                        style.paragraphSpacing = 0
                        style.paragraphSpacingBefore = 0
                        style.firstLineHeadIndent = 14
                        style.headIndent = 14
                        style.tailIndent = -14
                        paragraphStyles.append((range, style))
                    }
                    for (range, style) in paragraphStyles {
                        attributedString.addAttribute(.paragraphStyle, value: style, range: range)
                    }

                    let currentString = attributedString.string as NSString
                    let firstParagraphRange = currentString.paragraphRange(
                        for: NSRange(location: blockRange.location, length: 0)
                    )
                    if let value = attributedString.attribute(.paragraphStyle, at: blockRange.location, effectiveRange: nil),
                       let firstStyle = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle {
                        firstStyle.paragraphSpacingBefore = 0
                        firstStyle.paragraphSpacing = 7
                        attributedString.addAttribute(.paragraphStyle, value: firstStyle, range: firstParagraphRange)
                    }

                    let lastLocation = NSMaxRange(blockRange) - 1
                    let lastParagraphRange = currentString.paragraphRange(
                        for: NSRange(location: lastLocation, length: 0)
                    )
                    if let value = attributedString.attribute(.paragraphStyle, at: lastLocation, effectiveRange: nil),
                       let lastStyle = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle {
                        lastStyle.paragraphSpacing = 0
                        attributedString.addAttribute(.paragraphStyle, value: lastStyle, range: lastParagraphRange)
                    }
                }
            }

            while let start = attributedString.string.range(of: MarkdownRenderMarker.inlineCodeStart),
                  let end = attributedString.string.range(
                      of: MarkdownRenderMarker.inlineCodeEnd,
                      range: start.upperBound..<attributedString.string.endIndex
                  ) {
                let startRange = NSRange(start, in: attributedString.string)
                let endRange = NSRange(end, in: attributedString.string)
                attributedString.deleteCharacters(in: endRange)
                attributedString.deleteCharacters(in: startRange)

                let codeLength = endRange.location - NSMaxRange(startRange)
                if codeLength > 0 {
                    let codeRange = NSRange(location: startRange.location, length: codeLength)
                    attributedString.addAttribute(
                        .markdownInlineCodeBackground,
                        value: inlineBackground,
                        range: codeRange
                    )
                    // kern 为自绘背景预留真实的左右空间，不向富文本中插入会影响复制的空格字符。
                    if codeRange.location > 0 {
                        attributedString.addAttribute(
                            .kern,
                            value: 3.0,
                            range: NSRange(location: codeRange.location - 1, length: 1)
                        )
                    }
                    attributedString.addAttribute(
                        .kern,
                        value: 3.0,
                        range: NSRange(location: NSMaxRange(codeRange) - 1, length: 1)
                    )
                }
            }
        }

        // MARK: - Markdown 表格支持（GFM）

        enum MarkdownTableAlignment {
            case none
            case left
            case center
            case right
        }

        enum MarkdownSegment {
            case text(String)
            case table(String)
        }

        public static func cmarkToHTML(_ text: String) -> String {
            // 若不含表格特征，直接走 cmark 原路径以保持原有性能与行为
            let segments = parseMarkdownSegmentsWithTables(text)
            // 仅有一段普通文本时，保持单次 cmark 调用
            if segments.count == 1, case .text(let md) = segments[0] {
                return cmarkHTML(md)
            }
            var html = ""
            for segment in segments {
                switch segment {
                case .text(let md):
                    html += cmarkHTML(md)
                case .table(let tableHTML):
                    html += tableHTML
                }
            }
            return html
        }

        /// 纯 cmark 调用（不含表格预处理），用于文本段与单元格 inline 渲染
        static func cmarkHTML(_ markdown: String) -> String {
            // 空段直接返回，避免产生空 <p>
            if markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "" }
            guard let cString = cmark_markdown_to_html(markdown, markdown.utf8.count, 0) else {
                return ""
            }
            let result = String(cString: cString)
            free(cString)
            return result
        }

        /// 将单元格内的 inline Markdown 转为 HTML 片段（去除外层 <p> 包裹）
        static func inlineMarkdownToHTML(_ text: String) -> String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return "" }
            let html = cmarkHTML(trimmed).trimmingCharacters(in: .whitespacesAndNewlines)
            // cmark 会将行内内容包裹为 <p>...</p>，此处剥离以嵌入 <td>/<th>
            if html.hasPrefix("<p>") && html.hasSuffix("</p>") {
                var inner = String(html.dropFirst(3).dropLast(4))
                // 处理 cmark 可能输出的换行
                inner = inner.trimmingCharacters(in: .whitespacesAndNewlines)
                return inner
            }
            // 若为多段或特殊情况，去除首尾的 <p> 标签对
            if html.hasPrefix("<p>") {
                // 仅移除首个 <p> 与末尾的 </p>，保留中间内容
                if let rangeStart = html.range(of: "<p>"), let rangeEnd = html.range(of: "</p>", options: .backwards) {
                    let inner = String(html[rangeStart.upperBound..<rangeEnd.lowerBound])
                    return inner.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            return html
        }

        static func escapeHTML(_ string: String) -> String {
            var result = string
            result = result.replacingOccurrences(of: "&", with: "&amp;")
            result = result.replacingOccurrences(of: "<", with: "&lt;")
            result = result.replacingOccurrences(of: ">", with: "&gt;")
            result = result.replacingOccurrences(of: "\"", with: "&quot;")
            return result
        }

        // 解析 Markdown 文本，将 GFM 表格块抽出为独立段，其余文本保持为普通段
        static func parseMarkdownSegmentsWithTables(_ text: String) -> [MarkdownSegment] {
            // 快速路径：不含表格关键字符时无需扫描
            guard text.contains("|") else { return [.text(text)] }

            let lines = text.components(separatedBy: "\n")
            var segments: [MarkdownSegment] = []
            var textBuffer: [String] = []
            var inFencedCodeBlock = false
            var fenceChar: Character = "`"
            var fenceLength = 0

            func flushTextBuffer() {
                if !textBuffer.isEmpty {
                    let md = textBuffer.joined(separator: "\n")
                    segments.append(.text(md))
                    textBuffer.removeAll()
                }
            }

            var i = 0
            while i < lines.count {
                let line = lines[i]
                let trimmedForFence = line.trimmingCharacters(in: .whitespaces)

                // 检测围栏代码块边界，避免将代码块内的 | 误判为表格
                if trimmedForFence.hasPrefix("```") || trimmedForFence.hasPrefix("~~~") {
                    let fenceMarker: Character = trimmedForFence.first!
                    let count = trimmedForFence.prefix(while: { $0 == fenceMarker }).count
                    if !inFencedCodeBlock {
                        inFencedCodeBlock = true
                        fenceChar = fenceMarker
                        fenceLength = count
                    } else if fenceMarker == fenceChar && count >= fenceLength {
                        inFencedCodeBlock = false
                    }
                    textBuffer.append(line)
                    i += 1
                    continue
                }

                if inFencedCodeBlock {
                    textBuffer.append(line)
                    i += 1
                    continue
                }

                // 尝试识别表格：当前行 + 下一行为分隔行
                if i + 1 < lines.count, let alignments = parseTableDelimiterLine(lines[i + 1]) {
                    // 分隔行有效，检查表头行是否像表格行（包含 |）
                    if isPotentialTableRow(line) {
                        let headerCells = splitTableRow(line)
                        // 列数以分隔行为准，允许表头列数不一致但需至少 1 列
                        let columnCount = alignments.count
                        if columnCount > 0 {
                            // 收集后续正文行
                            var bodyRows: [[String]] = []
                            var j = i + 2
                            while j < lines.count {
                                let bodyLine = lines[j]
                                if bodyLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
                                // 遇到围栏代码块开始则终止表格
                                let trimmedBody = bodyLine.trimmingCharacters(in: .whitespaces)
                                if trimmedBody.hasPrefix("```") || trimmedBody.hasPrefix("~~~") { break }
                                // 非表格行则终止
                                if !isPotentialTableRow(bodyLine) { break }
                                // 若再次出现分隔行样式的行，视为新表格或终止
                                if parseTableDelimiterLine(bodyLine) != nil { break }
                                let cells = splitTableRow(bodyLine)
                                bodyRows.append(cells)
                                j += 1
                            }
                            // 至少要有表头+分隔行即可成表；允许无正文行
                            flushTextBuffer()
                            let tableHTML = buildTableHTML(headerCells: headerCells, alignments: alignments, bodyRows: bodyRows, columnCount: columnCount)
                            segments.append(.table(tableHTML))
                            i = j
                            continue
                        }
                    }
                }

                textBuffer.append(line)
                i += 1
            }

            flushTextBuffer()
            if segments.isEmpty { return [.text(text)] }
            return segments
        }

        static func isPotentialTableRow(_ line: String) -> Bool {
            // 包含 | 且非空即视为潜在表格行
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
            return line.contains("|")
        }

        static func splitTableRow(_ line: String) -> [String] {
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            // 移除首尾的管道符（GFM 允许省略）
            if trimmed.hasPrefix("|") { trimmed.removeFirst() }
            if trimmed.hasSuffix("|") { trimmed.removeLast() }
            // 处理转义的 \|，用占位符临时替换
            let placeholder = "\u{FFFD}PIPE\u{FFFD}"
            let escaped = trimmed.replacingOccurrences(of: "\\|", with: placeholder)
            let rawParts = escaped.components(separatedBy: "|")
            return rawParts.map { part in
                part.replacingOccurrences(of: placeholder, with: "|").trimmingCharacters(in: .whitespaces)
            }
        }

        static func parseTableDelimiterLine(_ line: String) -> [MarkdownTableAlignment]? {
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return nil }
            if trimmed.hasPrefix("|") { trimmed.removeFirst() }
            if trimmed.hasSuffix("|") { trimmed.removeLast() }
            trimmed = trimmed.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return nil }
            // 分隔行仅允许包含 | : - 及空格
            let allowed = CharacterSet(charactersIn: "|-: ").inverted
            if trimmed.rangeOfCharacter(from: allowed) != nil { return nil }

            let parts = trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.isEmpty { return nil }
            var alignments: [MarkdownTableAlignment] = []
            for part in parts {
                if part.isEmpty { return nil }
                let hasLeftColon = part.hasPrefix(":")
                let hasRightColon = part.hasSuffix(":")
                var core = part
                if hasLeftColon { core.removeFirst() }
                if hasRightColon { core.removeLast() }
                if core.isEmpty { return nil }
                // 核心必须全为 -
                if core.contains(where: { $0 != "-" }) { return nil }
                // 至少一个 -
                if alignments.count == 0 && parts.count == 1 && core.count < 1 { return nil }
                if hasLeftColon && hasRightColon {
                    alignments.append(.center)
                } else if hasLeftColon {
                    alignments.append(.left)
                } else if hasRightColon {
                    alignments.append(.right)
                } else {
                    alignments.append(.none)
                }
            }
            return alignments
        }

        static func buildTableHTML(headerCells: [String], alignments: [MarkdownTableAlignment], bodyRows: [[String]], columnCount: Int) -> String {
            func alignAttribute(_ align: MarkdownTableAlignment) -> String {
                switch align {
                case .left: return " align=\"left\""
                case .center: return " align=\"center\""
                case .right: return " align=\"right\""
                case .none: return ""
                }
            }

            func normalizedCells(_ cells: [String], count: Int) -> [String] {
                if cells.count == count { return cells }
                if cells.count > count { return Array(cells.prefix(count)) }
                // 列数不足时补空
                return cells + Array(repeating: "", count: count - cells.count)
            }

            let normalizedHeader = normalizedCells(headerCells, count: columnCount)
            var html = "<table>\n<thead>\n<tr>"
            for (idx, cell) in normalizedHeader.enumerated() {
                let align = idx < alignments.count ? alignments[idx] : .none
                let content = cell.isEmpty ? "" : inlineMarkdownToHTML(cell)
                // 空单元格保留 &nbsp; 以维持表格结构可见性，但此处保持空亦可
                html += "<th\(alignAttribute(align))>\(content)</th>"
            }
            html += "</tr>\n</thead>\n"
            if !bodyRows.isEmpty {
                html += "<tbody>\n"
                for row in bodyRows {
                    let normalized = normalizedCells(row, count: columnCount)
                    html += "<tr>"
                    for (idx, cell) in normalized.enumerated() {
                        let align = idx < alignments.count ? alignments[idx] : .none
                        let content = cell.isEmpty ? "" : inlineMarkdownToHTML(cell)
                        html += "<td\(alignAttribute(align))>\(content)</td>"
                    }
                    html += "</tr>\n"
                }
                html += "</tbody>\n"
            }
            html += "</table>\n"
            return html
        }

}
