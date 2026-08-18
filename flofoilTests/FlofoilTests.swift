//
//  FlofoilTests.swift
//  flofoilTests
//
//  Created by tolg on 2026/7/6.
//

import Testing
import Foundation
import AppKit
import CoreGraphics
@testable import Flofoil

@MainActor
@Suite(.serialized)
struct HistorySearchTests {
    private func repository() throws -> (HistoryRepository, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("flofoil-history-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (HistoryRepository(databaseURL: directory.appendingPathComponent("history.sqlite3")), directory)
    }

    @Test func createsSQLiteDatabaseAndDoesNotImportLegacyHistory() throws {
        let legacy = try JSONEncoder().encode([WindowConfig(id: UUID(), text: "不应导入")])
        UserDefaults.standard.set(legacy, forKey: "historyConfigs")
        let (repository, directory) = try repository()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(repository.initializationError == nil)
        #expect(repository.recent().isEmpty)
        #expect(UserDefaults.standard.object(forKey: "historyConfigs") == nil)
    }

    @Test func searchesChineseSubstringAndRanksExactTitleFirst() async throws {
        let (repository, directory) = try repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bodyID = UUID()
        let titleID = UUID()
        #expect(repository.upsert(WindowConfig(id: bodyID, originalImageName: "项目笔记", text: "这里记录历史记录搜索的实现细节")))
        #expect(repository.upsert(WindowConfig(id: titleID, originalImageName: "记录搜索", text: "其他内容")))

        let results = await repository.search("记录搜索")
        #expect(results.map(\.id).contains(bodyID))
        #expect(results.first?.id == titleID)
    }

    @Test func supportsMultiKeywordAcrossDifferentChunksAndCascadingDelete() async throws {
        let (repository, directory) = try repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        #expect(repository.upsert(WindowConfig(id: id, originalImageName: "Swift 资料", text: "数据库索引")))

        #expect((await repository.search("Swift 索引")).first?.id == id)
        repository.remove(id: id)
        #expect((await repository.search("索引")).isEmpty)
        #expect(repository.rebuildSearchIndex())
        #expect(repository.searchDatabaseSize > 0)
    }

    @Test func repeatedLocalSourceKeepsSingleHistoryItem() throws {
        let (repository, directory) = try repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fingerprint = "file:/tmp/repeated-reference.png"
        let firstID = UUID()
        let secondID = UUID()

        #expect(repository.upsert(WindowConfig(id: firstID, imagePath: "/tmp/cache-a.png", originalImageName: "reference.png", contentKind: .image, sourceFingerprint: fingerprint)))
        #expect(repository.upsert(WindowConfig(id: secondID, imagePath: "/tmp/cache-b.png", originalImageName: "reference.png", contentKind: .image, sourceFingerprint: fingerprint)))

        let history = repository.recent()
        #expect(history.count == 1)
        #expect(history.first?.id == secondID)
        #expect(history.first?.sourceFingerprint == fingerprint)
    }
}

@MainActor
@Suite(.serialized)
struct FlofoilTests {

    @Test func testLoadingHistoryKeepsOriginalIdentifier() {
        let historyID = UUID()
        let state = AppState()

        state.loadConfig(WindowConfig(id: historyID, text: "历史内容"))

        #expect(state.id == historyID)
    }

