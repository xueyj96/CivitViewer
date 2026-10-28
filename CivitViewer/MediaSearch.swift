import Foundation
import Combine

enum MediaSearchMode: String, CaseIterable, Identifiable {
    case author, tag, title
    var id: Self { self }
    var title: String { switch self { case .author: "作者"; case .tag: "标签"; case .title: "标题" } }
    var hint: String { switch self { case .author: "输入作者昵称"; case .tag: "输入标签名称前缀"; case .title: "输入作品帖标题前缀" } }
    var explanation: String {
        switch self {
        case .author: "先匹配站点作者昵称，选择作者后搜索其图片和视频。每次最多返回 20 位候选；请细化昵称，不表示已遍历全部作者。"
        case .tag: "按站点图片／视频标签名称前缀查找，选择准确标签后搜索对应作品。标签不是 prompt 全文，中文关键词不会自动翻译。"
        case .title: "按已发布作品帖的标题前缀匹配，忽略大小写，再分页读取帖子内的图片和视频。不会只展示帖子封面；不搜索 prompt、描述或任意全文。"
        }
    }
}

struct SearchTag: Decodable, Hashable, Identifiable { let id: Int; let name: String; var nsfwLevel: Int? = nil }
struct MediaSearchCriteria: Hashable, Identifiable {
    var text = ""
    var author: Creator?
    var tags: [SearchTag] = []
    var normalizedText: String { MediaSearchText.normalized(text) }
    var tagIDs: Set<Int> { Set(tags.map(\.id)) }
    var id: String { "combined:\(author?.id ?? 0):\(tagIDs.sorted().map(String.init).joined(separator: ",")):\(normalizedText.lowercased())" }
    var valid: Bool {
        (!normalizedText.isEmpty || author != nil || !tags.isEmpty) && (normalizedText.isEmpty || MediaSearchText.valid(normalizedText, mode: .title))
            && tags.count <= 8 && tags.allSatisfy { $0.id > 0 } && (author.map { $0.id > 0 } ?? true)
    }
    var summary: String {
        ([normalizedText.isEmpty ? nil : "标题开头：" + normalizedText, author.map { "作者：@" + $0.username }] + tags.map { "#" + $0.name }).compactMap { $0 }.joined(separator: " · ")
    }
    func matches(_ item: MediaItem) throws -> Bool {
        if let author {
            guard let username = item.username else { throw ClientError.format("搜索作品作者待核实") }
            if username.lowercased() != author.username.lowercased() { return false }
        }
        if !tags.isEmpty {
            guard let actual = item.tags, actual.allSatisfy({ $0.id != nil }) else { throw ClientError.format("多标签搜索元数据待核实") }
            if !tagIDs.isSubset(of: Set(actual.compactMap(\.id))) { return false }
        }
        return true
    }
}
enum MediaSearchTarget: Hashable, Identifiable {
    case author(Creator), tag(SearchTag), title(String), combined(MediaSearchCriteria)
    var id: String { switch self { case .author(let creator): "author:\(creator.id)"; case .tag(let tag): "tag:\(tag.id)"; case .title(let text): "title:" + text.lowercased(); case .combined(let criteria): criteria.id } }
    var title: String { switch self { case .author(let creator): "@" + creator.username; case .tag(let tag): "#" + tag.name; case .title(let text): "标题：" + text; case .combined: "搜索结果" } }
    var explanation: String { switch self { case .author: "这位作者在当前账号内容范围内的图片和视频。"; case .tag: "站点按所选标签 ID 搜索的图片和视频。"; case .title: MediaSearchMode.title.explanation; case .combined(let criteria): "需同时满足：" + criteria.summary + "。文本按作品帖标题前缀，不搜索 prompt。" } }
    var selectedTags: [SearchTag] { switch self { case .tag(let tag): [tag]; case .combined(let criteria): criteria.tags; default: [] } }
}

