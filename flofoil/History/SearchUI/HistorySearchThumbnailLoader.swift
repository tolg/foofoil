import AppKit
import Combine
import ImageIO

@MainActor
final class HistorySearchThumbnailLoader: ObservableObject {
    private static let cache = NSCache<NSString, NSImage>()
    @Published var image: NSImage?

    func load(path: String?) async {
        guard let path else { image = nil; return }
        if let cached = Self.cache.object(forKey: path as NSString) { image = cached; return }
        let loaded = await Task.detached(priority: .utility) { () -> NSImage? in
            // 如果已经是生成好的 HEIC 缩略图文件，则直接加载，无需现场进行高开销的裁剪缩放计算
            if path.lowercased().hasSuffix(".heic") {
                if let img = NSImage(contentsOfFile: path) {
                    return img
                }
            }
            
            // 保底方案：如果是原图路径，则按原逻辑动态生成缩略图以做兼容
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                  let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 128,
                    kCGImageSourceCreateThumbnailWithTransform: true
                  ] as CFDictionary) else { return nil }
            return NSImage(cgImage: cgImage, size: .zero)
        }.value
        if let loaded {
            Self.cache.setObject(loaded, forKey: path as NSString)
            image = loaded
        }
    }
}
