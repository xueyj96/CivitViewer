import Foundation

enum MediaKind: String, CaseIterable, Codable, Identifiable {
    case image, all, video
    var id: Self { self }
    var title: String { chineseTitle }
    var chineseTitle: String { switch self { case .all: "全部"; case .image: "图片"; case .video: "视频" } }
}

enum FilterContext { case discovery, following, creator }

enum FeedPeriod: String, CaseIterable, Identifiable {
    case day = "Day", week = "Week", month = "Month", year = "Year", allTime = "AllTime"
    var id: Self { self }
    var title: String { switch self { case .day: "今日"; case .week: "本周"; case .month: "本月"; case .year: "今年"; case .allTime: "全部时间" } }
}

enum FeedSort: String, CaseIterable, Identifiable {
    case reactions = "Most Reactions", newest = "Newest", comments = "Most Comments", collected = "Most Collected"
    var id: Self { self }
    var title: String { switch self { case .reactions: "热度"; case .newest: "最新"; case .comments: "最多评论"; case .collected: "最多收藏" } }
}

struct FeedFilter: Codable, Equatable {
    var kind: MediaKind = .all
    var sort = "Most Reactions"
    var period = "Week"
    var baseModel = ""
    var onlyPG = false
    var videoDurationRange: VideoDurationRange? = nil
    var effectiveKind: MediaKind { videoDurationRange == nil ? kind : .video }
    func selecting(kind: MediaKind) -> FeedFilter {
        var value = self; value.kind = kind
        if kind != .video { value.videoDurationRange = nil }
        return value
    }
    func resetting(in context: FilterContext) -> FeedFilter { .defaults(for: context, kind: kind) }

    static func defaults(for context: FilterContext, kind: MediaKind = .all) -> FeedFilter {
        switch context {
        case .discovery: FeedFilter(kind: kind)
        case .following, .creator: FeedFilter(kind: kind, sort: "Newest", period: "AllTime")
        }
    }
    var periodTitle: String { FeedPeriod(rawValue: period)?.title ?? period }
    var sortTitle: String { FeedSort(rawValue: sort)?.title ?? sort }
    var summary: String {
        ([effectiveKind.title, periodTitle, sortTitle] + (baseModel.isEmpty ? [] : [baseModel]) + (onlyPG ? ["仅看 PG"] : []) + (videoDurationRange.map { ["视频 " + $0.summary] } ?? [])).joined(separator: " · ")
    }

    static func saved(followed: Bool = false) -> FeedFilter {
        if let data = UserDefaults.standard.data(forKey: followed ? "defaultFollowingFilter" : "defaultDiscoveryFilter"),
           let value = try? JSONDecoder().decode(FeedFilter.self, from: data) { return value }
        return defaults(for: followed ? .following : .discovery)
    }
    func saveDefault(followed: Bool) {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: followed ? "defaultFollowingFilter" : "defaultDiscoveryFilter")
        }
    }

    func query(cursor: String? = nil, creator: Creator? = nil) -> [URLQueryItem] {
        var q = [URLQueryItem(name: "limit", value: "20"),
                 URLQueryItem(name: "sort", value: sort),
                 URLQueryItem(name: "period", value: period)]
        if effectiveKind != .all { q.append(.init(name: "type", value: effectiveKind.rawValue)) }
        if !baseModel.isEmpty { q.append(.init(name: "baseModels", value: baseModel)) }
        if onlyPG { q.append(.init(name: "browsingLevel", value: "1")) }
        if let creator { q.append(.init(name: "username", value: creator.username)) }
        if let cursor { q.append(.init(name: "cursor", value: cursor)) }
        return q
    }
}

struct Creator: Decodable, Identifiable, Hashable {
    let id: Int
    let username: String
    var image: String?
}

/// Navigation carries the actual work's media type, independent of feed filters.
struct CreatorRoute: Identifiable, Hashable {
    let creator: Creator
    let kind: MediaKind
    var id: String { "\(creator.id):\(kind.rawValue)" }
    init(creator: Creator, item: MediaItem) {
        self.creator = creator; kind = item.isVideo ? .video : .image
    }
}

