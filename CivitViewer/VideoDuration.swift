import Foundation

/// Finite endpoints are inclusive seconds. Only the separate lower terminal is
/// exclusive (>120); only a nil upper endpoint means no maximum.
struct VideoDurationRange: Codable, Equatable, Hashable {
    private(set) var minimumSeconds: Int
    private(set) var maximumSeconds: Int?
    private(set) var minimumIsExclusive: Bool
    init(minimumSeconds: Int = 2, maximumSeconds: Int? = nil, minimumIsExclusive: Bool = false) {
        self.minimumSeconds = min(120, max(2, minimumSeconds))
        self.minimumIsExclusive = minimumIsExclusive && self.minimumSeconds == 120
        // An exclusive 120-second lower bound has no valid finite upper bound.
        self.maximumSeconds = self.minimumIsExclusive ? nil : maximumSeconds.map { min(120, max(self.minimumSeconds, $0)) }
    }
    private enum CodingKeys: CodingKey { case minimumSeconds, maximumSeconds, minimumIsExclusive }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(minimumSeconds: try values.decode(Int.self, forKey: .minimumSeconds),
                  maximumSeconds: try values.decodeIfPresent(Int.self, forKey: .maximumSeconds),
                  minimumIsExclusive: try values.decodeIfPresent(Bool.self, forKey: .minimumIsExclusive) ?? false)
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(minimumSeconds, forKey: .minimumSeconds)
        try values.encodeIfPresent(maximumSeconds, forKey: .maximumSeconds)
        // Preserve the legacy representation for inclusive ranges.
        if minimumIsExclusive { try values.encode(true, forKey: .minimumIsExclusive) }
    }
    func contains(_ seconds: Double?) -> Bool {
        guard let seconds, seconds.isFinite, seconds > 0 else { return false }
        let aboveMinimum = minimumIsExclusive ? seconds > Double(minimumSeconds) : seconds >= Double(minimumSeconds)
        return aboveMinimum && maximumSeconds.map { seconds <= Double($0) } != false
    }
    var minimumTitle: String { minimumIsExclusive ? "超过02:00" : VideoDurationScale.title(minimumSeconds) }
    var maximumTitle: String { maximumSeconds.map(VideoDurationScale.title) ?? "不限" }
    var summary: String { minimumIsExclusive ? minimumTitle : "\(minimumTitle)—\(maximumTitle)" }
}

enum VideoDurationScale {
    static let seconds = Array(2...120)
    static let finiteLastIndex = seconds.count - 1
    /// A state index, never a duration in seconds: lower >120 or upper nil.
    static let terminalIndex = seconds.count
    static let unlimitedIndex = terminalIndex
    static let tickSeconds = [30, 60, 90, 120]
    static func title(_ seconds: Int) -> String { String(format: "%02d:%02d", seconds / 60, seconds % 60) }
    static func index(for seconds: Int) -> Int { min(120, max(2, seconds)) - 2 }
    static func lowerIndex(_ range: VideoDurationRange) -> Int { range.minimumIsExclusive ? terminalIndex : index(for: range.minimumSeconds) }
    static func upperIndex(_ range: VideoDurationRange) -> Int { range.maximumSeconds.map(index) ?? terminalIndex }
    static func movingLower(_ index: Int, in range: VideoDurationRange) -> VideoDurationRange {
        let index = min(terminalIndex, max(0, min(index, upperIndex(range))))
        return .init(minimumSeconds: index == terminalIndex ? 120 : seconds[index], maximumSeconds: range.maximumSeconds,
                     minimumIsExclusive: index == terminalIndex)
    }
    static func movingUpper(_ index: Int, in range: VideoDurationRange) -> VideoDurationRange {
        let index = min(terminalIndex, max(lowerIndex(range), index))
        return .init(minimumSeconds: range.minimumSeconds, maximumSeconds: index == terminalIndex ? nil : seconds[index],
                     minimumIsExclusive: range.minimumIsExclusive)
    }
    /// The finite span is linear; a separate terminal area gives the special
    /// states usable space without pretending that they are 121 seconds.
    static func fraction(for index: Int, finiteFraction: Double) -> Double {
        let span = min(0.95, max(0.5, finiteFraction))
        let index = min(terminalIndex, max(0, index))
        return index == terminalIndex ? 1 : Double(index) / Double(finiteLastIndex) * span
    }
    static func index(atFraction fraction: Double, finiteFraction: Double) -> Int {
        guard fraction.isFinite else { return 0 }
        let span = min(0.95, max(0.5, finiteFraction))
        let position = min(1, max(0, fraction))
        if position > (span + 1) / 2 { return terminalIndex }
        return min(finiteLastIndex, max(0, Int((position / span * Double(finiteLastIndex)).rounded())))
    }
}

/// Technical `metadata.duration` is seconds; generation `meta` is deliberately ignored.
struct VideoTechnicalMetadata: Decodable, Hashable {
    let duration: Double?
    init(duration: Double?) { self.duration = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } }
    private enum CodingKeys: CodingKey { case duration }
    init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        self.init(duration: try? container?.decode(Double.self, forKey: .duration))
    }
}
struct VideoDurationRecord: Decodable {
    let id: Int
    let metadata: VideoTechnicalMetadata?
}
struct VideoDurationMetadataPage: Decodable { let items: [VideoDurationRecord] }

/// Also used by the following-feed index before REST media hydration.
struct FollowingIndexPage: Decodable {
    let items: [Item]
    let nextCursor: String?
    struct Item: Decodable {
        let id: Int
        let user: User
        var metadata: VideoTechnicalMetadata? = nil
    }
    struct User: Decodable { let id: Int }
}

struct VideoDurationBatch: Equatable {
    let ids: [Int]
    let postIDs: [Int]
    init(items: [MediaItem]) {
        var seen = Set<Int>()
        let candidates = items.filter { $0.isVideo && $0.durationSeconds == nil && $0.id > 0 && ($0.postID ?? 0) > 0 && seen.insert($0.id).inserted }.prefix(20)
        ids = candidates.map(\.id)
        var posts = Set<Int>()
        postIDs = candidates.compactMap(\.postID).filter { posts.insert($0).inserted }
    }
    func merging(_ records: [VideoDurationRecord], into items: [MediaItem]) -> [MediaItem] {
        let expected = Set(ids)
        let byID = Dictionary(records.filter { expected.contains($0.id) }.map { ($0.id, $0.metadata) }, uniquingKeysWith: { first, _ in first })
        return items.map { item in
            guard item.durationSeconds == nil, let metadata = byID[item.id] ?? nil else { return item }
            var copy = item; copy.metadata = metadata; return copy
        }
    }
}
