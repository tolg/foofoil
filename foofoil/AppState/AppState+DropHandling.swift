//  AppState+DropHandling.swift
//  foofoil
//
//  Created by tolg on 2026/7/6.
//


import Foundation
import Combine
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import ImageIO
import SwiftUI


extension AppState {
        func isCurrentDrop(_ generation: UInt64) -> Bool {
            generation == currentDropGeneration
        }

        public func handleDrop(providers: [NSItemProvider], completion: @escaping (Bool) -> Void = { _ in }) {
            NSLog("handleDrop started for \(providers.count) providers")
            for (index, p) in providers.enumerated() {
                NSLog("Provider [\(index)] types: \(p.registeredTypeIdentifiers), suggestedName: \(p.suggestedName ?? "nil")")
            }

            // 递增代次，后续所有异步回调需校验仍为当前代次，否则丢弃（防止并发覆盖与“打开以前的东西”）。
            currentDropGeneration &+= 1
            let generation = currentDropGeneration

            // 直接基于 providers 解析，不再读取全局 drag pasteboard，避免读取到过期/残留的粘贴板内容导致误打开旧数据。
            tryLoadProviders(providers, index: 0, generation: generation, completion: { [weak self] success in
                guard let self else {
                    completion(false)
                    return
                }
                // 若在处理期间已发生更新的拖拽，本次结果视为过期。
                guard self.isCurrentDrop(generation) else {
                    NSLog("handleDrop completion discarded due to newer drop (generation \(generation) vs \(self.currentDropGeneration))")
                    completion(false)
                    return
                }
                completion(success)
            })
        }

        func tryLoadProviders(_ providers: [NSItemProvider], index: Int, generation: UInt64, completion: @escaping (Bool) -> Void) {
            guard isCurrentDrop(generation) else {
                completion(false)
                return
            }
            guard index < providers.count else {
                completion(false)
                return
            }

            self.tryLoadProvider(providers[index], generation: generation) { [weak self] success in
                guard let self else {
                    completion(false)
                    return
                }
                guard self.isCurrentDrop(generation) else {
                    completion(false)
                    return
                }
                if success {
                    completion(true)
                } else {
                    self.tryLoadProviders(providers, index: index + 1, generation: generation, completion: completion)
                }
            }
        }

