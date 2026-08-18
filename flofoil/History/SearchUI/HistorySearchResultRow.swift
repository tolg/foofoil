import SwiftUI
import ImageIO

struct HistorySearchResultRow: View {
    let result: HistorySearchResult
    let isSelected: Bool

    var body: some View {
        SearchResultRow(
            symbolName: result.contentKind.symbolName,
            title: result.title,
            snippet: result.matchedSnippet,
            pageNumber: result.matchedPageNumber,
            thumbnailPath: result.thumbnailPath,
            showsInlineIcon: true,
            isSelected: isSelected
        )
    }
}

struct OpenURLSearchResultRow: View {
    let url: URL
    let isSelected: Bool

    var body: some View {
        SearchResultRow(
            symbolName: "globe",
            title: String(format: NSLocalizedString("Open URL Search Result Format", comment: ""), url.absoluteString),
            snippet: nil,
            pageNumber: nil,
            thumbnailPath: nil,
            showsInlineIcon: false,
            isSelected: isSelected
        )
    }
}

private struct SearchResultRow: View {
    let symbolName: String
    let title: String
    let snippet: String?
    let pageNumber: Int?
    let thumbnailPath: String?
    let showsInlineIcon: Bool
    let isSelected: Bool
    @StateObject private var thumbnail = HistorySearchThumbnailLoader()

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.12))
                if let image = thumbnail.image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: symbolName).font(.title2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if showsInlineIcon {
                        Image(systemName: symbolName).foregroundStyle(.secondary)
                    }
                    Text(title).font(.headline).lineLimit(1)
                    if let page = pageNumber {
                        Text(String(format: NSLocalizedString("Search Result Page Format", comment: ""), page)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let snippet, !snippet.isEmpty {
                    Text(snippet).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(isSelected ? Color.accentColor.opacity(0.20) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
        .contentShape(Rectangle())
        .task(id: thumbnailPath) { await thumbnail.load(path: thumbnailPath) }
    }
}
