import Foundation

nonisolated public struct HistorySearchResult: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let title: String
    public let contentKind: HistoryContentKind
    public let thumbnailPath: String?
    public let matchedSnippet: String?
    public let matchedPageNumber: Int?
    public let score: Double
}

nonisolated struct HistorySearchCandidate: Sendable {
    let id: UUID
    let title: String
    let contentKind: HistoryContentKind
    let thumbnailPath: String?
    let originalText: String
    let normalizedText: String
    let pageNumber: Int?
    let lastOpenedAt: Date
}
