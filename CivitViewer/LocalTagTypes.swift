import Foundation

/// A site-wide read cooldown has no retry loop and admits no request while
/// blocked. A successful concurrent response must not clear a newer 429.
@MainActor final class SiteRequestCooldown {
    static let shared = SiteRequestCooldown(defaults: .standard)
    private(set) var retryAvailableAt: Date?
    private var failures: Int
    private let defaults: UserDefaults?
    private let now: () -> Date
    init(defaults: UserDefaults? = nil, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults; self.now = now
        retryAvailableAt = defaults?.object(forKey: "siteReadCooldownUntil57") as? Date
        failures = min(4, max(0, defaults?.integer(forKey: "siteRead429Count57") ?? 0))
    }
    func check() throws {
        if let retryAvailableAt, retryAvailableAt > now() { throw ClientError.http(429) }
    }
    func performRead<T>(_ load: () async throws -> T) async throws -> T {
        try check()
        return try await load()
    }
    func validateResponse(status: Int, retryAfter: String? = nil, rpcError: Any? = nil, markSuccess: Bool = true) throws {
        var effective = status
        if status == 200, let rpcError {
            let root = rpcError as? [String: Any] ?? [:]
            let error = root["json"] as? [String: Any] ?? root
            let value = (error["data"] as? [String: Any])?["httpStatus"] as? Int
            effective = value.flatMap { (100...599).contains($0) ? $0 : nil } ?? 400
        }
        if effective == 429 { record429(retryAfter: retryAfter) }
        if effective == 401 { throw ClientError.signedOut }
        guard effective == 200 else { throw ClientError.http(effective) }
        if markSuccess { recordSuccess() }
    }
    func record429(retryAfter: String?) {
        let instant = now()
        var deadline: Date?
        if let text = retryAfter?.trimmingCharacters(in: .whitespacesAndNewlines), text.count <= 64 {
            if let seconds = TimeInterval(text), seconds.isFinite, seconds >= 0, seconds <= 31_536_000 {
                deadline = instant.addingTimeInterval(seconds)
            } else {
                let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX")
                format.timeZone = TimeZone(secondsFromGMT: 0); format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                deadline = format.date(from: text)
            }
        }
        let fallback = instant.addingTimeInterval(min(3600, 300 * pow(2, Double(failures))))
        let next = max(instant.addingTimeInterval(30), deadline ?? fallback)
        retryAvailableAt = max(retryAvailableAt ?? .distantPast, next)
        failures = min(4, failures + 1)
        defaults?.set(retryAvailableAt, forKey: "siteReadCooldownUntil57")
        defaults?.set(failures, forKey: "siteRead429Count57")
    }
    func recordSuccess() {
        guard retryAvailableAt.map({ $0 <= now() }) ?? true else { return }
        retryAvailableAt = nil; failures = 0
        defaults?.removeObject(forKey: "siteReadCooldownUntil57")
        defaults?.removeObject(forKey: "siteRead429Count57")
    }
}

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