enum MediaSearchText {
    static func normalized(_ raw: String) -> String { raw.trimmingCharacters(in: .whitespacesAndNewlines) }
    static func valid(_ raw: String, mode: MediaSearchMode) -> Bool {
        let value = normalized(raw)
        return !value.isEmpty && value.count <= 80 && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && (mode == .author || (!value.contains("%") && !value.contains("_")))
    }
    static func matchesPrefix(_ value: String?, keyword: String) -> Bool {
        guard let value else { return false }
        return value.lowercased().hasPrefix(normalized(keyword).lowercased())
    }
    static let validationMessage = "请输入 1—80 个字符。标题／标签搜索暂不接受 % 和 _ 通配符。"
}

struct SearchPostPage: Decodable {
    struct Post: Decodable { let id: Int; let title: String?; var user: User? = nil; struct User: Decodable { let id: Int } }
    let items: [Post]
    let nextCursor: PublicationCursor?
}

@MainActor protocol MediaSearchSource: AnyObject {
    var feedIdentity: String { get }
    func searchAuthors(keyword: String) async throws -> [Creator]
    func searchTags(keyword: String, page: Int) async throws -> [SearchTag]
    func searchTitlePosts(keyword: String, filter: FeedFilter, cursor: PublicationCursor?) async throws -> SearchPostPage
    func searchPostMedia(postID: Int, filter: FeedFilter, cursor: String?, includeTags: Bool) async throws -> MediaPage
}

/// A title page is not a media page: consume every media cursor of a matched
/// post before advancing to the next post. No cover-only truncation or global
/// fallback when a search field is unsupported.
@MainActor enum TitleMediaPager {
    private struct Position: Codable {
        let keyword: String
        let identity: String
        let filter: FeedFilter
        var criteriaID: String?
        var postsRead = false
        var postCursor: PublicationCursor?
        var pendingPosts: [Int] = []
        var mediaCursor: String?
        var seenPostCursors = Set<PublicationCursor>()
        var seenPosts = Set<Int>()
        var seenMediaCursors = Set<String>()
    }
    static func page(keyword: String, filter: FeedFilter, cursor: String?, includeTags: Bool, source: any MediaSearchSource, criteria: MediaSearchCriteria? = nil) async throws -> MediaPage {
        try Task.checkCancellation()
        guard MediaSearchText.valid(keyword, mode: .title) else { throw ClientError.format("搜索关键词") }
        let keyword = MediaSearchText.normalized(keyword)
        var position: Position
        if let cursor {
            guard cursor.hasPrefix("title.v1."), cursor.count < 65_536,
                  let data = Data(base64Encoded: String(cursor.dropFirst(9))) else { throw ClientError.invalidResponse }
            position = try JSONDecoder().decode(Position.self, from: data)
            guard position.keyword == keyword, position.identity == source.feedIdentity, position.filter == filter, position.criteriaID == criteria?.id else { throw ClientError.accountChanged }
        } else { position = Position(keyword: keyword, identity: source.feedIdentity, filter: filter, criteriaID: criteria?.id) }
        if position.pendingPosts.isEmpty {
            guard !position.postsRead || position.postCursor != nil else { return .init(items: [], metadata: .init(nextCursor: nil)) }
            let page = try await source.searchTitlePosts(keyword: keyword, filter: filter, cursor: position.postCursor)
            try Task.checkCancellation()
            guard position.identity == source.feedIdentity else { throw ClientError.accountChanged }
            guard page.items.allSatisfy({ $0.id > 0 && MediaSearchText.matchesPrefix($0.title, keyword: keyword) }) else { throw ClientError.format("站点标题搜索条件未生效") }
            if let next = page.nextCursor {
                guard position.seenPostCursors.count < 512, position.seenPostCursors.insert(next).inserted else { throw ClientError.format("标题搜索分页重复或超出单次范围") }
            }
            position.postsRead = true; position.postCursor = page.nextCursor
            var matched: [Int] = []
            for post in page.items {
                if let author = criteria?.author {
                    guard let owner = post.user?.id else { throw ClientError.format("标题搜索作者信息待核实") }
                    if owner != author.id { continue }
                }
                if position.seenPosts.insert(post.id).inserted { matched.append(post.id) }
            }
            position.pendingPosts = matched
        }
        var items: [MediaItem] = []
        if let postID = position.pendingPosts.first {
            let page = try await source.searchPostMedia(postID: postID, filter: filter, cursor: position.mediaCursor, includeTags: includeTags)
            try Task.checkCancellation()
            guard position.identity == source.feedIdentity else { throw ClientError.accountChanged }
            guard page.items.allSatisfy({ $0.postID == postID }) else { throw ClientError.format("站点返回作品不属于匹配的帖子") }
            items = try page.items.filter { try criteria?.matches($0) ?? true }
            if let next = page.metadata.nextCursor {
                guard position.seenMediaCursors.insert(next).inserted else { throw ClientError.format("帖子作品分页重复") }
                position.mediaCursor = next
            } else {
                position.pendingPosts.removeFirst(); position.mediaCursor = nil; position.seenMediaCursors = []
            }
        }
        var next: String?
        if !position.pendingPosts.isEmpty || position.postCursor != nil {
            let data = try JSONEncoder().encode(position)
            guard data.count < 48_000 else { throw ClientError.format("搜索分页范围已达上限，请细化关键词") }
            next = "title.v1." + data.base64EncodedString()
        }
        return .init(items: items, metadata: .init(nextCursor: next))
    }
}

