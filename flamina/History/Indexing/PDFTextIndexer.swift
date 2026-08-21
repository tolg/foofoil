import Foundation
import PDFKit
import AppKit

enum PDFTextIndexer {
    static func extract(url: URL, isCancelled: () -> Bool) throws -> [(String, Int?)] {
        guard let document = PDFDocument(url: url), document.pageCount > 0 else { return [] }
        let samples = samplePages(count: document.pageCount)
        let textSamples = samples.compactMap { document.page(at: $0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) }
        let isTextPDF = textSamples.filter { $0.count >= 40 }.count >= min(2, samples.count)
        if !isTextPDF {
            guard let page = document.page(at: 0) else { return [] }
            let box = page.bounds(for: .mediaBox)
            let scale = min(2, 2200 / max(box.width, box.height))
            let image = page.thumbnail(of: NSSize(width: box.width * scale, height: box.height * scale), for: .mediaBox)
            guard let data = image.tiffRepresentation,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return [] }
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("flamina-pdf-cover-\(UUID().uuidString).png")
            guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL, "public.png" as CFString, 1, nil) else { return [] }
            CGImageDestinationAddImage(destination, cgImage, nil)
            CGImageDestinationFinalize(destination)
            defer { try? FileManager.default.removeItem(at: temporary) }
            return [(try ImageOCRIndexer.recognize(url: temporary), 1)]
        }

        var chunks: [(String, Int?)] = []
        for index in 0..<document.pageCount {
            if isCancelled() { break }
            if let text = document.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                chunks.append((text, index + 1))
            }
        }
        return chunks
    }

    private static func samplePages(count: Int) -> [Int] {
        Array(Set([0, min(1, count - 1), count / 4, count / 2, max(0, count - 2), count - 1])).sorted()
    }
}
