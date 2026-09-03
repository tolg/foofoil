//  AppState+MediaType.swift
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
import FoofoilExtensionKit


extension AppState {
        public var isSVG: Bool {
            guard let name = originalImageName?.lowercased() else { return false }
            return name.hasSuffix(".svg")
        }

        public var isPDFDocument: Bool {
            guard let name = originalImageName?.lowercased() else { return false }
            return name.hasSuffix(".pdf")
        }

        /// 当前内容是否为视频文档（复用图片内容通道，但不经缓存）。
        public var isVideoDocument: Bool {
            guard let name = originalImageName else { return false }
            return Self.isVideoFileName(name)
        }

        /// 当前内容是否为音频文档（复用图片内容通道，但不经缓存）。
        public var isAudioDocument: Bool {
            if extensionSession?.providerID == "audio.hifi",
               extensionSession?.mediaPlayback != nil { return true }
            if fileList?.kind == .audio { return true }
            if let url = imageURL, Self.isAudioFileName(url.lastPathComponent) { return true }
            guard let name = originalImageName else { return false }
            return Self.isAudioFileName(name)
        }

        /// 视频或音频：均引用原始文件并依赖安全范围书签。
        public var isExternalMediaDocument: Bool {
            isVideoDocument || isAudioDocument
        }

        /// 内置音频与 Hi-Fi 扩展共享封面/元数据呈现时所对应的当前源文件。
        var currentAudioPresentationURL: URL? {
            if fileList?.kind == .audio, let item = fileList?.currentItem {
                return resolvedURL(for: item) ?? item.url
            }
            guard let session = extensionSession, session.providerID == "audio.hifi" else {
                return isAudioDocument ? imageURL : nil
            }
            let resources = session.request.resources
            guard let queue = session.playbackQueue,
                  let currentID = queue.currentItemID else {
                return session.request.primaryFileURL
            }
            let sourceIndex = currentID.hasPrefix("file:")
                ? Int(currentID.dropFirst("file:".count))
                : queue.items.firstIndex(where: { $0.id == currentID })
            guard let index = sourceIndex,
                  resources.indices.contains(index) else {
                return session.request.primaryFileURL
            }
            return resources[index].url
        }

        /// 按扩展名判断是否属于视频类型；仅作快速预筛，实际能否播放需在打开时验证。
        public static func isVideoFileName(_ name: String) -> Bool {
            let ext = (name as NSString).pathExtension.lowercased()
            guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
            return type.conforms(to: .movie)
        }

        public static func isVideoFile(url: URL) -> Bool {
            isVideoFileName(url.lastPathComponent)
        }

        /// 按扩展名判断是否属于系统音频类型；影片文件不视为音频。
        public static func isAudioFileName(_ name: String) -> Bool {
            let ext = (name as NSString).pathExtension.lowercased()
            guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
            if type.conforms(to: .movie) { return false }
            return type.conforms(to: .audio)
        }

        public static func isAudioFile(url: URL) -> Bool {
            isAudioFileName(url.lastPathComponent)
        }

        public static func isExternalMediaFileName(_ name: String) -> Bool {
            isVideoFileName(name) || isAudioFileName(name)
        }

        public static func isExternalMediaFile(url: URL) -> Bool {
            isExternalMediaFileName(url.lastPathComponent)
        }

        /// 为视频/音频原始文件创建安全范围书签，用于跨进程生命周期保留沙盒访问授权。
        public static func makeSecurityScopedBookmark(for url: URL) -> Data? {
            try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        }

        /// 解析视频安全范围书签并校验文件仍存在；返回解析后的 URL（文件移动后可解析到新路径）。
        /// 仅在内部临时持有访问授权完成存在性检查，不会长期占用授权。
        public static func resolveVideoBookmark(_ bookmark: Data) -> URL? {
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                bookmarkDataIsStale: &isStale
            ) else { return nil }
            // 重启后尚未持有授权，fileExists 需在安全范围内检查才准确
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
}