struct Account: Decodable, Equatable {
    let id: Int
    let username: String
    let browsingLevel: Int?
    let blurNsfw: Bool?
}

struct MediaItem: Decodable, Identifiable, Hashable {
    let id: Int
    let url: String
    let width: Int?
    let height: Int?
    var type: String?
    let username: String?
    let browsingLevel: Int?
    let thumbnail: Thumbnail?
    var creatorID: Int?
    var tags: [MediaTag]? = nil
    var postID: Int? = nil
    var metadata: VideoTechnicalMetadata? = nil
    var durationSeconds: Double? { metadata?.duration }
    // Assigned only by the local library, never decoded from a remote response.
    var offlineMediaURL: URL? = nil
    var offlinePosterURL: URL? = nil
    private enum CodingKeys: String, CodingKey { case id, url, width, height, type, username, browsingLevel, thumbnail, creatorID, tags, metadata; case postID = "postId" }
    struct Thumbnail: Decodable, Hashable { let url: String? }
    var isVideo: Bool { type == "video" }
    /// Viewer/history interpretation after decoding. Catalog filtering and
    /// network requests retain the server's original item/type.
    func resolvingMediaType(isVideo: Bool) -> MediaItem {
        var copy = self; copy.type = isVideo ? "video" : "image"; return copy
    }
    var isSupported: Bool { type == "image" || type == "video" || type == nil }
    var tagNames: Set<String>? {
        guard let tags, tags.allSatisfy({ $0.name.map { !TagPolicy.normalize($0).isEmpty } ?? false }) else { return nil }
        return Set(tags.compactMap(\.name).map(TagPolicy.normalize))
    }
    var mediaAssetKey: String? {
        let mediaType: String
        guard isSupported else { return nil }
        mediaType = isVideo ? "video" : "image"
        guard let address = Self.httpsURL(url) else { return nil }
        if address.host?.lowercased() == "image.civitai.com",
           let uuid = address.pathComponents.first(where: { UUID(uuidString: $0) != nil }) {
            return "civitai:\(mediaType):\(uuid.lowercased())"
        }
        return "url:\(mediaType):\(address.absoluteString)"
    }
    var mediaURL: URL? { offlineMediaURL ?? Self.httpsURL(url) }
    var posterURL: URL? { offlinePosterURL ?? Self.httpsURL(thumbnail?.url) }
    static func httpsURL(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw), url.scheme == "https", url.host != nil else { return nil }
        return url
    }
}

struct MediaTag: Decodable, Hashable { var id: Int? = nil; var name: String? = nil }

enum TagVerdict: Equatable { case allowed, blocked, unverified }
enum TagPolicy {
    static func normalize(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCompatibilityMapping.lowercased()
    }
    static func verdict(names: Set<String>?, blocked: Set<String>) -> TagVerdict {
        guard !blocked.isEmpty else { return .allowed }
        guard let names else { return .unverified }
        return names.isDisjoint(with: blocked) ? .allowed : .blocked
    }
}

enum VideoFailure: Equatable {
    case http(Int), decoderMissing, localMissing, network, unknown
}
enum VideoRecoveryDecision: Equatable { case wait, recover, skip, manualRetry }
enum VideoRecoveryPolicy {
    static func decide(failed: Bool, failure: VideoFailure, recoveryAttempted: Bool) -> VideoRecoveryDecision {
        guard failed else { return .wait } // Waiting/loading/buffering are never terminal.
        if failure == .http(401) || failure == .http(429) { return .manualRetry }
        if failure == .localMissing { return .skip }
        guard recoveryAttempted else { return .recover }
        return .skip // A confirmed failed retry may try another work, without deleting this one.
    }
}

