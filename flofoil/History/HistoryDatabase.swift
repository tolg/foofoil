import Foundation
import SQLite3

nonisolated final class HistoryDatabase {
    static let schemaVersion = 3

    private let queue = DispatchQueue(label: "com.flofoil.history.database", qos: .utility)
    private var connection: OpaquePointer?
    let databaseURL: URL

    init(databaseURL: URL? = nil) throws {
        if let databaseURL {
            self.databaseURL = databaseURL
        } else {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Flofoil", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            self.databaseURL = root.appendingPathComponent("history.sqlite3")
        }
        try openAndMigrate()
    }

    deinit {
        if let connection { sqlite3_close(connection) }
    }

    func upsert(_ config: WindowConfig) throws {
        try queue.sync {
            try transaction {
                var config = config
                let kind = config.contentKind ?? HistoryContentKind.infer(from: config)
                let now = Date().timeIntervalSince1970
                let old = try fetchItem(id: config.id)
                var duplicateCreatedAt: Date?

                // 同一本地来源再次打开时只更新一条历史，不因新的窗口 UUID 重复记录。
                if kind != .note, let fingerprint = config.sourceFingerprint,
                   let duplicate = try findSourceDuplicate(fingerprint: fingerprint, excluding: config.id) {
                    duplicateCreatedAt = duplicate.createdAt
                    try deleteItem(id: duplicate.id)
                }

                // 网页按初始/实际 URL 去重，并保留首次记录的初始 URL。
                if kind == .web, let inputURL = config.webURLString {
                    let actualURL = config.actualWebURLString ?? inputURL
                    if let duplicate = try findWebDuplicate(inputURL: inputURL, actualURL: actualURL, excluding: config.id) {
                        config.webURLString = duplicate.webURLString ?? inputURL
                        if config.actualWebURLString == nil { config.actualWebURLString = duplicate.actualWebURLString }
                        if config.imagePath == nil { config.imagePath = duplicate.imagePath }
                        try deleteItem(id: duplicate.id)
                    }
                }

                // 普通保存只重建元数据和文本块，避免窗口移动等状态变化抹掉已完成的 OCR/PDF/网页索引。
                if old != nil { try deleteChunks(historyID: config.id, kinds: [0, 1]) }
                let createdAt = old?.createdAt.timeIntervalSince1970 ?? duplicateCreatedAt?.timeIntervalSince1970 ?? config.createdAt?.timeIntervalSince1970 ?? now
                let title = displayTitle(for: config, kind: kind)
                try executePrepared("""
                    INSERT INTO history_items (
                        id, content_kind, display_title, original_filename, image_path, text_path,
                        web_url, actual_web_url, image_source, inline_text, is_pinned, opacity,
                        window_frame, show_border, image_scale, text_font_size, is_markdown_preview,
                        svg_color, background_color_hex, created_at, updated_at, last_opened_at,
                        source_fingerprint, index_status, index_version
                    ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET
                        content_kind=excluded.content_kind, display_title=excluded.display_title,
                        original_filename=excluded.original_filename, image_path=excluded.image_path,
                        text_path=excluded.text_path, web_url=excluded.web_url,
                        actual_web_url=excluded.actual_web_url, image_source=excluded.image_source,
                        inline_text=excluded.inline_text, is_pinned=excluded.is_pinned,
                        opacity=excluded.opacity, window_frame=excluded.window_frame,
                        show_border=excluded.show_border, image_scale=excluded.image_scale,
                        text_font_size=excluded.text_font_size,
                        is_markdown_preview=excluded.is_markdown_preview, svg_color=excluded.svg_color,
                        background_color_hex=excluded.background_color_hex, updated_at=excluded.updated_at,
                        last_opened_at=excluded.last_opened_at,
                        source_fingerprint=excluded.source_fingerprint
                    """, bindings: [
                        config.id.uuidString, kind.rawValue, title, config.originalImageName,
                        config.imagePath, config.textPath, config.webURLString, config.actualWebURLString,
                        config.imageSource?.rawValue, config.text, config.isPinned, config.opacity,
                        config.windowFrame, config.showBorder, config.imageScale, config.textFontSize,
                        config.isMarkdownPreview, config.svgColor, config.backgroundColorHex,
                        createdAt, now, now, config.sourceFingerprint, 0, 1
                    ])

                let metadata = [config.webURLString, config.actualWebURLString].compactMap { $0 }.joined(separator: " ")
                try insertChunk(historyID: config.id, title: title, kind: 0, ordinal: 0, pageNumber: nil, text: metadata)
                if kind == .note || kind == .text || kind == .markdown || kind == .csv {
                    try insertTextChunks(historyID: config.id, title: title, kind: 1, text: config.text)
                    try updateIndexStatus(id: config.id, status: 2, error: nil)
                }
            }
        }
    }

    func replaceChunks(historyID: UUID, chunkKind: Int, chunks: [(String, Int?)], completed: Bool) throws {
        try queue.sync {
            try transaction {
                guard let item = try fetchItem(id: historyID) else { return }
                try deleteChunks(historyID: historyID, kinds: [chunkKind])
                for (index, chunk) in chunks.enumerated() {
                    try insertChunk(historyID: historyID, title: item.displayTitle, kind: chunkKind, ordinal: index, pageNumber: chunk.1, text: chunk.0)
                }
                try updateIndexStatus(id: historyID, status: completed ? 2 : 1, error: nil)
            }
        }
    }

    func markIndex(id: UUID, status: Int, error: String? = nil) throws {
        try queue.sync { try updateIndexStatus(id: id, status: status, error: error) }
    }

    func recent(limit: Int) throws -> [WindowConfig] {
        try queue.sync {
            try queryConfigs("SELECT * FROM history_items ORDER BY last_opened_at DESC LIMIT ?", bindings: [limit])
        }
    }

    func config(id: UUID) throws -> WindowConfig? {
        try queue.sync { try queryConfigs("SELECT * FROM history_items WHERE id = ? LIMIT 1", bindings: [id.uuidString]).first }
    }

    func touch(id: UUID) throws {
        try queue.sync {
            try executePrepared("UPDATE history_items SET last_opened_at = ? WHERE id = ?", bindings: [Date().timeIntervalSince1970, id.uuidString])
        }
    }

    func rename(id: UUID, title: String) throws {
        try queue.sync {
            try transaction {
                guard var config = try queryConfigs("SELECT * FROM history_items WHERE id = ?", bindings: [id.uuidString]).first else { return }
                try deleteChunks(historyID: id, kinds: [0, 1])
                config.originalImageName = title.isEmpty ? nil : title
                let displayTitle = displayTitle(for: config, kind: config.contentKind ?? HistoryContentKind.infer(from: config))
                try executePrepared("UPDATE history_items SET display_title = ?, original_filename = ?, updated_at = ? WHERE id = ?", bindings: [displayTitle, config.originalImageName, Date().timeIntervalSince1970, id.uuidString])
                let metadata = [config.webURLString, config.actualWebURLString].compactMap { $0 }.joined(separator: " ")
                try insertChunk(historyID: id, title: displayTitle, kind: 0, ordinal: 0, pageNumber: nil, text: metadata)
                if [.note, .text, .markdown, .csv].contains(config.contentKind ?? .note) {
                    try insertTextChunks(historyID: id, title: displayTitle, kind: 1, text: config.text)
                }
            }
        }
    }

    func updateThumbnailPath(id: UUID, path: String) throws {
        try queue.sync {
            try executePrepared("UPDATE history_items SET thumbnail_path = ? WHERE id = ?", bindings: [path, id.uuidString])
        }
    }

    func remove(id: UUID) throws {
        try queue.sync { try transaction { try deleteItem(id: id) } }
    }

    func removeAll(excluding ids: Set<UUID>) throws {
        try queue.sync {
            try transaction {
                let all = try queryUUIDs("SELECT id FROM history_items")
                for id in all where !ids.contains(id) { try deleteItem(id: id) }
            }
        }
    }

    func searchCandidates(keyword: String, limit: Int = 200) throws -> [HistorySearchCandidate] {
        guard let expression = SearchNGramEncoder.matchExpression(for: keyword) else { return [] }
        return try queue.sync {
            var values: [HistorySearchCandidate] = []
            try withStatement("""
                SELECT h.id, h.display_title, h.content_kind, COALESCE(h.thumbnail_path, h.image_path),
                       c.original_text, c.normalized_text, c.page_number, h.last_opened_at
                FROM search_fts f
                JOIN search_chunks c ON c.id = f.rowid
                JOIN history_items h ON h.id = c.history_id
                WHERE search_fts MATCH ?
                ORDER BY bm25(search_fts, 8.0, 1.0), h.last_opened_at DESC
                LIMIT ?
                """, bindings: [expression, limit]) { statement in
                while sqlite3_step(statement) == SQLITE_ROW {
                    guard let id = UUID(uuidString: text(statement, 0)) else { continue }
                    values.append(HistorySearchCandidate(
                        id: id,
                        title: text(statement, 1),
                        contentKind: HistoryContentKind(rawValue: Int(sqlite3_column_int(statement, 2))) ?? .note,
                        thumbnailPath: optionalText(statement, 3),
                        originalText: text(statement, 4),
                        normalizedText: text(statement, 5),
                        pageNumber: sqlite3_column_type(statement, 6) == SQLITE_NULL ? nil : Int(sqlite3_column_int(statement, 6)),
                        lastOpenedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))
                    ))
                }
            }
            return values
        }
    }

    func rebuildSearchIndex() throws {
        try queue.sync {
            try transaction {
                var rows: [(Int64, String, String)] = []
                try withStatement("""
                    SELECT c.id, h.display_title, c.normalized_text
                    FROM search_chunks c JOIN history_items h ON h.id = c.history_id
                    """, bindings: []) { statement in
                    while sqlite3_step(statement) == SQLITE_ROW {
                        rows.append((sqlite3_column_int64(statement, 0), text(statement, 1), text(statement, 2)))
                    }
                }
                try execute("INSERT INTO search_fts(search_fts) VALUES('delete-all')")
                for row in rows {
                    try executePrepared("INSERT INTO search_fts(rowid, title_terms, body_terms) VALUES (?,?,?)", bindings: [row.0, SearchNGramEncoder.titleTerms(SearchTextNormalizer.normalize(row.1)), SearchNGramEncoder.bodyTerms(row.2)])
                }
                try execute("INSERT INTO search_fts(search_fts) VALUES('integrity-check')")
            }
        }
    }

    func searchDatabaseSize() -> Int64 {
        let paths = [databaseURL.path, databaseURL.path + "-wal", databaseURL.path + "-shm"]
        return paths.reduce(0) { total, path in
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
            return total + size
        }
    }

    private func openAndMigrate() throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw HistoryDatabaseError.open(db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown")
        }
        connection = db
        try execute("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL; PRAGMA foreign_keys = ON; PRAGMA busy_timeout = 3000;")
        guard sqlite3_compileoption_used("ENABLE_FTS5") != 0 else { throw HistoryDatabaseError.unavailableFTS5 }
        let previousVersion = try scalarInt("PRAGMA user_version")
        try execute("""
            CREATE TABLE IF NOT EXISTS history_items (
                id TEXT PRIMARY KEY NOT NULL, content_kind INTEGER NOT NULL,
                display_title TEXT NOT NULL DEFAULT '', original_filename TEXT,
                image_path TEXT, text_path TEXT, web_url TEXT, actual_web_url TEXT,
                image_source TEXT, inline_text TEXT NOT NULL DEFAULT '', is_pinned INTEGER NOT NULL DEFAULT 0,
                opacity REAL NOT NULL DEFAULT 1.0, window_frame TEXT, show_border INTEGER NOT NULL DEFAULT 1,
                image_scale REAL NOT NULL DEFAULT 1.0, text_font_size REAL NOT NULL DEFAULT 16.0,
                is_markdown_preview INTEGER NOT NULL DEFAULT 0, svg_color TEXT, background_color_hex TEXT,
                created_at REAL NOT NULL, updated_at REAL NOT NULL, last_opened_at REAL NOT NULL,
                source_fingerprint TEXT, index_status INTEGER NOT NULL DEFAULT 0,
                index_version INTEGER NOT NULL DEFAULT 0, index_error TEXT, thumbnail_path TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_history_last_opened ON history_items(last_opened_at DESC);
            CREATE INDEX IF NOT EXISTS idx_history_kind ON history_items(content_kind);
            CREATE INDEX IF NOT EXISTS idx_history_web_url ON history_items(web_url) WHERE web_url IS NOT NULL;
            CREATE INDEX IF NOT EXISTS idx_history_actual_web_url ON history_items(actual_web_url) WHERE actual_web_url IS NOT NULL;
            CREATE INDEX IF NOT EXISTS idx_history_source_fingerprint ON history_items(source_fingerprint) WHERE source_fingerprint IS NOT NULL;
            CREATE TABLE IF NOT EXISTS search_chunks (
                id INTEGER PRIMARY KEY, history_id TEXT NOT NULL, chunk_kind INTEGER NOT NULL,
                ordinal INTEGER NOT NULL, page_number INTEGER, original_text TEXT NOT NULL,
                normalized_text TEXT NOT NULL,
                FOREIGN KEY(history_id) REFERENCES history_items(id) ON DELETE CASCADE,
                UNIQUE(history_id, chunk_kind, ordinal)
            );
            CREATE INDEX IF NOT EXISTS idx_search_chunks_history ON search_chunks(history_id);
            CREATE VIRTUAL TABLE IF NOT EXISTS search_fts USING fts5(title_terms, body_terms, content='', detail=column, tokenize='unicode61');
            """)
        if previousVersion == 1 {
            // 开发期 schema v1 曾使用 contentful FTS；升级为仅保存 token posting 的 contentless 索引。
            try execute("DROP TABLE IF EXISTS search_fts; CREATE VIRTUAL TABLE search_fts USING fts5(title_terms, body_terms, content='', detail=column, tokenize='unicode61');")
            var rows: [(Int64, String, String)] = []
            try withStatement("SELECT c.id, h.display_title, c.normalized_text FROM search_chunks c JOIN history_items h ON h.id = c.history_id", bindings: []) { statement in
                while sqlite3_step(statement) == SQLITE_ROW {
                    rows.append((sqlite3_column_int64(statement, 0), text(statement, 1), text(statement, 2)))
                }
            }
            for row in rows {
                try executePrepared("INSERT INTO search_fts(rowid, title_terms, body_terms) VALUES (?,?,?)", bindings: [row.0, SearchNGramEncoder.titleTerms(SearchTextNormalizer.normalize(row.1)), SearchNGramEncoder.bodyTerms(row.2)])
            }
        }
        try execute("PRAGMA user_version = \(Self.schemaVersion)")
        // 新库明确不读取旧历史；初始化成功后移除旧键，避免旧路径复活。
        UserDefaults.standard.removeObject(forKey: "historyConfigs")
    }

    private func insertTextChunks(historyID: UUID, title: String, kind: Int, text: String) throws {
        let chunks = TextContentIndexer.chunk(text)
        for (index, chunk) in chunks.enumerated() {
            try insertChunk(historyID: historyID, title: title, kind: kind, ordinal: index, pageNumber: nil, text: chunk)
        }
    }

    private func displayTitle(for config: WindowConfig, kind: HistoryContentKind) -> String {
        // 普通笔记的原始文件名字段承载用户自定义标题；其他类型继续沿用既有展示规则。
        if kind == .note, let title = config.originalImageName?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        return config.historyMenuDisplayName
    }

    private func insertChunk(historyID: UUID, title: String, kind: Int, ordinal: Int, pageNumber: Int?, text original: String) throws {
        let normalized = SearchTextNormalizer.normalize(original)
        try executePrepared("INSERT INTO search_chunks(history_id, chunk_kind, ordinal, page_number, original_text, normalized_text) VALUES (?,?,?,?,?,?)", bindings: [historyID.uuidString, kind, ordinal, pageNumber, original, normalized])
        let rowID = sqlite3_last_insert_rowid(connection)
        try executePrepared("INSERT INTO search_fts(rowid, title_terms, body_terms) VALUES (?,?,?)", bindings: [rowID, SearchNGramEncoder.titleTerms(SearchTextNormalizer.normalize(title)), SearchNGramEncoder.bodyTerms(normalized)])
    }

    private func deleteChunks(historyID: UUID, kinds: [Int]?) throws {
        var sql = """
            SELECT c.id, h.display_title, c.normalized_text
            FROM search_chunks c JOIN history_items h ON h.id = c.history_id
            WHERE c.history_id = ?
            """
        var bindings: [Any?] = [historyID.uuidString]
        if let kinds, !kinds.isEmpty {
            sql += " AND c.chunk_kind IN (\(Array(repeating: "?", count: kinds.count).joined(separator: ",")))"
            bindings.append(contentsOf: kinds)
        }
        var rows: [(Int64, String, String)] = []
        try withStatement(sql, bindings: bindings) { statement in
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append((sqlite3_column_int64(statement, 0), text(statement, 1), text(statement, 2)))
            }
        }
        for row in rows {
            try executePrepared(
                "INSERT INTO search_fts(search_fts, rowid, title_terms, body_terms) VALUES('delete',?,?,?)",
                bindings: [row.0, SearchNGramEncoder.titleTerms(SearchTextNormalizer.normalize(row.1)), SearchNGramEncoder.bodyTerms(row.2)]
            )
        }
        var deleteSQL = "DELETE FROM search_chunks WHERE history_id = ?"
        if let kinds, !kinds.isEmpty { deleteSQL += " AND chunk_kind IN (\(Array(repeating: "?", count: kinds.count).joined(separator: ",")))" }
        try executePrepared(deleteSQL, bindings: bindings)
    }

    private func deleteThumbnailFile(for id: UUID) {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Flofoil", isDirectory: true)
        let thumbnailURL = root.appendingPathComponent("Thumbnails").appendingPathComponent("\(id.uuidString).heic")
        try? FileManager.default.removeItem(at: thumbnailURL)
    }

    private func deleteItem(id: UUID) throws {
        try deleteChunks(historyID: id, kinds: nil)
        try executePrepared("DELETE FROM history_items WHERE id = ?", bindings: [id.uuidString])
        deleteThumbnailFile(for: id)
    }

    private func updateIndexStatus(id: UUID, status: Int, error: String?) throws {
        try executePrepared("UPDATE history_items SET index_status = ?, index_version = ?, index_error = ? WHERE id = ?", bindings: [status, 1, error.map { String($0.prefix(500)) }, id.uuidString])
    }

    private struct StoredItem { let id: UUID; let displayTitle: String; let createdAt: Date }
    private func fetchItem(id: UUID) throws -> StoredItem? {
        var result: StoredItem?
        try withStatement("SELECT display_title, created_at FROM history_items WHERE id = ?", bindings: [id.uuidString]) { statement in
            if sqlite3_step(statement) == SQLITE_ROW { result = StoredItem(id: id, displayTitle: text(statement, 0), createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))) }
        }
        return result
    }

    private func findWebDuplicate(inputURL: String, actualURL: String, excluding id: UUID) throws -> WindowConfig? {
        try queryConfigs("""
            SELECT * FROM history_items WHERE id != ? AND web_url IS NOT NULL AND
            (web_url IN (?, ?) OR COALESCE(actual_web_url, web_url) IN (?, ?))
            ORDER BY created_at ASC LIMIT 1
            """, bindings: [id.uuidString, inputURL, actualURL, inputURL, actualURL]).first
    }

    private func findSourceDuplicate(fingerprint: String, excluding id: UUID) throws -> WindowConfig? {
        try queryConfigs(
            "SELECT * FROM history_items WHERE id != ? AND source_fingerprint = ? ORDER BY created_at ASC LIMIT 1",
            bindings: [id.uuidString, fingerprint]
        ).first
    }

    private func queryUUIDs(_ sql: String) throws -> [UUID] {
        var result: [UUID] = []
        try withStatement(sql, bindings: []) { statement in
            while sqlite3_step(statement) == SQLITE_ROW, let id = UUID(uuidString: text(statement, 0)) { result.append(id) }
        }
        return result
    }

    private func queryConfigs(_ sql: String, bindings: [Any?]) throws -> [WindowConfig] {
        var result: [WindowConfig] = []
        try withStatement(sql, bindings: bindings) { statement in
            let columns = columnMap(statement)
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let id = UUID(uuidString: text(statement, columns["id"]!)) else { continue }
                let kind = HistoryContentKind(rawValue: Int(sqlite3_column_int(statement, columns["content_kind"]!))) ?? .note
                result.append(WindowConfig(
                    id: id,
                    imagePath: optionalText(statement, columns["image_path"]!),
                    webURLString: optionalText(statement, columns["web_url"]!),
                    actualWebURLString: optionalText(statement, columns["actual_web_url"]!),
                    originalImageName: optionalText(statement, columns["original_filename"]!),
                    imageSource: optionalText(statement, columns["image_source"]!).flatMap(ImageSource.init(rawValue:)),
                    text: text(statement, columns["inline_text"]!),
                    isPinned: sqlite3_column_int(statement, columns["is_pinned"]!) != 0,
                    opacity: sqlite3_column_double(statement, columns["opacity"]!),
                    windowFrame: optionalText(statement, columns["window_frame"]!),
                    showBorder: sqlite3_column_int(statement, columns["show_border"]!) != 0,
                    imageScale: sqlite3_column_double(statement, columns["image_scale"]!),
                    textFontSize: sqlite3_column_double(statement, columns["text_font_size"]!),
                    isMarkdownPreview: sqlite3_column_int(statement, columns["is_markdown_preview"]!) != 0,
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, columns["created_at"]!)),
                    svgColor: optionalText(statement, columns["svg_color"]!),
                    backgroundColorHex: optionalText(statement, columns["background_color_hex"]!),
                    textPath: optionalText(statement, columns["text_path"]!),
                    contentKind: kind,
                    sourceFingerprint: optionalText(statement, columns["source_fingerprint"]!),
                    storedDisplayTitle: text(statement, columns["display_title"]!),
                    thumbnailPath: optionalText(statement, columns["thumbnail_path"]!)
                ))
            }
        }
        return result
    }

    private func transaction(_ work: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try work(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }

    private func execute(_ sql: String) throws {
        guard let connection else { throw HistoryDatabaseError.open("connection closed") }
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(connection, sql, nil, nil, &message) == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(connection))
            sqlite3_free(message)
            throw HistoryDatabaseError.execute(detail)
        }
    }

    private func scalarInt(_ sql: String) throws -> Int {
        var value = 0
        try withStatement(sql, bindings: []) { statement in
            if sqlite3_step(statement) == SQLITE_ROW { value = Int(sqlite3_column_int(statement, 0)) }
        }
        return value
    }

    private func executePrepared(_ sql: String, bindings: [Any?]) throws {
        try withStatement(sql, bindings: bindings) { statement in
            guard sqlite3_step(statement) == SQLITE_DONE else { throw HistoryDatabaseError.execute(errorMessage) }
        }
    }

    private func withStatement(_ sql: String, bindings: [Any?], body: (OpaquePointer) throws -> Void) throws {
        guard let connection else { throw HistoryDatabaseError.open("connection closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw HistoryDatabaseError.prepare(errorMessage) }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in bindings.enumerated() { try bind(value, to: statement, index: Int32(offset + 1)) }
        try body(statement)
    }

    private func bind(_ value: Any?, to statement: OpaquePointer, index: Int32) throws {
        let result: Int32
        switch value {
        case nil: result = sqlite3_bind_null(statement, index)
        case let value as String: result = sqlite3_bind_text(statement, index, value, -1, Self.transient)
        case let value as Int: result = sqlite3_bind_int64(statement, index, Int64(value))
        case let value as Int64: result = sqlite3_bind_int64(statement, index, value)
        case let value as Double: result = sqlite3_bind_double(statement, index, value)
        case let value as Bool: result = sqlite3_bind_int(statement, index, value ? 1 : 0)
        default: throw HistoryDatabaseError.bind("unsupported value")
        }
        guard result == SQLITE_OK else { throw HistoryDatabaseError.bind(errorMessage) }
    }

    private var errorMessage: String { connection.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown" }
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private func text(_ statement: OpaquePointer, _ column: Int32) -> String { sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "" }
    private func optionalText(_ statement: OpaquePointer, _ column: Int32) -> String? { sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : text(statement, column) }
    private func columnMap(_ statement: OpaquePointer) -> [String: Int32] {
        Dictionary(uniqueKeysWithValues: (0..<sqlite3_column_count(statement)).map { (String(cString: sqlite3_column_name(statement, $0)), $0) })
    }
}
