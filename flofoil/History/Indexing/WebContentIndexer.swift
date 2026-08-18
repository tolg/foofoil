import Foundation

enum WebContentIndexer {
    static let maximumLength = 2_000_000

    static func sanitize(_ text: String) -> String {
        let cleaned = text.unicodeScalars.filter { !CharacterSet.controlCharacters.subtracting(.newlines).contains($0) }.map(String.init).joined()
        return String(cleaned.prefix(maximumLength))
    }
}
