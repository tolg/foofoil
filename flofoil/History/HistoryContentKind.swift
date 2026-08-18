import Foundation

nonisolated public enum HistoryContentKind: Int, Codable, Sendable {
    case note = 0
    case text = 1
    case markdown = 2
    case csv = 3
    case image = 4
    case web = 5
    case pdf = 6

    public var symbolName: String {
        switch self {
        case .web: return "globe"
        case .image: return "photo"
        case .pdf: return "text.document"
        case .markdown: return "arrow.down.document"
        case .csv: return "tablecells"
        case .note, .text: return "note.text"
        }
    }

    public static func infer(from config: WindowConfig) -> Self {
        if config.webURLString != nil { return .web }
        let name = (config.originalImageName ?? config.textPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "").lowercased()
        if name.hasSuffix(".pdf") { return .pdf }
        if config.imagePath != nil { return .image }
        if name.hasSuffix(".md") || name.hasSuffix(".markdown") { return .markdown }
        if name.hasSuffix(".csv") { return .csv }
        if config.textPath != nil { return .text }
        return .note
    }
}
