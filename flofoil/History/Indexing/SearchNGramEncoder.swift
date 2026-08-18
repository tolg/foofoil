import Foundation

nonisolated enum SearchNGramEncoder {
    static func titleTerms(_ normalized: String) -> String {
        let characters = Array(normalized.filter { !$0.isWhitespace })
        return (characters.map { "t1x" + hex(String($0)) } + grams(characters).map { "t2x" + hex($0) }).joined(separator: " ")
    }

    static func bodyTerms(_ normalized: String) -> String {
        grams(Array(normalized.filter { !$0.isWhitespace })).map { "b2x" + hex($0) }.joined(separator: " ")
    }

    static func matchExpression(for keyword: String) -> String? {
        let characters = Array(keyword.filter { !$0.isWhitespace })
        guard !characters.isEmpty else { return nil }
        if characters.count == 1 {
            return "title_terms:t1x\(hex(String(characters[0])))"
        }
        // detail=column 不支持短语查询；编码 token 不含分词符，可直接作为单 token 查询。
        let title = grams(characters).map { "title_terms:t2x\(hex($0))" }.joined(separator: " AND ")
        let body = grams(characters).map { "body_terms:b2x\(hex($0))" }.joined(separator: " AND ")
        return "(\(title)) OR (\(body))"
    }

    private static func grams(_ characters: [Character]) -> [String] {
        guard characters.count >= 2 else { return [] }
        return (0..<(characters.count - 1)).map { String(characters[$0...($0 + 1)]) }
    }

    private static func hex(_ value: String) -> String {
        value.utf8.map { String(format: "%02x", $0) }.joined()
    }
}
