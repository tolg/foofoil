import Foundation

nonisolated enum TextContentIndexer {
    private static let targetSize = 24 * 1024

    static func chunk(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var chunks: [String] = []
        var current = ""
        for paragraph in text.components(separatedBy: .newlines) {
            let addition = current.isEmpty ? paragraph : "\n" + paragraph
            if current.utf8.count + addition.utf8.count > targetSize, !current.isEmpty {
                chunks.append(current)
                current = paragraph
            } else {
                current += addition
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
