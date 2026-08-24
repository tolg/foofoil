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
                let textColor = isDark ? "#ffffff" : "#000000"
                let borderColor = isDark ? "rgba(255,255,255,0.15)" : "rgba(0,0,0,0.1)"
                let codeBg = isDark ? "rgba(255,255,255,0.15)" : "rgba(0,0,0,0.06)"
                let preBg = isDark ? "rgba(255,255,255,0.1)" : "rgba(0,0,0,0.04)"
                let blockquoteColor = isDark ? "rgba(255,255,255,0.6)" : "rgba(0,0,0,0.6)"
                let blockquoteBorder = isDark ? "rgba(255,255,255,0.25)" : "rgba(0,0,0,0.2)"
                let tableBorder = isDark ? "rgba(255,255,255,0.15)" : "rgba(0,0,0,0.12)"
                let thBg = isDark ? "rgba(255,255,255,0.08)" : "rgba(0,0,0,0.04)"
                let trEvenBg = isDark ? "rgba(255,255,255,0.04)" : "rgba(0,0,0,0.02)"

                // 构建包含 CSS 的完整 HTML，支持自适应系统明暗主题与字号大小缩放
                let htmlContent = """
                <html>
                <head>
                <style>
                body, p, li, blockquote {
                    font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
                    font-size: \(fontSize)px;
                    line-height: 1.8;
                    color: \(textColor);
                    background-color: transparent;
                }
                body {
                    margin: 0;
                    padding: 0;
                }
                p {
                    margin-top: 0;
                    margin-bottom: 14px;
                }
                h1, h2, h3, h4, h5, h6 {
                    font-weight: 600;
                    margin-top: 24px;
                    margin-bottom: 16px;
                    line-height: 1.25;
                }
                h1 { font-size: 1.6em; border-bottom: 1px solid \(borderColor); padding-bottom: 0.3em; }
                h2 { font-size: 1.4em; border-bottom: 1px solid \(borderColor); padding-bottom: 0.3em; }
                h3 { font-size: 1.25em; }
                h4 { font-size: 1.15em; }
                code {
                    padding: 0.2em 0.4em;
                    margin: 0;
                    font-size: 85%;
                    background-color: \(codeBg);
                    border-radius: 6px;
                    font-family: Menlo, Consolas, monospace;
                }
                pre {
                    padding: 16px;
                    overflow: auto;
                    font-size: 85%;
                    line-height: 1.45;
                    background-color: \(preBg);
                    border-radius: 6px;
                }
                pre code {
                    background-color: transparent;
                    padding: 0;
                    border-radius: 0;
                }
                blockquote {
                    padding: 0 1em;
                    color: \(blockquoteColor);
                    border-left: 0.25em solid \(blockquoteBorder);
                    margin: 0 0 16px 0;
                }
                ul, ol {
                    padding-left: 2em;
                    margin-top: 0;
                    margin-bottom: 16px;
                }
                table {
                    width: 100%;
                    border-collapse: collapse;
                    margin: 16px 0;
                    font-size: 0.9em;
                    line-height: 1.5;
                }
                th, td {
                    border: 1px solid \(tableBorder);
                    padding: 6px 10px;
                    text-align: left;
                    vertical-align: top;
                    word-break: break-word;
                }
                th {
                    background-color: \(thBg);
                    font-weight: 600;
                }
                tr:nth-child(even) td {
                    background-color: \(trEvenBg);
                }
                </style>
                </head>
                <body>
                \(htmlBody)
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
                        // 后处理：直接遍历并修改富文本段落样式 (NSParagraphStyle) 以强制行高和段落间距生效
                        let mutableAttr = NSMutableAttributedString(attributedString: attr)
                        let fullRange = NSRange(location: 0, length: mutableAttr.length)

                        mutableAttr.enumerateAttribute(.paragraphStyle, in: fullRange, options: []) { value, range, _ in
                            let paragraphStyle = (value as? NSParagraphStyle) ?? NSParagraphStyle.default
                            let mutableParagraphStyle = paragraphStyle.mutableCopy() as! NSMutableParagraphStyle

                            // 强制注入 1.45 倍行高
                            mutableParagraphStyle.lineHeightMultiple = 1.45
                            // 强制注入 12pt 段落底部留白
                            mutableParagraphStyle.paragraphSpacing = 12.0

                            mutableAttr.addAttribute(.paragraphStyle, value: mutableParagraphStyle, range: range)
                        }
                        self.renderedMarkdown = mutableAttr
                    } else {
                        self.renderedMarkdown = NSAttributedString(string: textToRender)
                    }
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
