import Foundation
import Combine

struct FollowingListKey: Hashable {
    let identity: String
    let memberIDs: Set<Int>
    let revision: Int
    init(identity: String, memberIDs: Set<Int>, revision: Int = 0) {
        self.identity = identity; self.memberIDs = memberIDs; self.revision = revision
    }
}

struct FollowingPage: Decodable {
    let items: [Creator]
    let totalItems: Int
    let currentPage: Int
    let pageSize: Int
    let totalPages: Int
}

@MainActor protocol FollowingListSource: AnyObject {
    var followingIdentity: String { get }
    var followingActorID: Int? { get }
    var followingMemberIDs: Set<Int> { get }
    var followingRevision: Int { get }
    func refreshFollowingIDs() async throws -> Set<Int>
    func followingPage(page: Int, limit: Int) async throws -> FollowingPage
}

enum FollowingSort: String, CaseIterable, Identifiable {
    case followed, name
    var id: Self { self }
    var title: String { self == .followed ? "关注顺序" : "名称 A–Z" }
}

enum FollowingListError: LocalizedError {
    case accountChanged, membershipChanged, invalidSnapshotID, invalidPage, changedCounts, unexpectedCreator, duplicateCreator, incomplete
    var errorDescription: String? {
        switch self {
        case .accountChanged: "账号已变更，请重新加载关注列表。"
        case .membershipChanged: "关注关系已变化，请刷新后重新加载。"
        case .invalidSnapshotID: "关注关系包含无效作者 ID，请刷新关注状态后重试。"
        case .invalidPage: "关注列表分页数据无效，可重试当前页。"
        case .changedCounts: "关注列表总数在加载期间发生变化，可重试或刷新。"
        case .unexpectedCreator: "关注列表包含当前关系之外的作者，可重试当前页。"
        case .duplicateCreator: "关注列表分页包含重复作者，可重试当前页。"
        case .incomplete: "关注列表尚未完整加载。"
        }
    }
}

enum FollowingListOrdering {
    static func sort(_ creators: [Creator], by mode: FollowingSort, reverse: Bool = false) -> [Creator] {
        let result: [Creator]
        switch mode {
        case .followed: result = creators
        case .name:
            let locale = Locale(identifier: "en_US_POSIX")
            result = creators.sorted {
                let order = $0.username.compare($1.username, options: [.caseInsensitive, .diacriticInsensitive, .numeric], range: nil, locale: locale)
                if order == .orderedSame { return $0.id < $1.id }
                return order == .orderedAscending
            }
        }
        return reverse ? Array(result.reversed()) : result
    }
}

@MainActor final class FollowingListStore: ObservableObject {
    @Published private(set) var creators: [Creator] = []
    @Published private(set) var loading = false
    @Published private(set) var complete = false
    @Published private(set) var error: String?
    @Published private(set) var totalItems = 0
    @Published private(set) var nextPage = 1
    @Published private(set) var canContinue = false
    @Published private(set) var requestKey: FollowingListKey?

    let pageSize: Int
    let batchPages: Int
    private var eligible = Set<Int>()
    private var requestGeneration = 0

    init(pageSize: Int = 50, batchPages: Int = 20) {
        self.pageSize = min(max(pageSize, 1), 200)
        self.batchPages = min(max(batchPages, 1), 20)
    }

    func clear() {
        requestGeneration += 1; requestKey = nil; eligible = []; creators = []; loading = false
        complete = false; error = nil; totalItems = 0; nextPage = 1; canContinue = false
    }

    func ordered(_ mode: FollowingSort, reverse: Bool = false) -> [Creator] {
        guard complete else { return [] }
        return FollowingListOrdering.sort(creators, by: mode, reverse: reverse)
    }

