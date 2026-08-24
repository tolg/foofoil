import Foundation

public enum HistoryDatabaseError: LocalizedError {
    case open(String)
    case execute(String)
    case prepare(String)
    case bind(String)
    case unavailableFTS5

    public var errorDescription: String? {
        switch self {
        case .open(let message): return "无法打开历史数据库：\(message)"
        case .execute(let message): return "历史数据库执行失败：\(message)"
        case .prepare(let message): return "历史数据库语句准备失败：\(message)"
        case .bind(let message): return "历史数据库参数绑定失败：\(message)"
        case .unavailableFTS5: return "当前系统 SQLite 不支持 FTS5，历史搜索无法启用。"
        }
    }
}
