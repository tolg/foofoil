import AppKit
import Combine
import ImageIO

private actor ThumbnailDecodeLimiter {
    private let limit: Int
    private var activeCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
    }

    func acquire() async {
        if activeCount < limit {
            activeCount += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            activeCount -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

@MainActor
final class HistorySearchThumbnailLoader: ObservableObject {
    private static let decodeLimiter = ThumbnailDecodeLimiter(limit: 2)
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        // 128 px RGBA 缩略图约 64 KB；双重限制避免长列表让缓存无界增长。
        cache.countLimit = 160
        cache.totalCostLimit = 12 * 1024 * 1024
        return cache
    }()
    @Published var image: NSImage?

    func load(path: String?) async {
        guard let path else { image = nil; return }
        if let cached = Self.cache.object(forKey: path as NSString) { image = cached; return }
        image = nil
        // 快速滚动时限制并行解码数，避免可见行瞬间争抢 CPU 与文件 I/O。
        await Self.decodeLimiter.acquire()
        if Task.isCancelled {
            await Self.decodeLimiter.release()
            return
        }
        let loaded = await Task.detached(priority: .utility) { () -> NSImage? in
            guard !Task.isCancelled else { return nil }
            let url = URL(fileURLWithPath: path)
            // SVG 保留矢量表示；栅格图直接按目标尺寸解码，避免把列表中的原图展开进内存。
            if url.pathExtension.lowercased() == "svg" {
                return NSImage(contentsOf: url)
            }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [
                    kCGImageSourceShouldCache: false
                  ] as CFDictionary),
                  let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 128,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { return nil }
            return NSImage(cgImage: cgImage, size: .zero)
        }.value
        await Self.decodeLimiter.release()
        guard !Task.isCancelled else { return }
        if let loaded {
            let pixelCost = max(1, Int(loaded.size.width * loaded.size.height * 4))
            Self.cache.setObject(loaded, forKey: path as NSString, cost: pixelCost)
            image = loaded
        }
    }
}