        func tryLoadProvider(_ provider: NSItemProvider, generation: UInt64, completion: @escaping (Bool) -> Void) {
            guard isCurrentDrop(generation) else {
                completion(false)
                return
            }
            // 1. 尝试以 URL 载入（包括 fileURL 与 http(s) URL）
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { [weak self] url, error in
                    guard let self else {
                        completion(false)
                        return
                    }
                    guard self.isCurrentDrop(generation) else {
                        completion(false)
                        return
                    }

                    if let error {
                        NSLog("loadObject URL failed for provider: \(error.localizedDescription)")
                    }

                    if let droppedURL = url, self.isSupportedDroppedURL(droppedURL) {
                        NSLog("Successfully loaded supported URL: \(droppedURL.absoluteString)")
                        self.openDroppedURL(droppedURL, generation: generation) { success in
                            guard self.isCurrentDrop(generation) else {
                                completion(false)
                                return
                            }
                            if success {
                                completion(true)
                            } else {
                                // URL 处理失败，尝试加载为 Image / Fallback
                                self.tryLoadProviderAsImage(provider, generation: generation, completion: completion)
                            }
                        }
                    } else if let droppedURL = url, droppedURL.isFileURL {
                        // 文件类型不受支持时，不能回退读取其 Finder 图标。
                        completion(false)
                    } else {
                        // 没有得到 URL，或者 URL 不受支持，尝试加载为 Image / Fallback
                        self.tryLoadProviderAsImage(provider, generation: generation, completion: completion)
                    }
                }
            } else {
                // 不能作为 URL 载入，尝试加载为 Image / Fallback
                self.tryLoadProviderAsImage(provider, generation: generation, completion: completion)
            }
        }

        func tryLoadProviderAsImage(_ provider: NSItemProvider, generation: UInt64, completion: @escaping (Bool) -> Void) {
            guard isCurrentDrop(generation) else {
                completion(false)
                return
            }
            if provider.canLoadObject(ofClass: NSImage.self) {
                _ = provider.loadObject(ofClass: NSImage.self) { [weak self] image, error in
                    guard let self else {
                        completion(false)
                        return
                    }
                    guard self.isCurrentDrop(generation) else {
                        completion(false)
                        return
                    }
                    if let error {
                        NSLog("loadObject NSImage failed for provider: \(error.localizedDescription)")
                    }
                    if let nsImage = image as? NSImage {
                        NSLog("Successfully loaded NSImage object from provider")
                        DispatchQueue.main.async {
                            guard self.isCurrentDrop(generation) else {
                                completion(false)
                                return
                            }
                            self.openImage(image: nsImage, originalName: provider.suggestedName)
                            completion(true)
                        }
                    } else {
                        self.tryLoadProviderAsImageData(provider, generation: generation, completion: completion)
                    }
                }
            } else {
                self.tryLoadProviderAsImageData(provider, generation: generation, completion: completion)
            }
        }

        func tryLoadProviderAsImageData(_ provider: NSItemProvider, generation: UInt64, completion: @escaping (Bool) -> Void) {
            guard isCurrentDrop(generation) else {
                completion(false)
                return
            }
            let imageIdentifiers = provider.registeredTypeIdentifiers.filter { ident in
                if let utType = UTType(ident) {
                    return utType.conforms(to: .image)
                }
                return false
            }

            if !imageIdentifiers.isEmpty {
                NSLog("Found image identifiers in provider: \(imageIdentifiers)")
                self.tryLoadImageData(from: provider, with: imageIdentifiers, index: 0, generation: generation) { [weak self] image in
                    guard let self else {
                        completion(false)
                        return
                    }
                    guard self.isCurrentDrop(generation) else {
                        completion(false)
                        return
                    }
                    if let image {
                        NSLog("Successfully loaded NSImage from data representation")
                        DispatchQueue.main.async {
                            guard self.isCurrentDrop(generation) else {
                                completion(false)
                                return
                            }
                            self.openImage(image: image, originalName: provider.suggestedName)
                            completion(true)
                        }
                    } else {
                        self.tryLoadProviderAsFallback(provider, generation: generation, completion: completion)
                    }
                }
            } else {
                self.tryLoadProviderAsFallback(provider, generation: generation, completion: completion)
            }
        }

        func tryLoadProviderAsFallback(_ provider: NSItemProvider, generation: UInt64, completion: @escaping (Bool) -> Void) {
            guard isCurrentDrop(generation) else {
                completion(false)
                return
            }
            self.loadAsItemRepresentation(provider: provider, generation: generation, completion: completion)
        }

        func tryLoadImageData(
            from provider: NSItemProvider,
            with identifiers: [String],
            index: Int,
            generation: UInt64,
            completion: @escaping (NSImage?) -> Void
        ) {
            guard isCurrentDrop(generation) else {
                completion(nil)
                return
            }
            guard index < identifiers.count else {
                completion(nil)
                return
            }

            let typeId = identifiers[index]
            NSLog("Attempting to loadDataRepresentation for type: \(typeId)")

            provider.loadDataRepresentation(forTypeIdentifier: typeId) { [weak self] data, error in
                guard let self else {
                    completion(nil)
                    return
                }
                guard self.isCurrentDrop(generation) else {
                    completion(nil)
                    return
                }
                if let error {
                    NSLog("Failed loadDataRepresentation for \(typeId): \(error.localizedDescription)")
                }
                if let data, let image = NSImage(data: data) {
                    NSLog("Successfully loaded NSImage from type: \(typeId)")
                    completion(image)
                } else {
                    self.tryLoadImageFileRepresentation(from: provider, typeIdentifier: typeId, generation: generation) { image in
                        guard self.isCurrentDrop(generation) else {
                            completion(nil)
                            return
                        }
                        if let image {
                            completion(image)
                        } else {
                            self.tryLoadImageData(from: provider, with: identifiers, index: index + 1, generation: generation, completion: completion)
                        }
                    }
                }
            }
        }

        func tryLoadImageFileRepresentation(
            from provider: NSItemProvider,
            typeIdentifier: String,
            generation: UInt64,
            completion: @escaping (NSImage?) -> Void
        ) {
            guard isCurrentDrop(generation) else {
                completion(nil)
                return
            }
            NSLog("Attempting to loadFileRepresentation for type: \(typeIdentifier)")
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { [weak self] url, error in
                guard let self else {
                    completion(nil)
                    return
                }
                guard self.isCurrentDrop(generation) else {
                    completion(nil)
                    return
                }
                if let error {
                    NSLog("Failed loadFileRepresentation for \(typeIdentifier): \(error.localizedDescription)")
                }

                guard let url else {
                    completion(nil)
                    return
                }

                if url.isFileURL {
                    let image = (try? Data(contentsOf: url)).flatMap(NSImage.init(data:)) ?? NSImage(contentsOf: url)
                    if image != nil {
                        NSLog("Successfully loaded NSImage from file representation: \(typeIdentifier)")
                    }
                    completion(image)
                } else {
                    self.loadDownloadedImage(from: url, generation: generation, completion: completion)
                }
            }
        }

        func handleDropFallback(provider: NSItemProvider, generation: UInt64, completion: @escaping (Bool) -> Void) {
            guard isCurrentDrop(generation) else {
                completion(false)
                return
            }
            NSLog("handleDropFallback started")
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { [weak self] url, error in
                    guard let self else {
                        completion(false)
                        return
                    }
                    guard self.isCurrentDrop(generation) else {
                        completion(false)
                        return
                    }
                    if let error {
                        NSLog("Failed to loadObject URL: \(error.localizedDescription)")
                    }
                    if let fileURL = url {
                        NSLog("Loaded URL: \(fileURL.absoluteString) (isFileURL: \(fileURL.isFileURL))")
                        self.openDroppedURL(fileURL, generation: generation, completion: completion)
                        return
                    }
                    self.loadAsItemRepresentation(provider: provider, generation: generation, completion: completion)
                }
            } else {
                NSLog("Provider cannot load URL, trying loadItem fallback")
                self.loadAsItemRepresentation(provider: provider, generation: generation, completion: completion)
            }
        }

        func loadAsItemRepresentation(provider: NSItemProvider, generation: UInt64, completion: @escaping (Bool) -> Void) {
            guard isCurrentDrop(generation) else {
                completion(false)
                return
            }
            let identifiers = fallbackTypeIdentifiers(for: provider)
            NSLog("Attempting loadItem fallback for identifiers: \(identifiers)")

            tryLoadDroppedItem(from: provider, with: identifiers, index: 0, generation: generation) { [weak self] item in
                guard let self else {
                    completion(false)
                    return
                }
                guard self.isCurrentDrop(generation) else {
                    completion(false)
                    return
                }

                switch item {
                case let .image(image, originalName):
                    DispatchQueue.main.async {
                        guard self.isCurrentDrop(generation) else {
                            completion(false)
                            return
                        }
                        self.openImage(image: image, originalName: originalName)
                        completion(true)
                    }
                case let .url(url):
                    self.openDroppedURL(url, generation: generation, completion: completion)
                case nil:
                    NSLog("loadItem fallback failed, trying loadAsImage fallback")
                    self.loadAsImage(provider: provider, generation: generation, completion: completion)
                }
            }
        }

        func fallbackTypeIdentifiers(for provider: NSItemProvider) -> [String] {
            let additionalIdentifiers = [
                UTType.url.identifier,
                UTType.fileURL.identifier,
                UTType.plainText.identifier,
                UTType.utf8PlainText.identifier,
                UTType.html.identifier
            ]
            var seen = Set<String>()
            return (provider.registeredTypeIdentifiers + additionalIdentifiers).filter { seen.insert($0).inserted }
        }

        func tryLoadDroppedItem(
            from provider: NSItemProvider,
            with identifiers: [String],
            index: Int,
            generation: UInt64,
            completion: @escaping (DroppedItem?) -> Void
        ) {
            guard isCurrentDrop(generation) else {
                completion(nil)
                return
            }
            guard index < identifiers.count else {
                completion(nil)
                return
            }

            let typeIdentifier = identifiers[index]
            NSLog("Attempting loadItem for type: \(typeIdentifier)")
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { [weak self] item, error in
                guard let self else {
                    completion(nil)
                    return
                }
                guard self.isCurrentDrop(generation) else {
                    completion(nil)
                    return
                }

                if let error {
                    NSLog("Failed loadItem for \(typeIdentifier): \(error.localizedDescription)")
                }

                if let droppedItem = self.droppedItem(from: item, typeIdentifier: typeIdentifier, suggestedName: provider.suggestedName) {
                    completion(droppedItem)
                } else {
                    self.tryLoadDroppedItem(from: provider, with: identifiers, index: index + 1, generation: generation, completion: completion)
                }
            }
        }

        func droppedItem(from item: NSSecureCoding?, typeIdentifier: String, suggestedName: String?) -> DroppedItem? {
            if let url = item as? URL {
                NSLog("Loaded URL from item representation \(typeIdentifier): \(url.absoluteString)")
                return .url(url)
            }

            if let url = item as? NSURL, let swiftURL = url as URL? {
                NSLog("Loaded NSURL from item representation \(typeIdentifier): \(swiftURL.absoluteString)")
                return .url(swiftURL)
            }

            if let image = item as? NSImage {
                NSLog("Loaded NSImage from item representation \(typeIdentifier)")
                return .image(image, originalName: suggestedName)
            }

            if let data = item as? Data {
                if let image = NSImage(data: data) {
                    NSLog("Loaded image data from item representation \(typeIdentifier)")
                    return .image(image, originalName: suggestedName)
                }
                if let text = String(data: data, encoding: .utf8), let url = imageURLFromText(text) {
                    NSLog("Loaded URL text from data item representation \(typeIdentifier): \(url.absoluteString)")
                    return .url(url)
                }
            }

            if let text = item as? String, let url = imageURLFromText(text) {
                NSLog("Loaded URL text from item representation \(typeIdentifier): \(url.absoluteString)")
                return .url(url)
            }

            if let text = item as? NSString, let url = imageURLFromText(text as String) {
                NSLog("Loaded NSString URL from item representation \(typeIdentifier): \(url.absoluteString)")
                return .url(url)
            }

            return nil
        }

        func imageURLFromText(_ text: String) -> URL? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: trimmed), isSupportedDroppedURL(url) {
                return url
            }

            if trimmed.range(of: "<html", options: .caseInsensitive) != nil,
               let extractedURL = extractImageURL(from: trimmed) {
                return extractedURL
            }

            guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue),
                  let match = detector.firstMatch(
                    in: trimmed,
                    options: [],
                    range: NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
                  ),
                  let range = Range(match.range, in: trimmed),
                  let url = URL(string: String(trimmed[range])),
                  isSupportedDroppedURL(url) else {
                return nil
            }

            return url
        }

        func isSupportedDroppedURL(_ url: URL) -> Bool {
            if url.isFileURL {
                return canOpenFile(url: url)
            }
            guard let scheme = url.scheme?.lowercased() else {
                return false
            }
            return scheme == "http" || scheme == "https"
        }

        func openDroppedURL(_ url: URL, generation: UInt64, completion: @escaping (Bool) -> Void) {
            guard isCurrentDrop(generation) else {
                completion(false)
                return
            }
            if url.isFileURL {
                // 拖拽文件可能为安全范围 URL，需临时获取访问授权；临时拷贝路径则无需授权亦可读取
                let canOpen: Bool = {
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    return canOpenFile(url: url)
                }()
                if canOpen {
                    DispatchQueue.main.async {
                        guard self.isCurrentDrop(generation) else {
                            completion(false)
                            return
                        }
                        if Self.isExternalMediaFile(url: url) {
                            // 音视频异步验证可播性；保持安全范围访问直到打开完成或失败，以便读取同目录封面。
                            let accessed = url.startAccessingSecurityScopedResource()
                            self.openExternalMediaIfPlayable(url: url, holdsSecurityAccess: accessed)
                        } else {
                            let accessed = url.startAccessingSecurityScopedResource()
                            self.openFile(url: url)
                            if accessed { url.stopAccessingSecurityScopedResource() }
                        }
                        completion(true)
                    }
                } else {
                    completion(false)
                }
            } else {
                // 远程 URL：优先尝试作为图片下载，失败则回退为网页打开，避免“拖进去没反应”
                downloadImage(from: url, generation: generation, isHTMLFallbackAllowed: true) { [weak self] success in
                    guard let self else {
                        completion(false)
                        return
                    }
                    guard self.isCurrentDrop(generation) else {
                        completion(false)
                        return
                    }
                    if success {
                        completion(true)
                    } else {
                        DispatchQueue.main.async {
                            guard self.isCurrentDrop(generation) else {
                                completion(false)
                                return
                            }
                            NSLog("Remote URL not decoded as image, opening as web: \(url.absoluteString)")
                            self.openWeb(url: url)
                            completion(true)
                        }
                    }
                }
            }
        }

        func loadAsImage(provider: NSItemProvider, generation: UInt64, completion: @escaping (Bool) -> Void) {
            guard isCurrentDrop(generation) else {
                completion(false)
                return
            }
            if provider.canLoadObject(ofClass: NSImage.self) {
                _ = provider.loadObject(ofClass: NSImage.self) { [weak self] image, error in
                    guard let self else {
                        completion(false)
                        return
                    }
                    guard self.isCurrentDrop(generation) else {
                        completion(false)
                        return
                    }
                    if let error {
                        NSLog("Failed to loadObject NSImage: \(error.localizedDescription)")
                    }
                    guard let nsImage = image as? NSImage else {
                        completion(false)
                        return
                    }
                    DispatchQueue.main.async {
                        guard self.isCurrentDrop(generation) else {
                            completion(false)
                            return
                        }
                        self.openImage(image: nsImage)
                        completion(true)
                    }
                }
            } else {
                completion(false)
            }
        }

        func downloadImage(from url: URL, generation: UInt64, isHTMLFallbackAllowed: Bool = true, completion: @escaping (Bool) -> Void) {
            guard isCurrentDrop(generation) else {
                completion(false)
                return
            }
            NSLog("downloadImage started for \(url.absoluteString)")
            loadDownloadedImage(from: url, generation: generation) { [weak self] image in
                guard let self else {
                    completion(false)
                    return
                }
                guard self.isCurrentDrop(generation) else {
                    completion(false)
                    return
                }

                if let image {
                    DispatchQueue.main.async {
                        guard self.isCurrentDrop(generation) else {
                            completion(false)
                            return
                        }
                        self.openImage(image: image, originalName: url.lastPathComponent)
                        completion(true)
                    }
                    return
                }

                if isHTMLFallbackAllowed {
                    self.downloadHTMLImageFallback(from: url, generation: generation, completion: completion)
                } else {
                    NSLog("Failed to decode downloaded image data from \(url.absoluteString)")
                    completion(false)
                }
            }
        }

        func loadDownloadedImage(from url: URL, generation: UInt64, completion: @escaping (NSImage?) -> Void) {
            guard isCurrentDrop(generation) else {
                completion(nil)
                return
            }
            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")

            let task = URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
                guard let self, self.isCurrentDrop(generation) else {
                    completion(nil)
                    return
                }
                if let error {
                    NSLog("Failed to download image from \(url.absoluteString): \(error.localizedDescription)")
                    completion(nil)
                    return
                }

                guard let data else {
                    NSLog("No data returned from \(url.absoluteString)")
                    completion(nil)
                    return
                }

                if let image = NSImage(data: data) {
                    NSLog("Successfully downloaded and decoded image from \(url.absoluteString)")
                    completion(image)
                } else {
                    NSLog("Failed to decode downloaded image data from \(url.absoluteString)")
                    completion(nil)
                }
            }
            task.resume()
        }

        func downloadHTMLImageFallback(from url: URL, generation: UInt64, completion: @escaping (Bool) -> Void) {
            guard isCurrentDrop(generation) else {
                completion(false)
                return
            }
            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")

            let task = URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
                guard let self, self.isCurrentDrop(generation) else {
                    completion(false)
                    return
                }
                if let error {
                    NSLog("Failed to download HTML fallback from \(url.absoluteString): \(error.localizedDescription)")
                    completion(false)
                    return
                }

                guard let data,
                      let htmlString = String(data: data, encoding: .utf8),
                      htmlString.range(of: "<html", options: .caseInsensitive) != nil else {
                    completion(false)
                    return
                }

                NSLog("Downloaded content is HTML. Attempting to extract og:image or twitter:image.")
                if let extractedURL = self.extractImageURL(from: htmlString) {
                    NSLog("Extracted image URL: \(extractedURL.absoluteString). Retrying download.")
                    self.downloadImage(from: extractedURL, generation: generation, isHTMLFallbackAllowed: false, completion: completion)
                } else {
                    NSLog("Failed to extract any cover image URL from HTML.")
                    completion(false)
                }
            }
            task.resume()
        }

        func extractImageURL(from html: String) -> URL? {
            // Simple search for og:image
            var searchRange = html.startIndex..<html.endIndex
            while let ogImageRange = html.range(of: "og:image", options: [], range: searchRange) {
                let startOfSearch = ogImageRange.lowerBound
                if let metaStartRange = html.range(of: "<meta", options: .backwards, range: html.startIndex..<startOfSearch),
                   let metaEndRange = html.range(of: ">", options: [], range: startOfSearch..<html.endIndex) {

                    let metaTag = html[metaStartRange.lowerBound...metaEndRange.lowerBound]
                    if let contentRange = metaTag.range(of: "content="),
                       let valStart = metaTag.range(of: "\"", options: [], range: contentRange.upperBound..<metaTag.endIndex) {
                        if let valEnd = metaTag.range(of: "\"", options: [], range: valStart.upperBound..<metaTag.endIndex) {
                            let urlStr = String(metaTag[valStart.upperBound..<valEnd.lowerBound])
                            if let url = URL(string: urlStr), url.scheme?.hasPrefix("http") == true {
                                return url
                            }
                        }
                    }
                    if let contentRange = metaTag.range(of: "content="),
                       let valStart = metaTag.range(of: "'", options: [], range: contentRange.upperBound..<metaTag.endIndex) {
                        if let valEnd = metaTag.range(of: "'", options: [], range: valStart.upperBound..<metaTag.endIndex) {
                            let urlStr = String(metaTag[valStart.upperBound..<valEnd.lowerBound])
                            if let url = URL(string: urlStr), url.scheme?.hasPrefix("http") == true {
                                return url
                            }
                        }
                    }
                }
                searchRange = ogImageRange.upperBound..<html.endIndex
            }

            // Fallback to twitter:image
            searchRange = html.startIndex..<html.endIndex
            while let twitterImageRange = html.range(of: "twitter:image", options: [], range: searchRange) {
                let startOfSearch = twitterImageRange.lowerBound
                if let metaStartRange = html.range(of: "<meta", options: .backwards, range: html.startIndex..<startOfSearch),
                   let metaEndRange = html.range(of: ">", options: [], range: startOfSearch..<html.endIndex) {

                    let metaTag = html[metaStartRange.lowerBound...metaEndRange.lowerBound]
                    if let contentRange = metaTag.range(of: "content="),
                       let valStart = metaTag.range(of: "\"", options: [], range: contentRange.upperBound..<metaTag.endIndex) {
                        if let valEnd = metaTag.range(of: "\"", options: [], range: valStart.upperBound..<metaTag.endIndex) {
                            let urlStr = String(metaTag[valStart.upperBound..<valEnd.lowerBound])
                            if let url = URL(string: urlStr), url.scheme?.hasPrefix("http") == true {
                                return url
                            }
                        }
                    }
                }
                searchRange = twitterImageRange.upperBound..<html.endIndex
            }

            return nil
        }
}
