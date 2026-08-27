//
//  SettingsStore.swift
//  foofoil
//
//  Created by tolg on 2026/7/6.
//

import Foundation

nonisolated public enum ImageSource: String, Codable {
    case clipboard
}

nonisolated public struct WindowConfig: Codable, Identifiable {
    public let id: UUID
    public var imagePath: String?
    public var webURLString: String?
    public var actualWebURLString: String?
    public var originalImageName: String?
    public var imageSource: ImageSource?
    public var text: String
    public var isPinned: Bool
    public var opacity: Double
    public var windowFrame: String?
    public var showBorder: Bool
    public var imageScale: Double
    public var textFontSize: Double
    public var isMarkdownPreview: Bool
    public var createdAt: Date?
    public var svgColor: String?
    /// 用户选择的窗体与 PDF 共用背景色；为空时使用各自的系统默认背景。
    public var backgroundColorHex: String?
    public var textPath: String?
    /// SQLite 历史记录保存的真实内容类型；旧 DTO 解码时允许为空并按来源推断。
    public var contentKind: HistoryContentKind?
    /// 本地导入内容的稳定来源标识，用于避免重复打开同一文件时产生多条历史。
    public var sourceFingerprint: String?
    /// 仓库读取时携带的展示标题，不作为窗口内容来源。
    public var storedDisplayTitle: String?
    /// 预先生成并单独存储的 HEIC 缩略图路径，仅用作历史列表展示，不作为窗口内容来源。
    public var thumbnailPath: String?
    public var webZoom: Double
    /// 视频/音频是否循环播放；仅媒体模式生效，默认开启。
    public var isVideoLooping: Bool
    /// 视频/音频原始文件的安全范围书签；沙盒授权仅随进程有效，靠它在 app 重启后恢复访问权限。
    public var videoBookmark: Data?
    /// 扩展状态仅保存 namespace 与引用；实际 payload 由 ExtensionStateStore 原子管理。
    public var extensionID: String?
    public var extensionStateReference: String?
    /// 导航面板属于窗口呈现状态，不进入扩展私有 payload。
    public var navigatorPanelSide: NavigatorPanelSide
    public var navigatorPanelVisibilityMode: NavigatorPanelVisibilityMode
    public var navigatorPanelWidth: Double
    /// 内置同类型文件列表；缺省或条目少于 2 时按单文件历史展示。
    public var fileList: FileListState?


    public init(
        id: UUID,
        imagePath: String? = nil,
        webURLString: String? = nil,
        actualWebURLString: String? = nil,
        originalImageName: String? = nil,
        imageSource: ImageSource? = nil,
        text: String = "",
        isPinned: Bool = false,
        opacity: Double = 1.0,
        windowFrame: String? = nil,
        showBorder: Bool = true,
        imageScale: Double = 1.0,
        textFontSize: Double = 16.0,
        isMarkdownPreview: Bool = false,
        createdAt: Date? = nil,
        svgColor: String? = nil,
        backgroundColorHex: String? = nil,
        textPath: String? = nil,
        contentKind: HistoryContentKind? = nil,
        sourceFingerprint: String? = nil,
        storedDisplayTitle: String? = nil,
        thumbnailPath: String? = nil,
        webZoom: Double = 1.0,
        isVideoLooping: Bool = true,
        videoBookmark: Data? = nil,
        extensionID: String? = nil,
        extensionStateReference: String? = nil,
        navigatorPanelSide: NavigatorPanelSide = .left,
        navigatorPanelVisibilityMode: NavigatorPanelVisibilityMode = .onHover,
        navigatorPanelWidth: Double = 260.0,
        fileList: FileListState? = nil
    ) {
        self.id = id
        self.imagePath = imagePath
        self.webURLString = webURLString
        self.actualWebURLString = actualWebURLString
        self.originalImageName = originalImageName
        self.imageSource = imageSource
        self.text = text
        self.isPinned = isPinned
        self.opacity = opacity
        self.windowFrame = windowFrame
        self.showBorder = showBorder
        self.imageScale = imageScale
        self.textFontSize = textFontSize
        self.isMarkdownPreview = isMarkdownPreview
        self.createdAt = createdAt ?? Date()
        self.svgColor = svgColor
        self.backgroundColorHex = backgroundColorHex
        self.textPath = textPath
        self.contentKind = contentKind
        self.sourceFingerprint = sourceFingerprint
        self.storedDisplayTitle = storedDisplayTitle
        self.thumbnailPath = thumbnailPath
        self.webZoom = webZoom
        self.isVideoLooping = isVideoLooping
        self.videoBookmark = videoBookmark
        self.extensionID = extensionID
        self.extensionStateReference = extensionStateReference
        self.navigatorPanelSide = navigatorPanelSide
        self.navigatorPanelVisibilityMode = navigatorPanelVisibilityMode
        self.navigatorPanelWidth = navigatorPanelWidth
        self.fileList = fileList?.isPresentable == true ? fileList : nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, imagePath, webURLString, actualWebURLString, originalImageName, imageSource, text, isPinned, opacity, windowFrame, showBorder, imageScale, textFontSize, isMarkdownPreview, createdAt, svgColor, backgroundColorHex, textPath, contentKind, sourceFingerprint, storedDisplayTitle, thumbnailPath, webZoom, isVideoLooping, videoBookmark, extensionID, extensionStateReference, navigatorPanelSide, navigatorPanelVisibilityMode, navigatorPanelWidth, fileList
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        imagePath = try container.decodeIfPresent(String.self, forKey: .imagePath)
        webURLString = try container.decodeIfPresent(String.self, forKey: .webURLString)
        actualWebURLString = try container.decodeIfPresent(String.self, forKey: .actualWebURLString)
        originalImageName = try container.decodeIfPresent(String.self, forKey: .originalImageName)
        imageSource = try container.decodeIfPresent(ImageSource.self, forKey: .imageSource)
        text = try container.decode(String.self, forKey: .text)
        isPinned = try container.decode(Bool.self, forKey: .isPinned)
        opacity = try container.decode(Double.self, forKey: .opacity)
        windowFrame = try container.decodeIfPresent(String.self, forKey: .windowFrame)
        showBorder = try container.decodeIfPresent(Bool.self, forKey: .showBorder) ?? true
        imageScale = try container.decodeIfPresent(Double.self, forKey: .imageScale) ?? 1.0
        textFontSize = try container.decodeIfPresent(Double.self, forKey: .textFontSize) ?? 16.0
        isMarkdownPreview = try container.decodeIfPresent(Bool.self, forKey: .isMarkdownPreview) ?? false
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        svgColor = try container.decodeIfPresent(String.self, forKey: .svgColor)
        backgroundColorHex = try container.decodeIfPresent(String.self, forKey: .backgroundColorHex)
        textPath = try container.decodeIfPresent(String.self, forKey: .textPath)
        contentKind = try container.decodeIfPresent(HistoryContentKind.self, forKey: .contentKind)
        sourceFingerprint = try container.decodeIfPresent(String.self, forKey: .sourceFingerprint)
        storedDisplayTitle = try container.decodeIfPresent(String.self, forKey: .storedDisplayTitle)
        thumbnailPath = try container.decodeIfPresent(String.self, forKey: .thumbnailPath)
        webZoom = try container.decodeIfPresent(Double.self, forKey: .webZoom) ?? 1.0
        // 旧数据没有循环播放字段；解码时默认开启。
        isVideoLooping = try container.decodeIfPresent(Bool.self, forKey: .isVideoLooping) ?? true
        videoBookmark = try container.decodeIfPresent(Data.self, forKey: .videoBookmark)
        extensionID = try container.decodeIfPresent(String.self, forKey: .extensionID)
        extensionStateReference = try container.decodeIfPresent(String.self, forKey: .extensionStateReference)
        navigatorPanelSide = try container.decodeIfPresent(NavigatorPanelSide.self, forKey: .navigatorPanelSide) ?? .right
        navigatorPanelVisibilityMode = try container.decodeIfPresent(
            NavigatorPanelVisibilityMode.self,
            forKey: .navigatorPanelVisibilityMode
        ) ?? .onHover
        navigatorPanelWidth = NavigatorPanelMetrics.clampWidth(
            try container.decodeIfPresent(Double.self, forKey: .navigatorPanelWidth) ?? NavigatorPanelMetrics.defaultWidth
        )
        let decodedList = try container.decodeIfPresent(FileListState.self, forKey: .fileList)
        fileList = decodedList?.isPresentable == true ? decodedList : nil
    }

    public var historyMenuSymbolName: String {
        if let fileList, fileList.isPresentable {
            return fileList.kind.historySymbolName
        }
        if let contentKind { return contentKind.symbolName }
        if self.webURLString != nil {
            return "globe"
        } else if self.imagePath != nil {
            if self.originalImageName?.lowercased().hasSuffix(".pdf") == true {
                return "text.document"
            }
            return "photo"
        } else if self.originalImageName?.lowercased().hasSuffix(".csv") == true {
            return "tablecells"
        } else {
            let isMarkdown: Bool
            if let textPath = self.textPath {
                let filename = self.originalImageName ?? URL(fileURLWithPath: textPath).lastPathComponent
                isMarkdown = self.isMarkdownPreview && (filename.lowercased().hasSuffix(".md") == true || filename.lowercased().hasSuffix(".markdown") == true)
            } else {
                isMarkdown = self.isMarkdownPreview && (self.originalImageName?.lowercased().hasSuffix(".md") == true || self.originalImageName?.lowercased().hasSuffix(".markdown") == true)
            }
            return isMarkdown ? "arrow.down.document" : "note.text"
        }
    }

    public var historyMenuDisplayName: String {
        if let storedDisplayTitle, !storedDisplayTitle.isEmpty { return storedDisplayTitle }
        if let fileList, fileList.isPresentable {
            return String(format: NSLocalizedString(fileList.kind.historyTitleFormatKey, comment: ""), fileList.items.count)
        }
        if let webURLString = self.webURLString {
            return self.originalImageName ?? webURLString
        } else if let imagePath = self.imagePath {
            let isClipboardImage = self.imageSource == .clipboard
            let isDropped = self.originalImageName == nil || self.originalImageName == "dropped_image.png"
            if isClipboardImage || isDropped {
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
                let dateStr = self.createdAt.map { dateFormatter.string(from: $0) } ?? ""
                let displayName = isClipboardImage ? NSLocalizedString("Clipboard Image", comment: "") : ""
                return "\(displayName) \(dateStr)".trimmingCharacters(in: .whitespaces)
            } else {
                return self.originalImageName ?? URL(fileURLWithPath: imagePath).lastPathComponent
            }
        } else if self.originalImageName?.lowercased().hasSuffix(".csv") == true {
            return self.originalImageName ?? ""
        } else if let textPath = self.textPath {
            return self.originalImageName ?? URL(fileURLWithPath: textPath).lastPathComponent
        } else {
            let text = self.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = text.count > 30 ? String(text.prefix(30)) + "..." : text
            if displayName.isEmpty {
                let isMarkdown = self.isMarkdownPreview && (self.originalImageName?.lowercased().hasSuffix(".md") == true || self.originalImageName?.lowercased().hasSuffix(".markdown") == true)
                return isMarkdown ? NSLocalizedString("Untitled Markdown", comment: "") : NSLocalizedString("Untitled Note", comment: "")
            } else {
                return displayName
            }
        }
    }

    public var historyMenuTitle: String {
        let emoji: String
        switch historyMenuSymbolName {
        case "globe": emoji = "🌐"
        case "photo", "photo.on.rectangle", "text.document": emoji = "🏞️"
        case "play.rectangle", "film.stack": emoji = "🎬"
        case "music.note", "music.note.list": emoji = "🎵"
        case "tablecells": emoji = "▦"
        case "arrow.down.document": emoji = "Ⓜ️"
        default: emoji = "📝"
        }
        return "\(emoji) \(historyMenuDisplayName)"
    }
}

