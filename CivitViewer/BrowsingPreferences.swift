import Foundation
import Combine

@MainActor final class TagBlocklist: ObservableObject {
    static let shared = TagBlocklist()
    @Published private(set) var names: Set<String>
    private let defaults: UserDefaults
    private let key = "blockedMediaTags.v1"
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let initial = Set((defaults.stringArray(forKey: key) ?? []).map(TagPolicy.normalize).filter { !$0.isEmpty })
        names = initial
    }
    @discardableResult func add(_ raw: String) -> Bool {
        let value = TagPolicy.normalize(raw)
        guard !value.isEmpty, value.count <= 80, names.count < 100 || names.contains(value) else { return false }
        names.insert(value); save(); return true
    }
    func remove(_ name: String) { names.remove(TagPolicy.normalize(name)); save() }
    private func save() { defaults.set(names.sorted(), forKey: key) }
}

enum RecentPublication: Int, CaseIterable, Identifiable {
    case any = 0, day = 1, week = 7, month = 30, quarter = 90
    var id: Self { self }
    var title: String { switch self { case .any: "不限时间"; case .day: "近 24 小时"; case .week: "近 7 天"; case .month: "近 30 天"; case .quarter: "近 90 天" } }
    func includes(_ date: Date, now: Date = Date()) -> Bool {
        date <= now && (self == .any || date >= now.addingTimeInterval(-Double(rawValue) * 86_400))
    }
}

enum PublicationResult: Equatable {
    case published(Date), noVisibleWorks, unverified
}

struct PublicationCursor: Codable, Hashable {
    private let text: String?
    private let number: Int?
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let text = try? value.decode(String.self) { self.text = text; number = nil }
        else { text = nil; number = try value.decode(Int.self) }
    }
    var value: Any { if let text { return text }; return number ?? 0 }
    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        if let text { try value.encode(text) } else { try value.encode(number ?? 0) }
    }
}

struct PublicationPage: Decodable {
    let items: [Post]
    let nextCursor: PublicationCursor?
    struct Post: Decodable {
        let id: Int
        let publishedAt: String?
        let user: User
        let images: [Media]
        struct User: Decodable { let id: Int }
        struct Media: Decodable { let type: String? }
        var hasVisualMedia: Bool { images.contains { $0.type == "image" || $0.type == "video" } }
        var hasUnknownMedia: Bool { images.contains { !["image", "video", "audio"].contains($0.type ?? "") } }
        var publicationDate: Date? {
            guard let publishedAt else { return nil }
            let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return fractional.date(from: publishedAt) ?? ISO8601DateFormatter().date(from: publishedAt)
        }
    }
}

struct PublicationScan {
    let creatorID: Int
    private var previous: Date?
    private var seen = Set<PublicationCursor>()
    init(creatorID: Int) { self.creatorID = creatorID }
    mutating func consume(_ page: PublicationPage, now: Date = Date()) -> PublicationResult? {
        for post in page.items {
            guard post.user.id == creatorID, let date = post.publicationDate, date <= now,
                  previous.map({ date <= $0 }) ?? true, !post.hasUnknownMedia else { return .unverified }
            previous = date
            if post.hasVisualMedia { return .published(date) }
        }
        guard let cursor = page.nextCursor else { return .noVisibleWorks }
        guard seen.insert(cursor).inserted else { return .unverified }
        return nil
    }
}

@MainActor protocol PublicationSource: AnyObject {
    var feedIdentity: String { get }
    func latestPublication(creator: Creator) async throws -> PublicationResult
}

/// Explicit, progressive coverage: at most 40 authors and 3 reads concurrently
/// per user batch. Unknown authors stay visible in their own section.
@MainActor final class CreatorActivityStore: ObservableObject {
    struct Check { let result: PublicationResult; let checkedAt: Date }
    @Published private(set) var checks: [Int: Check] = [:]
    @Published private(set) var busy = false
    private var identity: String?
    private var revision = 0
    private let lifetime: TimeInterval = 600
    func bind(identity: String) {
        guard self.identity != identity else { return }
        revision += 1; self.identity = identity; checks = [:]; busy = false
    }
    func result(for id: Int, now: Date = Date()) -> PublicationResult? {
        guard let check = checks[id], now.timeIntervalSince(check.checkedAt) < lifetime else { return nil }
        return check.result
    }
    func checkNext(_ creators: [Creator], source: any PublicationSource, retryUnknown: Bool = false) async {
        bind(identity: source.feedIdentity)
        guard !busy else { return }
        let targets = Array(creators.filter {
            let result = result(for: $0.id)
            return result == nil || (retryUnknown && result == .unverified)
        }.prefix(40))
        guard !targets.isEmpty else { return }
        busy = true; let generation = revision
        defer { if generation == revision { busy = false } }
        await withTaskGroup(of: (Int, PublicationResult).self) { group in
            var iterator = targets.makeIterator()
            func enqueue(_ creator: Creator) {
                group.addTask {
                    do { return (creator.id, try await source.latestPublication(creator: creator)) }
                    catch { return (creator.id, .unverified) }
                }
            }
            for _ in 0..<3 { if let creator = iterator.next() { enqueue(creator) } }
            while let (id, result) = await group.next() {
                guard !Task.isCancelled, generation == revision, identity == source.feedIdentity else { group.cancelAll(); return }
                checks[id] = .init(result: result, checkedAt: Date())
                if let creator = iterator.next() { enqueue(creator) }
            }
        }
    }
}
