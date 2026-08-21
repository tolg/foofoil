import Foundation

public final class ContentIndexCoordinator: @unchecked Sendable {
    public static let shared = ContentIndexCoordinator()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.flamina.history.indexing"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private let lock = NSLock()
    private var operations: [UUID: Operation] = [:]
    private var scheduledPaths: [UUID: String] = [:]

    private init() {}

    public func schedule(config: WindowConfig) {
        let kind = config.contentKind ?? HistoryContentKind.infer(from: config)
        guard kind == .image || kind == .pdf || kind == .video, let path = config.imagePath else { return }
        lock.lock()
        if scheduledPaths[config.id] == path {
            lock.unlock()
            return
        }
        operations[config.id]?.cancel()
        scheduledPaths[config.id] = path
        lock.unlock()
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak operation] in
            guard operation?.isCancelled == false else { return }
            do {
                // 1. 生成正方形 HEIC 缩略图文件并更新数据库
                let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Flamina", isDirectory: true)
                let thumbnailURL = root.appendingPathComponent("Thumbnails").appendingPathComponent("\(config.id.uuidString).heic")
                
                if HistoryThumbnailGenerator.generateThumbnail(for: URL(fileURLWithPath: path), kind: kind, destinationURL: thumbnailURL) {
                    HistoryRepository.shared.updateThumbnailPath(id: config.id, path: thumbnailURL.path)
                    HistoryManager.shared.refresh()
                }

                // 2. 提取文本 OCR 并进行索引；视频没有可索引的文本内容，仅保留元数据
                if kind != .video {
                    let chunks: [(String, Int?)]
                    if kind == .pdf {
                        chunks = try PDFTextIndexer.extract(url: URL(fileURLWithPath: path)) { operation?.isCancelled ?? true }
                    } else {
                        chunks = [(try ImageOCRIndexer.recognize(url: URL(fileURLWithPath: path)), nil)]
                    }
                    guard operation?.isCancelled == false,
                          HistoryRepository.shared.config(id: config.id)?.imagePath == path else { return }
                    HistoryRepository.shared.replaceChunks(historyID: config.id, chunkKind: kind == .pdf ? 4 : 2, chunks: chunks.filter { !$0.0.isEmpty })
                }
            } catch {
                NSLog("内容索引失败（%@）：%@", config.id.uuidString, error.localizedDescription)
            }
        }
        lock.lock(); operations[config.id] = operation; lock.unlock()
        queue.addOperation(operation)
    }

    public func indexWebContent(historyID: UUID, text: String) {
        let content = WebContentIndexer.sanitize(text)
        queue.addOperation {
            guard HistoryRepository.shared.config(id: historyID) != nil else { return }
            let chunks = TextContentIndexer.chunk(content).map { ($0, Optional<Int>.none) }
            HistoryRepository.shared.replaceChunks(historyID: historyID, chunkKind: 3, chunks: chunks)
        }
    }

    public func cancel(historyID: UUID) {
        lock.lock(); let operation = operations.removeValue(forKey: historyID); scheduledPaths.removeValue(forKey: historyID); lock.unlock()
        operation?.cancel()
    }

    public func cancelAll(excluding ids: Set<UUID> = []) {
        lock.lock()
        let cancelled = operations.filter { !ids.contains($0.key) }
        cancelled.keys.forEach { operations.removeValue(forKey: $0); scheduledPaths.removeValue(forKey: $0) }
        lock.unlock()
        cancelled.values.forEach { $0.cancel() }
    }
}