public class SettingsStore {
    public static let shared = SettingsStore()

    private let userDefaults = UserDefaults.standard

    private init() {
        userDefaults.register(defaults: [
            Keys.opacity: 1.0,
            Keys.isPinned: false,
            Keys.text: "",
            Keys.navigatorPanelSide: NavigatorPanelSide.left.rawValue,
            Keys.navigatorPanelVisibilityMode: NavigatorPanelVisibilityMode.onHover.rawValue,
            Keys.navigatorPanelWidth: NavigatorPanelMetrics.defaultWidth,
            Keys.extensionAutoCheckUpdates: true,
            Keys.extensionAutoDownloadUpdates: false,
            Keys.extensionAutoInstallCompatibleMinorUpdates: false,
            Keys.imageListSlideshowInterval: ImageListSlideshow.defaultInterval
        ])
    }

    private enum Keys {
        static let isPinned = "isPinned"
        static let opacity = "opacity"
        static let text = "text"
        static let imagePath = "imagePath"
        static let windowFrame = "windowFrame"
        static let windowConfigs = "windowConfigs"
        static let historyConfigs = "historyConfigs"
        static let navigatorPanelSide = "navigatorPanelSide"
        static let navigatorPanelVisibilityMode = "navigatorPanelVisibilityMode"
        static let navigatorPanelWidth = "navigatorPanelWidth"
        static let preferredProvidersByDomain = "preferredProvidersByDomain"
        static let extensionAutoCheckUpdates = "extensionAutoCheckUpdates"
        static let extensionAutoDownloadUpdates = "extensionAutoDownloadUpdates"
        static let extensionAutoInstallCompatibleMinorUpdates = "extensionAutoInstallCompatibleMinorUpdates"
        static let imageListSlideshowInterval = "imageListSlideshowInterval"
    }