struct PlaybackAdvanceState {
    static let maximumFollowingAttempts = 3
    private(set) var consecutive = 0
    private var handled = Set<Int>()
    private var automaticTarget: Int?
    func canAdvance(failedID: Int, focused: Int?, active: Bool) -> Bool {
        active && focused == failedID && !handled.contains(failedID) && consecutive < Self.maximumFollowingAttempts
    }
    mutating func target(failedID: Int, focused: Int?, ids: [Int], active: Bool) -> Int? {
        guard canAdvance(failedID: failedID, focused: focused, active: active),
              let index = ids.firstIndex(of: failedID), ids.indices.contains(index + 1) else { return nil }
        let target = ids[index + 1]
        handled.insert(failedID); consecutive += 1; automaticTarget = target
        return target
    }
    mutating func focusChanged(_ id: Int?) {
        if automaticTarget == id { automaticTarget = nil }
        else { consecutive = 0; handled = []; automaticTarget = nil }
    }
}

/// One requested destination, owned by a user swipe or bounded playback recovery.
/// Appending a page alone creates no intent.
struct MediaContinuationIntent: Equatable {
    enum Cause: Equatable { case userSwipe, failedPlayback }
    let anchorID: Int
    let context: String
    var cause: Cause = .userSwipe
    var targetID: Int? = nil

    func target(focused: Int?, ids: [Int], context: String, active: Bool) -> Int? {
        guard active, self.context == context, focused == anchorID,
              let index = ids.firstIndex(of: anchorID), ids.indices.contains(index + 1) else { return nil }
        return ids[index + 1]
    }
}

enum MediaFocusPolicy {
    static func target(current: Int?, previousIDs: [Int], ids: [Int]) -> Int? {
        guard !ids.isEmpty else { return nil }
        if current == -1 {
            let previous = Set(previousIDs)
            return ids.first(where: { !previous.contains($0) }) ?? -1
        }
        let available = Set(ids)
        if let current, available.contains(current) { return current }
        guard let current, let index = previousIDs.firstIndex(of: current) else { return ids.first }
        return previousIDs.dropFirst(index + 1).first(where: { available.contains($0) }) ?? ids.last
    }

    static func target(current: Int?, previousItems: [MediaItem], items: [MediaItem]) -> Int? {
        let availableIDs = Set(items.map(\.id))
        if let current, availableIDs.contains(current) { return current }
        if let current,
           let previous = previousItems.first(where: { $0.id == current }),
           let asset = previous.mediaAssetKey,
           let replacement = items.first(where: { $0.mediaAssetKey == asset }) {
            return replacement.id
        }
        return target(current: current, previousIDs: previousItems.map(\.id), ids: items.map(\.id))
    }
}

struct SearchScanProgress: Codable {
    let pages: Int
    let candidates: Int
    let matches: Int
    let anchorTagID: Int
}
struct MediaPage: Decodable {
    let items: [MediaItem]
    let metadata: Metadata
    var searchProgress: SearchScanProgress? = nil
    var durationEnrichmentFailed = false
    // Local request evidence only; never decoded from the site's media payload.
    var durationEnrichmentHTTPStatus: Int? = nil
    private enum CodingKeys: String, CodingKey { case items, metadata, searchProgress }
    struct Metadata: Decodable { let nextCursor: String?; var sourceIDs: [Int]? = nil }
}

struct LeaderboardEntry: Decodable, Identifiable {
    let position: Int
    let user: Creator
    var id: Int { user.id }
}

enum Board: String, CaseIterable, Identifiable {
    case legacy, seasonal
    var id: Self { self }
    var title: String { self == .legacy ? "Legacy" : "Seasonal" }
    var procedure: String { self == .legacy ? "leaderboard.getLeadboardLegends" : "leaderboard.getLeaderboard" }
    var webValue: String { self == .legacy ? "legend" : "season" }
}