    func reload(key newKey: FollowingListKey, source: FollowingListSource) async {
        guard !Task.isCancelled else { return }
        requestGeneration += 1; let generation = requestGeneration
        requestKey = newKey; eligible = []; creators = []; complete = false; error = nil
        totalItems = 0; nextPage = 1; canContinue = false; loading = true
        defer { if generation == requestGeneration { loading = false } }
        do {
            guard source.followingIdentity == newKey.identity else { throw FollowingListError.accountChanged }
            let ids = try await source.refreshFollowingIDs()
            try Task.checkCancellation()
            guard generation == requestGeneration else { return }
            guard source.followingIdentity == newKey.identity else { throw FollowingListError.accountChanged }
            guard ids == newKey.memberIDs, source.followingMemberIDs == newKey.memberIDs, source.followingRevision == newKey.revision else { throw FollowingListError.membershipChanged }
            guard ids.allSatisfy({ $0 > 0 || $0 == -1 || $0 == source.followingActorID }) else { throw FollowingListError.invalidSnapshotID }
            eligible = Set(ids.filter { $0 != -1 && $0 != source.followingActorID })
            if eligible.isEmpty { complete = true; canContinue = false; return }
            try await loadBatch(source: source, generation: generation)
        } catch is CancellationError {
            if generation == requestGeneration { error = "加载已取消，可重试当前关注列表。" }
        } catch {
            if generation == requestGeneration { self.error = error.localizedDescription }
        }
    }

    func nextBatch(source: FollowingListSource) async {
        guard requestKey != nil, !loading, !complete else { return }
        requestGeneration += 1; let generation = requestGeneration; loading = true; error = nil
        defer { if generation == requestGeneration { loading = false } }
        do { try await loadBatch(source: source, generation: generation) }
        catch is CancellationError { if generation == requestGeneration { error = "加载已取消，可重试当前分页。" } }
        catch { if generation == requestGeneration { self.error = error.localizedDescription } }
    }

    private func loadBatch(source: FollowingListSource, generation: Int) async throws {
        for _ in 0..<batchPages {
            try Task.checkCancellation()
            guard generation == requestGeneration else { return }
            guard let key = requestKey, source.followingIdentity == key.identity else { throw FollowingListError.accountChanged }
            guard source.followingMemberIDs == key.memberIDs, source.followingRevision == key.revision else { throw FollowingListError.membershipChanged }
            let response = try await source.followingPage(page: nextPage, limit: pageSize)
            guard generation == requestGeneration else { return }
            try Task.checkCancellation()
            guard source.followingIdentity == key.identity else { throw FollowingListError.accountChanged }
            guard source.followingMemberIDs == key.memberIDs, source.followingRevision == key.revision else { throw FollowingListError.membershipChanged }
            guard response.totalItems >= 0 else { throw FollowingListError.invalidPage }
            let expectedPages = max(1, response.totalItems / pageSize + (response.totalItems % pageSize == 0 ? 0 : 1))
            guard response.currentPage == nextPage, response.pageSize == pageSize,
                  response.totalPages >= 0,
                  response.totalPages == expectedPages,
                  response.items.count <= pageSize,
                  response.items.count == (nextPage < response.totalPages ? pageSize : response.totalItems - (nextPage - 1) * pageSize)
            else { throw FollowingListError.invalidPage }
            let candidateTotal = nextPage == 1 ? response.totalItems : totalItems
            guard candidateTotal == response.totalItems else { throw FollowingListError.changedCounts }
            let existing = Set(creators.map(\.id))
            guard response.items.allSatisfy({ eligible.contains($0.id) }) else { throw FollowingListError.unexpectedCreator }
            guard Set(response.items.map(\.id)).count == response.items.count,
                  existing.isDisjoint(with: response.items.map(\.id)) else { throw FollowingListError.duplicateCreator }
            let combined = creators + response.items
            let finalPage = nextPage == response.totalPages
            if finalPage {
                guard Set(combined.map(\.id)) == eligible, combined.count == candidateTotal else { throw FollowingListError.incomplete }
            }
            creators = combined
            totalItems = candidateTotal
            nextPage += 1
            if finalPage {
                complete = true; canContinue = false; return
            }
        }
        canContinue = !complete
    }
}