    var navigatorPanelSide: NavigatorPanelSide {
        get { NavigatorPanelSide(rawValue: userDefaults.string(forKey: Keys.navigatorPanelSide) ?? "") ?? .left }
        set { userDefaults.set(newValue.rawValue, forKey: Keys.navigatorPanelSide) }
    }

    var navigatorPanelVisibilityMode: NavigatorPanelVisibilityMode {
        get {
            NavigatorPanelVisibilityMode(
                rawValue: userDefaults.string(forKey: Keys.navigatorPanelVisibilityMode) ?? ""
            ) ?? .onHover
        }
        set { userDefaults.set(newValue.rawValue, forKey: Keys.navigatorPanelVisibilityMode) }
    }

    var navigatorPanelWidth: Double {
        get { NavigatorPanelMetrics.clampWidth(userDefaults.double(forKey: Keys.navigatorPanelWidth)) }
        set { userDefaults.set(NavigatorPanelMetrics.clampWidth(newValue), forKey: Keys.navigatorPanelWidth) }
    }

    var preferredProvidersByDomain: [String: String] {
        get {
            guard let data = userDefaults.data(forKey: Keys.preferredProvidersByDomain),
                  let values = try? JSONDecoder().decode([String: String].self, from: data) else {
                return [:]
            }
            return values
        }
        set {
            userDefaults.set(try? JSONEncoder().encode(newValue), forKey: Keys.preferredProvidersByDomain)
        }
    }