enum ClientError: LocalizedError {
    case signedOut, loadingSite, http(Int), invalidResponse, missingCreator, writeUnknown, siteUnavailable, accountChanged, format(String), collectionAuthorization, collectionWriteUnknown, collectionBusy
    var errorDescription: String? {
        switch self {
        case .signedOut: "请先登录 Civitai，再刷新账号状态。"
        case .loadingSite: "请先完成或关闭登录窗口。"
        case .http(429): "站点请求过于频繁（429），已进入冷却，请稍后重试。"
        case .http(let status): "站点返回 HTTP \(status)，请稍后重试。"
        case .invalidResponse: "站点返回的数据格式暂不支持。"
        case .missingCreator: "暂时无法确认这位作者的账号。"
        case .writeUnknown: "关注结果待确认，请先刷新关注状态。"
        case .siteUnavailable: "暂时无法连接 civitai.red，请打开登录窗口检查站点。"
        case .accountChanged: "账号已变更，请刷新账号后重新操作。"
        case .format(let path): "站点数据字段暂不匹配（\(path)）。"
        case .collectionAuthorization: "收藏需要补充 Civitai 收藏读取与管理授权。现有登录仍可继续浏览。"
        case .collectionWriteUnknown: "收藏结果尚未确认，请刷新收藏状态后再操作。"
        case .collectionBusy: "正在同步另一项收藏，请稍候。"
        }
    }
}

/// Civitai treats both images and videos as CollectionType.Image.
struct SavedCollection: Codable, Identifiable, Hashable {
    let id: Int
    let name: String
    let userId: Int
    let type: String?
    let mode: String?
    let read: String
    var privacyTitle: String {
        switch read { case "Private": "私密"; case "Unlisted": "不公开列出"; case "Public": "公开"; default: read }
    }
    func isPersonalMedia(actorID: Int) -> Bool {
        userId == actorID && (type == nil || type == "Image") && mode != "Contest"
    }
}

enum OfflineCloudState: String, Codable { case saved, localOnly, unknown }
enum OfflineFileState: String, Codable { case pending, ready, failed }

/// Deliberately no URL, token, cookie or request headers in the persistent index.
struct OfflineRecord: Codable, Identifiable, Hashable {
    let id: Int
    var video: Bool
    var username: String?
    var creatorID: Int?
    var browsingLevel: Int?
    var collectionIDs: Set<Int>
    var cloudState: OfflineCloudState
    var fileState: OfflineFileState = .pending
    var bytes: Int64 = 0
    var savedAt: Date?
    var lastOpenedAt: Date?
    var checkedAt: Date?
    var tagNames: Set<String>? = nil
    var fileName: String { "\(id)." + (video ? "mp4" : "img") }
    var posterName: String { "\(id).poster.img" }
    func media(in directory: URL) -> MediaItem {
        var item = MediaItem(id: id, url: "", width: nil, height: nil, type: video ? "video" : "image", username: username, browsingLevel: browsingLevel, thumbnail: nil, creatorID: creatorID)
        item.offlineMediaURL = directory.appendingPathComponent(fileName)
        item.tags = tagNames.map { $0.sorted().map { MediaTag(name: $0) } }
        let poster = directory.appendingPathComponent(posterName)
        if video && FileManager.default.fileExists(atPath: poster.path) { item.offlinePosterURL = poster }
        return item
    }
}

struct OfflineManifest: Codable {
    var version = 1
    let accountID: Int
    var records: [OfflineRecord] = []
    var omittedIDs = Set<Int>()
    var lastScan: Date?
}

enum OfflineQuota {
    static func downloadBudget(used: Int64, limit: Int64, free: Int64?, reserve: Int64 = 1_000_000_000) -> Int64 {
        let remaining = max(0, max(0, limit) - max(0, used))
        guard let free else { return 0 } // Cannot promise space without a capacity reading.
        return min(remaining, max(0, max(0, free) - max(0, reserve)))
    }
}

struct SavedMembershipUpdate: Equatable {
    var revision = UUID()
    let accountID: Int
    let imageID: Int
    let collectionIDs: Set<Int>
}

struct CollectionMembership: Decodable {
    let collectionId: Int
}