    @Test func testCSVParserHandlesQuotedValuesAndNewlines() {
        let rows = CSVParser.parse("名称,备注\r\n\"张,三\",\"第一行\n第二行\"\r\n李四,\"他说 \"\"你好\"\"\"")

        #expect(rows == [
            ["名称", "备注"],
            ["张,三", "第一行\n第二行"],
            ["李四", "他说 \"你好\""]
        ])
    }

    @Test func testOpenCSVFileUsesTableDocumentMode() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flofoil-test-\(UUID().uuidString).csv")
        let content = "项目,数量\n纸张,3"
        try content.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let state = AppState()
        state.openFile(url: url)

        #expect(state.isCSVDocument)
        #expect(state.text == content)
        #expect(state.imageURL == nil)
        #expect(state.webURL == nil)
    }

    @Test func testOpenedTextFileUsesCachedCopy() throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("flofoil-text-source-\(UUID().uuidString).txt")
        let content = "缓存后的文本内容"
        try content.write(to: sourceURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let state = AppState()
        state.openTextFile(url: sourceURL)

        let cachedURL = try #require(state.textURL)
        #expect(cachedURL != sourceURL)
        #expect(cachedURL.lastPathComponent == "cached_text_\(state.id.uuidString).txt")
        #expect(FileManager.default.fileExists(atPath: cachedURL.path))

        try FileManager.default.removeItem(at: sourceURL)
        let restoredState = AppState(config: state.toConfig())
        #expect(restoredState.text == content)

        let config = try #require(SettingsStore.shared.historyConfigs.first(where: { $0.id == state.id }))
        HistoryManager.shared.removeFromHistory(config)
        #expect(FileManager.default.fileExists(atPath: cachedURL.path) == false)
    }

    @Test func testOpenedLocalWebFileUsesCachedCopy() throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("flofoil-web-source-\(UUID().uuidString).html")
        try "<html><body>缓存网页</body></html>".write(to: sourceURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let state = AppState()
        state.openWeb(url: sourceURL)

        let cachedURL = try #require(state.webURL)
        #expect(cachedURL != sourceURL)
        #expect(cachedURL.lastPathComponent == "cached_web_\(state.id.uuidString).html")
        try FileManager.default.removeItem(at: sourceURL)
        #expect(FileManager.default.fileExists(atPath: cachedURL.path))

        let config = try #require(SettingsStore.shared.historyConfigs.first(where: { $0.id == state.id }))
        HistoryManager.shared.removeFromHistory(config)
        #expect(FileManager.default.fileExists(atPath: cachedURL.path) == false)
    }

    @Test func testClearHistoryPreservesActiveCacheAndRemovesOtherCacheFiles() throws {
        let activeSourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("flofoil-active-\(UUID().uuidString).png")
        let historicalSourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("flofoil-history-\(UUID().uuidString).png")
        try Data("active".utf8).write(to: activeSourceURL)
        try Data("history".utf8).write(to: historicalSourceURL)
        defer {
            try? FileManager.default.removeItem(at: activeSourceURL)
            try? FileManager.default.removeItem(at: historicalSourceURL)
        }

        let activeState = AppState()
        activeState.imageURL = activeSourceURL
        let activeConfig = activeState.toConfig()
        let historicalState = AppState()
        historicalState.imageURL = historicalSourceURL
        let historicalCacheURL = try #require(historicalState.imageURL)
        let cacheDirectoryURL = try #require(AppState.cacheDirectoryURLs().first)
        let orphanCacheURL = cacheDirectoryURL
            .appendingPathComponent("cached_text_\(UUID().uuidString).txt")
        try Data("orphan".utf8).write(to: orphanCacheURL)

        HistoryManager.shared.clearHistory(preserving: [activeConfig])

        let activeCacheURL = try #require(activeState.imageURL)
        #expect(FileManager.default.fileExists(atPath: activeCacheURL.path))
        #expect(FileManager.default.fileExists(atPath: historicalCacheURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: orphanCacheURL.path) == false)
        #expect(SettingsStore.shared.historyConfigs.map(\.id) == [activeConfig.id])

        HistoryManager.shared.clearHistory(preserving: [])
    }

    @Test func testSettingsStoreDefaults() async throws {
        let store = SettingsStore.shared

        // 清理所有数据以确保独立性
        store.clear()

        // 验证默认值为空
        #expect(store.windowConfigs.isEmpty == true)
        #expect(store.historyConfigs.isEmpty == true)
    }

    @Test func testOpacityClamping() async throws {
        let state = AppState()

        // 测试正常范围赋值
        state.opacity = 0.5
        #expect(state.opacity == 0.5)

        // 测试下限 clamp (0.3)
        state.opacity = 0.1
        #expect(state.opacity == 0.3)

        // 测试上限 clamp (1.0)
        state.opacity = 1.5
        #expect(state.opacity == 1.0)

        // 测试增加透明度（越接近 1.0 越不透明）
        state.opacity = 0.9
        state.increaseOpacity()
        #expect(state.opacity == 1.0)

        // 再次增加不应超出 1.0
        state.increaseOpacity()
        #expect(state.opacity == 1.0)

        // 测试减少透明度（越接近 0.3 越透明）
        state.opacity = 0.4
        state.decreaseOpacity()
        #expect(state.opacity == 0.3)

        // 再次减少不应低于 0.3
        state.decreaseOpacity()
        #expect(state.opacity == 0.3)
    }

    @Test func testContentScaleClamping() async throws {
        let state = AppState()

        #expect(state.imageScale == 1.0)
        #expect(state.textFontSize == AppState.defaultTextFontSize)

        state.imageScale = 0.001
        #expect(state.imageScale == AppState.minImageScale)

        state.imageScale = 100
        #expect(state.imageScale == AppState.maxImageScale)

        state.textFontSize = 1
        #expect(state.textFontSize == AppState.minTextFontSize)

        state.textFontSize = 100
        #expect(state.textFontSize == AppState.maxTextFontSize)
    }

    @Test func testWindowConfigDecodesLegacyScaleDefaults() async throws {
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "text": "Legacy note",
          "isPinned": false,
          "opacity": 1.0,
          "showBorder": true
        }
        """
        let data = Data(json.utf8)
        let config = try JSONDecoder().decode(WindowConfig.self, from: data)

        #expect(config.imageScale == 1.0)
        #expect(config.textFontSize == AppState.defaultTextFontSize)
        #expect(config.imageSource == nil)
    }

    @Test func testClipboardImageSourcePersistsInHistoryConfig() throws {
        let config = WindowConfig(
            id: UUID(),
            imagePath: "/tmp/clipboard.png",
            imageSource: .clipboard
        )

        let decodedConfig = try JSONDecoder().decode(
            WindowConfig.self,
            from: JSONEncoder().encode(config)
        )

        #expect(decodedConfig.imageSource == .clipboard)
    }

    @Test func testPinStateToggling() async throws {
        let state = AppState()
        state.isPinned = false

        state.togglePin()
        #expect(state.isPinned == true)

        state.togglePin()
        #expect(state.isPinned == false)
    }

    @Test func testClearContent() async throws {
        let state = AppState()
        let originalId = state.id
        state.text = "Hello Flofoil"
        state.imageURL = URL(fileURLWithPath: "/tmp/mock_image.png")

        #expect(state.text == "Hello Flofoil")
        #expect(state.imageURL?.path == "/tmp/mock_image.png")

        state.resetContent()

        #expect(state.text == "")
        #expect(state.imageURL == nil)

        // 验证持久化存储中该窗口的配置在重置后依然保留在历史记录中
        #expect(SettingsStore.shared.historyConfigs.contains(where: { $0.id == originalId }) == true)

        // 恢复环境，从历史中删除该配置
        if let config = SettingsStore.shared.historyConfigs.first(where: { $0.id == originalId }) {
            HistoryManager.shared.removeFromHistory(config)
        }
    }

    @Test func testImageCaching() async throws {
        let state = AppState()

        // 确保一开始无图且缓存为空
        state.resetContent()
        #expect(state.imageURL == nil)

        // 创建一个临时测试文件作为模拟的源图片
        let tempDir = FileManager.default.temporaryDirectory
        let sourceURL = tempDir.appendingPathComponent("test_source_image.png")
        let dummyData = "dummy image content".data(using: .utf8)!
        try dummyData.write(to: sourceURL)

        // 设置图片，触发缓存逻辑
        state.imageURL = sourceURL

        // 验证缓存后，imageURL 应当指向应用沙盒内的 Application Support 目录中的 cached_image.png
        let cachedURL = state.imageURL
        #expect(cachedURL != nil)
        #expect(cachedURL != sourceURL)
        #expect(cachedURL?.lastPathComponent == "cached_image_\(state.id.uuidString).png")
        #expect(cachedURL?.path.contains("/Library/Application Support/Flofoil") == true)

        // 验证文件是否实际写入成功且内容一致
        #expect(FileManager.default.fileExists(atPath: cachedURL!.path) == true)
        let cachedData = try Data(contentsOf: cachedURL!)
        #expect(cachedData == dummyData)

        // 验证 SettingsStore 历史记录中是否保存了缓存路径
        let savedConfig = SettingsStore.shared.historyConfigs.first(where: { $0.id == state.id })
        #expect(savedConfig != nil)
        #expect(savedConfig?.imagePath == cachedURL?.path)

        let beforeResetId = state.id

        // 清理/重置内容，但不应删除历史状态
        state.resetContent()
        #expect(state.imageURL == nil)

        // 应该依然包含历史记录，并且物理文件应当依然存在（因为在历史记录中被使用了）
        #expect(SettingsStore.shared.historyConfigs.contains(where: { $0.id == beforeResetId }) == true)
        #expect(FileManager.default.fileExists(atPath: cachedURL!.path) == true)

        // 恢复环境，从历史中删除该配置，这也将清理其物理缓存
        if let config = savedConfig {
            HistoryManager.shared.removeFromHistory(config)
        }
        #expect(FileManager.default.fileExists(atPath: cachedURL!.path) == false)

        // 清理临时源文件
        try? FileManager.default.removeItem(at: sourceURL)
    }

    @Test func testMainMenuIncludesHideMenuItems() {
        let appDelegate = AppDelegate()
        appDelegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        guard let mainMenu = NSApplication.shared.mainMenu,
              let appMenuItem = mainMenu.items.first,
              let appMenu = appMenuItem.submenu else {
            #expect(Bool(false), "Main menu or App menu not setup")
            return
        }

        let hideItem = appMenu.items.first { $0.action == #selector(NSApplication.hide(_:)) }
        #expect(hideItem != nil)
        #expect(hideItem?.keyEquivalent == "h")
        #expect(hideItem?.keyEquivalentModifierMask == [.command])

        let hideOthersItem = appMenu.items.first { $0.action == #selector(NSApplication.hideOtherApplications(_:)) }
        #expect(hideOthersItem != nil)
        #expect(hideOthersItem?.keyEquivalent == "h")
        #expect(hideOthersItem?.keyEquivalentModifierMask == [.command, .option])

        let showAllItem = appMenu.items.first { $0.action == #selector(NSApplication.unhideAllApplications(_:)) }
        #expect(showAllItem != nil)
    }

    @Test func testWebModeMenuItemsInFileAndEditMenu() {
        let appDelegate = AppDelegate()
        appDelegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        guard let mainMenu = NSApplication.shared.mainMenu else {
            #expect(Bool(false), "Main menu not setup")
            return
        }

        let fileMenuItem = mainMenu.items.first { $0.submenu?.title == NSLocalizedString("File", comment: "") }
        #expect(fileMenuItem != nil)
        let fileMenu = fileMenuItem?.submenu
        #expect(fileMenu != nil)

        let copyURLFileItem = fileMenu?.items.first { $0.action == Selector(("copyWebURLAction")) }
        #expect(copyURLFileItem != nil)

        let openBrowserItem = fileMenu?.items.first { $0.action == Selector(("openInDefaultBrowserAction")) }
        #expect(openBrowserItem != nil)

        let state = AppState()
        #expect(copyURLFileItem.map { appDelegate.validateMenuItem($0) } == false)
        #expect(openBrowserItem.map { appDelegate.validateMenuItem($0) } == false)
    }

    @Test func testHistorySearchViewModelInitialQuerySetsShouldSelectAll() {
        let model = HistorySearchViewModel()
        model.reset(mode: .url, initialQuery: "https://apple.com")
        #expect(model.query == "https://apple.com")
        #expect(model.shouldSelectAll == true)

        model.reset(mode: .url, initialQuery: nil)
        #expect(model.query == "")
        #expect(model.shouldSelectAll == false)
    }
}