    var extensionAutoCheckUpdates: Bool {
        get { userDefaults.object(forKey: Keys.extensionAutoCheckUpdates) as? Bool ?? true }
        set { userDefaults.set(newValue, forKey: Keys.extensionAutoCheckUpdates) }
    }

    var extensionAutoDownloadUpdates: Bool {
        get { userDefaults.bool(forKey: Keys.extensionAutoDownloadUpdates) }
        set { userDefaults.set(newValue, forKey: Keys.extensionAutoDownloadUpdates) }
    }

    var extensionAutoInstallCompatibleMinorUpdates: Bool {
        get { userDefaults.bool(forKey: Keys.extensionAutoInstallCompatibleMinorUpdates) }
        set { userDefaults.set(newValue, forKey: Keys.extensionAutoInstallCompatibleMinorUpdates) }
    }

    /// 图片列表轮播间隔（秒）；全局偏好，打开的列表共用。
    var imageListSlideshowInterval: TimeInterval {
        get {
            guard userDefaults.object(forKey: Keys.imageListSlideshowInterval) != nil else {
                return ImageListSlideshow.defaultInterval
            }
            return ImageListSlideshow.clampInterval(userDefaults.double(forKey: Keys.imageListSlideshowInterval))
        }
        set {
            let clamped = ImageListSlideshow.clampInterval(newValue)
            let current = imageListSlideshowInterval
            guard abs(current - clamped) > 0.001 else { return }
            userDefaults.set(clamped, forKey: Keys.imageListSlideshowInterval)
            NotificationCenter.default.post(name: .imageListSlideshowIntervalDidChange, object: nil)
        }
    }

