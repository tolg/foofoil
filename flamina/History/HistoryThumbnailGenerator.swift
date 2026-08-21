//
//  HistoryThumbnailGenerator.swift
//  flamina
//
//  Created by tolg on 2026/7/15.
//

import Foundation
import AppKit
import AVFoundation
import PDFKit
import ImageIO

/// 历史记录缩略图生成器，支持将图片与 PDF 生成为正方形的 HEIC 缩略图
public enum HistoryThumbnailGenerator {

    /// 生成缩略图并保存到指定路径
    /// - Parameters:
    ///   - url: 原文件路径（图片或 PDF）
    ///   - kind: 历史内容类型
    ///   - destinationURL: 缩略图保存的目标 HEIC 路径
    /// - Returns: 生成并保存成功返回 true，否则返回 false
    public static func generateThumbnail(for url: URL, kind: HistoryContentKind, destinationURL: URL) -> Bool {
        var finalImage: CGImage? = nil

        switch kind {
        case .image:
            // 使用 CGImageSource 快速载入，设置最大宽高为 512，避免将超大原图完全加载进内存
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 512,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            if let mediumCGImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                // 裁剪为正方形并缩放到 128x128 像素
                finalImage = cropAndResize(mediumCGImage, to: 128)
            }

        case .pdf:
            // 提取 PDF 的第一页并转成 CGImage
            guard let document = PDFDocument(url: url), document.pageCount > 0,
                  let page = document.page(at: 0) else { return false }
            let box = page.bounds(for: .mediaBox)
            // 先按比例限制最大边为 256 生成一张稍微大一点的页面图以提供裁剪余量
            let scale = 256.0 / max(box.width, box.height)
            let size = NSSize(width: box.width * scale, height: box.height * scale)
            let nsImage = page.thumbnail(of: size, for: .mediaBox)
            if let tiffData = nsImage.tiffRepresentation,
               let source = CGImageSourceCreateWithData(tiffData as CFData, nil),
               let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                // 裁剪为正方形并缩放到 128x128 像素
                finalImage = cropAndResize(cgImage, to: 128)
            }

        case .video:
            // 视频引用原始文件且不做 OCR；取首帧画面作为缩略图
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 512, height: 512)
            // 当前调用位于后台索引队列，可用信号量同步等待异步取帧结果
            let semaphore = DispatchSemaphore(value: 0)
            var generatedImage: CGImage?
            generator.generateCGImageAsynchronously(for: .zero) { cgImage, _, _ in
                generatedImage = cgImage
                semaphore.signal()
            }
            semaphore.wait()
            if let cgImage = generatedImage {
                finalImage = cropAndResize(cgImage, to: 128)
            }

        case .audio:
            // 音频缩略图优先使用内嵌封面，其次同目录匹配的封面图
            let info = AudioMetadataLoader.loadSynchronously(from: url)
            if let artwork = info.artwork,
               let cgImage = artwork.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                finalImage = cropAndResize(cgImage, to: 128)
            }

        default:
            return false
        }

        guard let image = finalImage else { return false }

        // 确保目标的父级目录存在
        let directory = destinationURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // 使用 HEIC 格式写入目标文件
        guard let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL, "public.heic" as CFString, 1, nil) else {
            return false
        }

        // 设置 HEIC 质量为 70%
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.70
        ]

        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    /// 将 CGImage 居中裁剪为正方形，并使用高插值质量缩放到 targetSize × targetSize 像素
    private static func cropAndResize(_ image: CGImage, to targetSize: Int) -> CGImage? {
        let width = image.width
        let height = image.height
        let size = min(width, height)
        let x = (width - size) / 2
        let y = (height - size) / 2

        // 居中裁剪出正方形区域
        guard let cropped = image.cropping(to: CGRect(x: x, y: y, width: size, height: size)) else { return nil }

        // 缩放到目标大小
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: targetSize,
            height: targetSize,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            // HEIC 缩略图不需要透明度；使用无 Alpha 的 RGBX 位图可避免编码器额外分配 Alpha 通道。
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: targetSize, height: targetSize))
        return context.makeImage()
    }
}
