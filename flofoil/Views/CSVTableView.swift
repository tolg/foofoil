//
//  CSVTableView.swift
//  flofoil
//
//  Created by tolg on 2026/7/11.
//

import SwiftUI

/// 轻量 CSV 解析器，支持双引号、转义双引号与引号内换行。
public enum CSVParser {
    public static func parse(_ content: String) -> [[String]] {
        let content = content.hasPrefix("\u{FEFF}") ? String(content.dropFirst()) : content
        guard !content.isEmpty else { return [] }

        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var isInsideQuotes = false
        var index = content.startIndex

        while index < content.endIndex {
            let character = content[index]

            if character == "\"" {
                let nextIndex = content.index(after: index)
                if isInsideQuotes, nextIndex < content.endIndex, content[nextIndex] == "\"" {
                    field.append("\"")
                    index = nextIndex
                } else {
                    isInsideQuotes.toggle()
                }
            } else if character == ",", !isInsideQuotes {
                row.append(field)
                field = ""
            } else if character.isNewline, !isInsideQuotes {
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            } else {
                field.append(character)
            }

            index = content.index(after: index)
        }

        if !row.isEmpty || !field.isEmpty || content.last == "," {
            row.append(field)
            rows.append(row)
        }

        return rows
    }
}

/// CSV 的基础只读表格视图：首行作为表头，支持横向和纵向滚动。
public struct CSVTableView: View {
    private let rows: [[String]]
    private let columnCount: Int
    private let cellWidth: CGFloat
    private let fontSize: CGFloat

    public init(content: String, fontSize: Double = AppState.defaultTextFontSize) {
        let parsedRows = CSVParser.parse(content)
        self.rows = parsedRows
        self.columnCount = parsedRows.map(\.count).max() ?? 0
        self.fontSize = CGFloat(fontSize)
        // 列宽与字号按比例缩放，保证放大后单元格内容仍有足够空间。
        self.cellWidth = max(90, 140 * CGFloat(fontSize / AppState.defaultTextFontSize))
    }

    public var body: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    HStack(spacing: 0) {
                        ForEach(0..<columnCount, id: \.self) { columnIndex in
                            CSVTableCell(
                                value: columnIndex < row.count ? row[columnIndex] : "",
                                isHeader: rowIndex == 0,
                                width: cellWidth,
                                fontSize: fontSize
                            )
                        }
                    }
                }
            }
            .padding(12)
        }
    }
}

private struct CSVTableCell: View {
    let value: String
    let isHeader: Bool
    let width: CGFloat
    let fontSize: CGFloat

    var body: some View {
        Text(value)
            .font(.system(size: fontSize, weight: isHeader ? .semibold : .regular))
            .foregroundStyle(.primary)
            .lineLimit(nil)
            .textSelection(.enabled)
            .frame(width: width, alignment: .leading)
            .frame(minHeight: max(30, fontSize + 16), alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isHeader ? Color.primary.opacity(0.12) : Color.clear)
            .overlay(
                Rectangle()
                    .stroke(Color.primary.opacity(0.16), lineWidth: 0.5)
            )
    }
}