struct CollectionIndexPage: Decodable {
    let collectionItems: [Entry]
    let nextCursor: String?
    struct Entry: Decodable {
        let id: Int
        let type: String
        let data: Resource
        struct Resource: Decodable { let id: Int }
    }
    var mediaIDs: [Int] { collectionItems.filter { $0.type == "image" }.map { $0.data.id } }
}

/// Apply only the user's changed checkboxes; preserve unedited server membership.
struct CollectionSelectionChange {
    let additions: Set<Int>
    let removals: Set<Int>
    init(original: Set<Int>, selected: Set<Int>, editable: Set<Int>, current: Set<Int>) {
        additions = selected.subtracting(original).intersection(editable).subtracting(current)
        removals = original.subtracting(selected).intersection(editable).intersection(current)
    }
    var isEmpty: Bool { additions.isEmpty && removals.isEmpty }
    func isConfirmed(by current: Set<Int>) -> Bool {
        additions.isSubset(of: current) && removals.isDisjoint(with: current)
    }
}

/// Cursor is opaque. An empty page with a cursor does not mean end of feed.
struct FeedAccumulator {
    private(set) var items: [MediaItem] = []
    private(set) var cursor: String?
    private(set) var reachedEnd = false
    private var ids = Set<Int>()
    private var seenSourceIDs = Set<Int>()
    private var mediaAssets = Set<String>()
    private var sourceItems: [MediaItem] = []
    private var repeatedIDs = 0
    private var rescanSeedAssets = Set<String>()
    private var rescanBoundaryID: Int?
    private var rescanBoundaryActive = false
    private(set) var blockedCount = 0
    private(set) var blockedAuthorCount = 0
    private(set) var unverifiedCount = 0
    private(set) var duplicateCount = 0
    private(set) var hiddenByDuration = 0
    private(set) var unverifiedDuration = 0
    var videoDurationRange: VideoDurationRange? = nil
    var blockedTags = Set<String>()
    var deduplicateMediaAssets = false
    private var blockedAuthorIDs = Set<Int>()
    private var blockedAuthorHandles = Set<String>()
    init(keeping items: [MediaItem] = [], blockedTags: Set<String> = [], deduplicateMediaAssets: Bool = false, videoDurationRange: VideoDurationRange? = nil) {
        self.videoDurationRange = videoDurationRange
        sourceItems = items; seenSourceIDs = Set(items.map(\.id))
        self.blockedTags = blockedTags; self.deduplicateMediaAssets = deduplicateMediaAssets
        rebuild()
    }
    mutating func append(_ page: MediaPage, kind: MediaKind = .all) {
        for item in page.items where item.isSupported && item.mediaURL != nil &&
            (kind == .all || (kind == .video ? item.isVideo : !item.isVideo)) {
            if rescanBoundaryActive, item.id == rescanBoundaryID { rescanBoundaryActive = false }
            guard seenSourceIDs.insert(item.id).inserted else { repeatedIDs += 1; continue }
            if rescanBoundaryActive, let asset = item.mediaAssetKey, rescanSeedAssets.contains(asset) {
                repeatedIDs += 1
                continue
            }
            sourceItems.append(item)
        }
        rebuild()
        cursor = page.metadata.nextCursor
        reachedEnd = cursor == nil
    }
    mutating func applyBlockedTags(_ names: Set<String>) { blockedTags = names; rebuild() }
    mutating func applyBlockedAuthors(ids: Set<Int>, handles: Set<String>) {
        blockedAuthorIDs = ids
        blockedAuthorHandles = handles
        rebuild()
    }
    mutating func setDeduplicateMediaAssets(_ value: Bool) {
        deduplicateMediaAssets = value
        rebuild()
    }
    mutating func retainFollowing(_ ids: Set<Int>, current: Int?) {
        sourceItems = sourceItems.filter { item in
            item.id == current || item.creatorID.map { ids.contains($0) } == true
        }
        seenSourceIDs = Set(sourceItems.map(\.id))
        repeatedIDs = 0
        cursor = nil
        reachedEnd = false
        rebuild()
    }
    mutating func restore(_ items: [MediaItem], cursor: String?, reachedEnd: Bool, rescanFromBeginning: Bool = false,
                          rescanBoundaryID: Int? = nil) {
        sourceItems = items.filter { $0.isSupported && $0.mediaURL != nil }
        seenSourceIDs = Set(sourceItems.map(\.id))
        repeatedIDs = 0
        rescanSeedAssets = rescanFromBeginning ? Set(sourceItems.compactMap(\.mediaAssetKey)) : []
        self.rescanBoundaryID = rescanFromBeginning ? (rescanBoundaryID ?? sourceItems.last?.id) : nil
        rescanBoundaryActive = rescanFromBeginning && rescanBoundaryID != nil
        self.cursor = cursor
        self.reachedEnd = reachedEnd
        rebuild()
    }
    mutating func restartContinuation() { cursor = nil; reachedEnd = false }
    var sourceTailID: Int? { sourceItems.last?.id }
    private mutating func rebuild() {
        items = []; ids = []; mediaAssets = []; blockedCount = 0; blockedAuthorCount = 0; unverifiedCount = 0; duplicateCount = repeatedIDs; hiddenByDuration = 0; unverifiedDuration = 0
        for item in sourceItems {
            if let range = videoDurationRange {
                guard item.isVideo else { hiddenByDuration += 1; continue }
                guard item.durationSeconds != nil else { unverifiedDuration += 1; continue }
                guard range.contains(item.durationSeconds) else { hiddenByDuration += 1; continue }
            }
            if AuthorHandlePolicy.blocks(creatorID: item.creatorID, username: item.username,
                                         blockedIDs: blockedAuthorIDs, blockedHandles: blockedAuthorHandles) {
                blockedAuthorCount += 1; continue
            }
            switch TagPolicy.verdict(names: item.tagNames, blocked: blockedTags) {
            case .blocked: blockedCount += 1; continue
            case .unverified: unverifiedCount += 1; continue
            case .allowed: break
            }
            if deduplicateMediaAssets, let asset = item.mediaAssetKey, !mediaAssets.insert(asset).inserted { duplicateCount += 1; continue }
            if ids.insert(item.id).inserted { items.append(item) }
        }
    }
}

