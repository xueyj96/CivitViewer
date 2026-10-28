import Foundation

struct LocalTagCursor: Equatable {
    let context: String
    let name: String
    let id: Int
}
struct LocalTagPage {
    let items: [SearchTag]
    let next: LocalTagCursor?
}
struct TagPrefixWork: Equatable {
    let prefix: String
    let page: Int
    let cycle: Int
}
struct TagLibraryStats {
    var stored = 0
    var visible = 0
    var common = 0
    var completedPrefixes = 0
    var trackedPrefixes = 36
    var lastCommonSync: Date?
    var lastSuccessfulSync: Date?
    var bytes: Int64 = 0
}
enum LocalTagError: LocalizedError {
    case database, capacity, invalidPage, repeatedPage, contextChanged, incompatibleSchema
    var errorDescription: String? {
        switch self {
        case .database: "本地标签库暂时无法读取，请重试；已有数据库保留。"
        case .capacity: "标签库达到独立存储上限，已暂停同步；已有标签仍可查询。"
        case .invalidPage: "站点标签分页范围不符，已保留当前同步位置。"
        case .repeatedPage: "站点返回重复标签页，已暂停这个前缀，稍后可重试。"
        case .contextChanged: "标签库上下文已变化，请重新读取。"
        case .incompatibleSchema: "标签库来自其他版本，暂时无法读取；原文件保留。"
        }
    }
}
