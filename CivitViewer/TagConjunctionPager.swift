import Foundation

@MainActor protocol TagCandidateSource: AnyObject {
    var feedIdentity: String { get }
    func tagCandidates(tagID: Int, author: Creator?, filter: FeedFilter, cursor: String?, limit: Int) async throws -> MediaPage
}

/// The public API's multi-tag input is OR. Preserve AND by checking every
/// returned tag ID; probe bounded first pages to choose a useful candidate lane.
@MainActor enum TagConjunctionPager {
    static let pageSize = 100
    private struct Position: Codable {
        let identity: String
        let criteriaID: String
        let filter: FeedFilter
        let anchor: Int
        var upstream: String?
        var visited = Set<String>()
        var pages: Int
        var candidates: Int
        var matches: Int
    }
    static func page(criteria: MediaSearchCriteria, filter: FeedFilter, cursor: String?, source: any TagCandidateSource) async throws -> MediaPage {
        guard criteria.valid, criteria.normalizedText.isEmpty, criteria.tags.count > 1,
              Set(criteria.tags.map(\.id)).count == criteria.tags.count else { throw ClientError.invalidResponse }
        try Task.checkCancellation()
        var position: Position
        let raw: MediaPage
        if let cursor {
            guard cursor.hasPrefix("tags1."), cursor.utf8.count <= 65_536,
                  let data = Data(base64Encoded: String(cursor.dropFirst(6))),
                  let value = try? JSONDecoder().decode(Position.self, from: data),
                  value.identity == source.feedIdentity, value.criteriaID == criteria.id, value.filter == filter,
                  criteria.tagIDs.contains(value.anchor), let upstream = value.upstream else { throw ClientError.accountChanged }
            position = value
            guard position.visited.insert(upstream).inserted else { throw ClientError.format("标签搜索的候选游标重复，请重新搜索。") }
            raw = try await source.tagCandidates(tagID: position.anchor, author: criteria.author, filter: filter, cursor: upstream, limit: pageSize)
            try Task.checkCancellation()
            guard position.identity == source.feedIdentity else { throw ClientError.accountChanged }
            try validate(raw, anchor: position.anchor, author: criteria.author)
            if let next = raw.metadata.nextCursor, position.visited.contains(next) { throw ClientError.format("标签搜索的候选游标重复，请重新搜索。") }
            position.pages += 1
            position.candidates += raw.items.count
        } else {
            let identity = source.feedIdentity
            var selected: (id: Int, page: MediaPage, matches: Int)?
            var probedPages = 0
            for tag in criteria.tags {
                try Task.checkCancellation()
                let page = try await source.tagCandidates(tagID: tag.id, author: criteria.author, filter: filter, cursor: nil, limit: pageSize)
                try Task.checkCancellation()
                guard identity == source.feedIdentity else { throw ClientError.accountChanged }
                try validate(page, anchor: tag.id, author: criteria.author)
                probedPages += 1
                let matches = try page.items.filter { try criteria.matches($0) }.count
                if let old = selected {
                    let ended = page.metadata.nextCursor == nil, oldEnded = old.page.metadata.nextCursor == nil
                    // An exhausted lane contains the complete intersection. Otherwise
                    // prefer observed matching density, never tag-ID-derived rarity.
                    if (ended && !oldEnded) || (ended && oldEnded && page.items.count < old.page.items.count)
                        || (!ended && !oldEnded && matches * max(1, old.page.items.count) > old.matches * max(1, page.items.count)) { selected = (tag.id, page, matches) }
                } else { selected = (tag.id, page, matches) }
                if page.items.isEmpty && page.metadata.nextCursor == nil { break }
            }
            guard let selected else { throw ClientError.invalidResponse }
            raw = selected.page
            position = .init(identity: identity, criteriaID: criteria.id, filter: filter, anchor: selected.id,
                             upstream: raw.metadata.nextCursor, pages: probedPages, candidates: raw.items.count, matches: 0)
        }
        let matches = try raw.items.filter { try criteria.matches($0) }
        position.matches += matches.count
        position.upstream = raw.metadata.nextCursor
        let next: String?
        if position.upstream != nil {
            let data = try JSONEncoder().encode(position)
            next = "tags1." + data.base64EncodedString()
        } else { next = nil }
        return .init(items: matches, metadata: .init(nextCursor: next), searchProgress: .init(pages: position.pages, candidates: position.candidates, matches: position.matches, anchorTagID: position.anchor))
    }
    private static func validate(_ page: MediaPage, anchor: Int, author: Creator?) throws {
        guard page.items.count <= pageSize,
              page.items.allSatisfy({ $0.tags?.contains(where: { $0.id == anchor }) == true }) else { throw ClientError.format("标签候选返回范围待核实，请重试。") }
        if let author, !page.items.allSatisfy({ $0.username?.lowercased() == author.username.lowercased() }) { throw ClientError.format("作者搜索返回范围不符") }
    }
}