enum AuthorHandlePolicy {
    static func normalize(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    static func blocks(creatorID: Int?, username: String?, blockedIDs: Set<Int>, blockedHandles: Set<String>) -> Bool {
        if let creatorID { return blockedIDs.contains(creatorID) }
        guard let username else { return false }
        let handle = normalize(username)
        return !handle.isEmpty && blockedHandles.contains(handle)
    }

    static func followingUsernamesNeedingResolution(_ items: [MediaItem], limit: Int = 30) -> [String] {
        guard limit > 0 else { return [] }
        var seen = Set<String>()
        var result: [String] = []
        for item in items where item.creatorID == nil {
            guard let username = item.username?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !username.isEmpty, username.utf8.count <= 128,
                  !username.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { continue }
            let handle = normalize(username)
            guard !handle.isEmpty, seen.insert(handle).inserted else { continue }
            result.append(username)
            if result.count == limit { break }
        }
        return result
    }

    static func attachingFollowingCreatorIDs(_ items: [MediaItem], resolved: [Creator], followingIDs: Set<Int>) -> [MediaItem] {
        let grouped = Dictionary(grouping: resolved, by: { normalize($0.username) })
        let unique: [String: Int] = grouped.reduce(into: [:]) { result, pair in
            guard !pair.key.isEmpty else { return }
            let ids = Set(pair.value.map(\.id))
            if ids.count == 1, let id = ids.first, followingIDs.contains(id) { result[pair.key] = id }
        }
        return items.map { item in
            guard item.creatorID == nil, let username = item.username else { return item }
            var copy = item
            copy.creatorID = unique[normalize(username)]
            return copy
        }
    }
}
