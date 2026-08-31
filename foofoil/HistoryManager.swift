import Foundation
import Cocoa
import Combine

/// 供现有视图观察的兼容门面；历史权威数据由 `HistoryRepository` 管理。
public final class HistoryManager: ObservableObject {
    public static let shared = HistoryManager()

    @Published public private(set) var historyConfigs: [WindowConfig] = []
    private let repository = HistoryRepository.shared

    private init() { refresh() }

    public func refresh() {
        let configs = repository.recent(limit: 30)
        if Thread.isMainThread { historyConfigs = configs }
        else { DispatchQueue.main.async { self.historyConfigs = configs } }
    }

    public func addToHistory(_ config: WindowConfig) {
        guard hasPersistableContent(config), repository.upsert(config) else { return }
        refreshUI()
        ContentIndexCoordinator.shared.schedule(config: config)
    }

    public func removeFromHistory(_ config: WindowConfig) {
        ContentIndexCoordinator.shared.cancel(historyID: config.id)
        repository.remove(id: config.id)
        let referencedPaths = Set(repository.recent(limit: Int.max).flatMap(cachePaths(for:)))
        removeCacheFiles(for: config, preserving: activeCachePaths().union(referencedPaths))
        refreshUI()
    }

    public func clearHistory(preserving activeConfigs: [WindowConfig]? = nil) {
        let configs = activeConfigs ?? (NSApplication.shared.delegate as? AppDelegate)?.windowControllers.map { $0.appState.toConfig() } ?? []
        let active = configs.filter(hasPersistableContent)
        let activeIDs = Set(active.map(\.id))
        ContentIndexCoordinator.shared.cancelAll(excluding: activeIDs)
        repository.removeAll(excluding: activeIDs)
        active.forEach { _ = repository.upsert($0) }

        let activePaths = Set(active.flatMap(cachePaths(for:)))
        for directoryURL in AppState.cacheDirectoryURLs() {
            guard let enumerator = FileManager.default.enumerator(at: directoryURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
            for case let fileURL as URL in enumerator where AppState.isManagedCacheURL(fileURL) && !activePaths.contains(fileURL.path) {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
        clearThumbnailFiles(preserving: activeIDs)
        refreshUI()
    }

    /// 清理所有不在活跃列表中的历史项的缩略图文件，兼容旧 Flofoil/Flamina 目录
    private func clearThumbnailFiles(preserving activeIDs: Set<UUID>) {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        for name in ["foofoil", "Flamina", "Flofoil"] {
            let root = appSupport.appendingPathComponent(name, isDirectory: true)
            let thumbnailsDir = root.appendingPathComponent("Thumbnails")
            guard let enumerator = FileManager.default.enumerator(at: thumbnailsDir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
            for case let fileURL as URL in enumerator {
                let uuidString = fileURL.deletingPathExtension().lastPathComponent
                if let uuid = UUID(uuidString: uuidString) {
                    if !activeIDs.contains(uuid) {
                        try? FileManager.default.removeItem(at: fileURL)
                    }
                } else {
                    try? FileManager.default.removeItem(at: fileURL)
                }
            }
        }
    }

    public func updateHistoryTitle(configId: UUID, newTitle: String) {
        // 已打开列表也同步内存标题，避免下一次窗口状态保存把刚改好的数据库标题覆盖掉。
        if let appDelegate = NSApplication.shared.delegate as? AppDelegate,
           let state = appDelegate.windowControllers.first(where: { $0.appState.id == configId })?.appState,
           var fileList = state.fileList,
           fileList.isPresentable {
            fileList.title = FileListState.normalizedTitle(newTitle)
            state.fileList = fileList
        }
        repository.rename(id: configId, title: newTitle)
        refreshUI()
    }

    private func refreshUI() {
        refresh()
        DispatchQueue.main.async {
            (NSApplication.shared.delegate as? AppDelegate)?.updateHistoryMenu()
        }
    }

    private func activeCachePaths() -> Set<String> {
        Set(((NSApplication.shared.delegate as? AppDelegate)?.windowControllers ?? []).flatMap { $0.appState.cachedContentPaths })
    }

    private func cachePaths(for config: WindowConfig) -> [String] {
        var paths = [config.imagePath, config.textPath].compactMap { $0 }
        if let value = config.webURLString, let url = URL(string: value), url.isFileURL { paths.append(url.path) }
        return paths
    }

    private func removeCacheFiles(for config: WindowConfig, preserving paths: Set<String>) {
        for path in cachePaths(for: config) where !paths.contains(path) {
            let url = URL(fileURLWithPath: path)
            if AppState.isManagedCacheURL(url) { try? FileManager.default.removeItem(at: url) }
        }
    }

    private func hasPersistableContent(_ config: WindowConfig) -> Bool {
        config.extensionID != nil || config.imagePath != nil || config.webURLString != nil || config.textPath != nil || !config.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
