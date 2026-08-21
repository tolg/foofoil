import Foundation

nonisolated public final class HistoryRepository: @unchecked Sendable {
    public static let shared = HistoryRepository()

    private let database: HistoryDatabase?
    public let initializationError: Error?

    init(databaseURL: URL? = nil) {
        do {
            database = try HistoryDatabase(databaseURL: databaseURL)
            initializationError = nil
        } catch {
            database = nil
            initializationError = error
            NSLog("历史数据库初始化失败：%@", error.localizedDescription)
        }
    }

    @discardableResult
    public func upsert(_ config: WindowConfig) -> Bool {
        guard let database else { return false }
        do { try database.upsert(config); return true }
        catch { NSLog("历史保存失败：%@", error.localizedDescription); return false }
    }

    public func recent(limit: Int = 30) -> [WindowConfig] {
        guard let database else { return [] }
        do {
            let configs = try database.recent(limit: limit)
            // 音视频历史仅记录原始文件路径；源文件已不存在（且书签也无法解析）时移除该条历史记录。
            return configs.filter { config in
                let kind = config.contentKind ?? HistoryContentKind.infer(from: config)
                guard kind == .video || kind == .audio else { return true }
                // 路径当前可达（进程内仍有授权），或安全范围书签仍可解析出存在的文件，均保留
                if let path = config.imagePath, FileManager.default.fileExists(atPath: path) { return true }
                if let bookmark = config.videoBookmark, AppState.resolveVideoBookmark(bookmark) != nil { return true }
                remove(id: config.id)
                return false
            }
        }
        catch { NSLog("最近历史读取失败：%@", error.localizedDescription); return [] }
    }

    public func config(id: UUID) -> WindowConfig? {
        guard let database else { return nil }
        return try? database.config(id: id)
    }

    public func touch(id: UUID) { try? database?.touch(id: id) }
    public func remove(id: UUID) { try? database?.remove(id: id) }
    public func updateThumbnailPath(id: UUID, path: String) { try? database?.updateThumbnailPath(id: id, path: path) }
    public func removeAll(excluding ids: Set<UUID>) { try? database?.removeAll(excluding: ids) }
    public func rename(id: UUID, title: String) { try? database?.rename(id: id, title: title) }
    public var searchDatabaseSize: Int64 { database?.searchDatabaseSize() ?? 0 }

    @discardableResult
    public func rebuildSearchIndex() -> Bool {
        do { try database?.rebuildSearchIndex(); return database != nil }
        catch { NSLog("搜索索引重建失败：%@", error.localizedDescription); return false }
    }

    public func replaceChunks(historyID: UUID, chunkKind: Int, chunks: [(String, Int?)], completed: Bool = true) {
        do { try database?.replaceChunks(historyID: historyID, chunkKind: chunkKind, chunks: chunks, completed: completed) }
        catch { try? database?.markIndex(id: historyID, status: 3, error: error.localizedDescription) }
    }

    public func search(_ query: String, limit: Int = 10) async -> [HistorySearchResult] {
        guard let database else { return [] }
        let keywords = SearchTextNormalizer.keywords(query)
        guard !keywords.isEmpty else { return [] }
        return await Task.detached(priority: .userInitiated) {
            do {
                let groups = try keywords.map { keyword in
                    try database.searchCandidates(keyword: keyword).filter { candidate in
                        candidate.title.localizedCaseInsensitiveContains(keyword) || candidate.normalizedText.contains(keyword)
                    }
                }
                guard let first = groups.first else { return [] }
                let commonIDs = groups.dropFirst().reduce(Set(first.map(\.id))) { result, group in
                    result.intersection(group.map(\.id))
                }
                let normalizedQuery = SearchTextNormalizer.normalize(query)
                var results: [HistorySearchResult] = []
                for id in commonIDs {
                    let candidates = groups.flatMap { $0 }.filter { $0.id == id }
                    guard let best = candidates.max(by: { self.score($0, query: normalizedQuery) < self.score($1, query: normalizedQuery) }) else { continue }
                    results.append(HistorySearchResult(
                        id: id,
                        title: best.title,
                        contentKind: best.contentKind,
                        thumbnailPath: best.thumbnailPath,
                        matchedSnippet: self.snippet(from: best.originalText, keywords: keywords),
                        matchedPageNumber: best.pageNumber,
                        score: self.score(best, query: normalizedQuery)
                    ))
                }
                return results.sorted { lhs, rhs in
                    if lhs.score != rhs.score { return lhs.score > rhs.score }
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }.prefix(limit).map { $0 }
            } catch {
                NSLog("历史搜索失败：%@", error.localizedDescription)
                return []
            }
        }.value
    }

    private func score(_ candidate: HistorySearchCandidate, query: String) -> Double {
        let title = SearchTextNormalizer.normalize(candidate.title)
        let base: Double
        if title == query { base = 1_000 }
        else if title.hasPrefix(query) { base = 800 }
        else if title.contains(query) { base = 600 }
        else if candidate.normalizedText.contains(query) { base = 400 }
        else { base = 200 }
        return base + min(candidate.lastOpenedAt.timeIntervalSince1970 / 1_000_000_000, 10)
    }

    private func snippet(from text: String, keywords: [String]) -> String? {
        guard !text.isEmpty, let keyword = keywords.first,
              let range = SearchTextNormalizer.normalize(text).range(of: keyword) else { return nil }
        let normalized = SearchTextNormalizer.normalize(text)
        let offset = normalized.distance(from: normalized.startIndex, to: range.lowerBound)
        let start = normalized.index(normalized.startIndex, offsetBy: max(0, offset - 35))
        let end = normalized.index(start, offsetBy: min(90, normalized.distance(from: start, to: normalized.endIndex)))
        return (start > normalized.startIndex ? "…" : "") + String(normalized[start..<end]) + (end < normalized.endIndex ? "…" : "")
    }
}