@MainActor final class SearchLookupStore: ObservableObject {
    struct Key: Equatable { let mode: MediaSearchMode; let text: String; let identity: String; let blockedTags: Set<String> }
    @Published private(set) var authors: [Creator] = []
    @Published private(set) var tags: [SearchTag] = []
    @Published private(set) var loading = false
    @Published private(set) var reachedEnd = false
    @Published private(set) var error: String?
    @Published private(set) var key: Key?
    private var generation = 0
    private var nextPage = 1
    private var seen = Set<Int>()
    func clear() { generation += 1; authors = []; tags = []; loading = false; error = nil; key = nil; nextPage = 1; seen = []; reachedEnd = false }
    func reload(key: Key, source: any MediaSearchSource) async {
        clear(); self.key = key
        guard MediaSearchText.valid(key.text, mode: key.mode), key.mode != .title else { reachedEnd = true; return }
        await next(source: source)
    }
    func next(source: any MediaSearchSource) async {
        guard let key, key.identity == source.feedIdentity, !loading, !reachedEnd else { return }
        loading = true; error = nil; let revision = generation
        defer { if revision == generation { loading = false } }
        do {
            if key.mode == .author {
                let result = try await source.searchAuthors(keyword: key.text)
                try Task.checkCancellation()
                guard revision == generation, key.identity == source.feedIdentity else { return }
                authors = Array(result.filter { $0.id > 0 && !$0.username.isEmpty && seen.insert($0.id).inserted }.prefix(20))
                reachedEnd = true // Server username-search has no offset; maximum20.
            } else {
                let result = try await source.searchTags(keyword: TagPolicy.normalize(key.text), page: nextPage)
                try Task.checkCancellation()
                guard revision == generation, key.identity == source.feedIdentity else { return }
                guard result.allSatisfy({ $0.id > 0 && MediaSearchText.matchesPrefix($0.name, keyword: key.text) }) else { throw ClientError.format("站点标签搜索条件未生效") }
                let fresh = result.filter { seen.insert($0.id).inserted }
                guard result.isEmpty || !fresh.isEmpty else { throw ClientError.format("标签候选分页重复，请细化关键词") }
                tags += fresh.filter { !key.blockedTags.contains(TagPolicy.normalize($0.name)) }
                nextPage += 1; reachedEnd = result.count < 20
            }
        } catch is CancellationError {} catch { if revision == generation { self.error = error.localizedDescription } }
    }
}