    public var windowConfigs: [WindowConfig] {
        get {
            if let data = userDefaults.data(forKey: Keys.windowConfigs),
               let configs = try? JSONDecoder().decode([WindowConfig].self, from: data) {
                return configs
            }

            // 迁移旧版单窗口配置（若存在）
            let legacyText = userDefaults.string(forKey: Keys.text)
            let legacyImagePath = userDefaults.string(forKey: Keys.imagePath)

            // 只有当有实际有意义的旧数据时才迁移（非空文本，或存在图片）
            let hasLegacyData = (legacyText != nil && !legacyText!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || (legacyImagePath != nil)

            if hasLegacyData {
                let legacyConfig = WindowConfig(
                    id: UUID(),
                    imagePath: legacyImagePath,
                    text: legacyText ?? "",
                    isPinned: userDefaults.bool(forKey: Keys.isPinned),
                    opacity: userDefaults.double(forKey: Keys.opacity) == 0 ? 1.0 : userDefaults.double(forKey: Keys.opacity),
                    windowFrame: userDefaults.string(forKey: Keys.windowFrame),
                    showBorder: true
                )
                let configs = [legacyConfig]

                // 立即保存迁移后的配置列表
                if let data = try? JSONEncoder().encode(configs) {
                    userDefaults.set(data, forKey: Keys.windowConfigs)
                }

                // 清理旧版本配置项
                userDefaults.removeObject(forKey: Keys.isPinned)
                userDefaults.removeObject(forKey: Keys.opacity)
                userDefaults.removeObject(forKey: Keys.text)
                userDefaults.removeObject(forKey: Keys.imagePath)
                userDefaults.removeObject(forKey: Keys.windowFrame)

                return configs
            }

            return []
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                userDefaults.set(data, forKey: Keys.windowConfigs)
            }
        }
    }

    /// 兼容旧调用点的只读快照。历史权威数据已迁移到 SQLite，不再读写此 UserDefaults 键。
    public var historyConfigs: [WindowConfig] {
        get {
            HistoryRepository.shared.recent(limit: 30)
        }
        set {
            // 仅为源代码兼容保留 setter；禁止把历史重新写回 UserDefaults。
            userDefaults.removeObject(forKey: Keys.historyConfigs)
        }
    }

    public func updateConfig(
        id: UUID,
        imagePath: String?,
        text: String,
        isPinned: Bool,
        opacity: Double,
        windowFrame: String?
    ) {
        var configs = windowConfigs
        if let index = configs.firstIndex(where: { $0.id == id }) {
            configs[index].imagePath = imagePath
            configs[index].text = text
            configs[index].isPinned = isPinned
            configs[index].opacity = opacity
            configs[index].windowFrame = windowFrame
            windowConfigs = configs
        }
    }

    public func clear() {
        userDefaults.removeObject(forKey: Keys.windowConfigs)
        userDefaults.removeObject(forKey: Keys.historyConfigs)
        userDefaults.removeObject(forKey: Keys.imagePath)
        userDefaults.removeObject(forKey: Keys.text)
        HistoryRepository.shared.removeAll(excluding: [])
        HistoryManager.shared.refresh()
    }
}
