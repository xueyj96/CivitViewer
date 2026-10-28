import Foundation

@MainActor private final class CandidateStub: TagCandidateSource {
    struct Request {
        let tagID: Int
        let authorID: Int?
        let filter: FeedFilter
        let cursor: String?
        let limit: Int
    }
    var feedIdentity = "account-A"
    var requests: [Request] = []
    var fetch: (Request) async throws -> MediaPage = { _ in .init(items: [], metadata: .init(nextCursor: nil)) }

    func tagCandidates(tagID: Int, author: Creator?, filter: FeedFilter, cursor: String?, limit: Int) async throws -> MediaPage {
        let request = Request(tagID: tagID, authorID: author?.id, filter: filter, cursor: cursor, limit: limit)
        requests.append(request)
        return try await fetch(request)
    }
}

@MainActor private final class CandidateGate {
    var continuation: CheckedContinuation<Void, Never>?
    var opened = false
    func wait() async { if !opened { await withCheckedContinuation { continuation = $0 } } }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}

@main struct TagConjunctionChecks {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            precondition(condition(), message)
        }
        func creator(_ id: Int = 7, _ username: String = "alice") -> Creator { Creator(id: id, username: username, image: nil) }
        func item(_ id: Int, _ ids: [Int]?, username: String = "alice", video: Bool = true, missingTagMetadata: Bool = false) -> MediaItem {
            let tagValues = ids.map { values in values.map { MediaTag(id: $0) } + (missingTagMetadata ? [MediaTag(id: nil, name: "unknown")] : []) }
            return MediaItem(id: id, url: "https://fixture.invalid/media/\(id)", width: 640, height: 480,
                             type: video ? "video" : "image", username: username, browsingLevel: 1,
                             thumbnail: nil, creatorID: 7, tags: tagValues)
        }
        func page(_ items: [MediaItem], _ cursor: String?) -> MediaPage {
            MediaPage(items: items, metadata: .init(nextCursor: cursor))
        }
        func criteria(_ ids: [Int], author: Creator? = nil) -> MediaSearchCriteria {
            var value = MediaSearchCriteria()
            value.author = author
            value.tags = ids.map { SearchTag(id: $0, name: "tag\($0)", nsfwLevel: 1) }
            return value
        }
        func sameError(_ error: ClientError, _ kind: String) -> Bool {
            switch (error, kind) {
            case (.accountChanged, "account"), (.invalidResponse, "invalid"), (.format, "format"): true
            default: false
            }
        }
        func expectClientError(_ kind: String, _ operation: () async throws -> MediaPage) async throws {
            do { _ = try await operation(); preconditionFailure("Expected ClientError kind \(kind)") }
            catch let error as ClientError { check(sameError(error, kind), "Expected \(kind), got \(error)") }
        }
        let filter = FeedFilter(kind: .video, sort: "Newest", period: "AllTime")
        let author = creator()

        // Density comes from observed AND matches, not the numeric tag ID.
        let denseSource = CandidateStub()
        let sparseItems = (0..<100).map { item(1_000 + $0, $0 == 0 ? [10,900] : [10]) }
        let denseItems = (0..<100).map { item(2_000 + $0, $0 < 25 ? [10,900] : [900]) }
        denseSource.fetch = { request in
            request.tagID == 10 ? page(sparseItems, "sparse-next") : page(denseItems, "dense-next")
        }
        let denseCriteria = criteria([10,900], author: author)
        let first = try await TagConjunctionPager.page(criteria: denseCriteria, filter: filter, cursor: nil, source: denseSource)
        check(first.items.count == 25 && first.items.allSatisfy { $0.tags?.contains(where: { $0.id == 10 }) == true }, "AND filtering returns only actual intersections")
        check(first.searchProgress?.anchorTagID == 900 && first.searchProgress?.pages == 2 && first.searchProgress?.candidates == 100, "The larger-ID tag wins when its observed AND density is higher")
        check(denseSource.requests.map(\.tagID) == [10,900] && denseSource.requests.allSatisfy { $0.limit == 100 && $0.authorID == author.id && $0.filter == filter }, "Each first-page probe is bounded to 100 and preserves author and media filter")
        let secondCandidates = [item(3_000,[10,900]), item(3_001,[900])]
        denseSource.fetch = { request in
            check(request.tagID == 900 && request.cursor == "dense-next", "Continuation follows only the chosen upstream cursor")
            return page(secondCandidates, nil)
        }
        let second = try await TagConjunctionPager.page(criteria: denseCriteria, filter: filter, cursor: first.metadata.nextCursor, source: denseSource)
        check(second.items.map(\.id) == [3_000] && second.searchProgress?.pages == 3 && second.searchProgress?.candidates == 102 && second.searchProgress?.matches == 26, "Later pages continue the chosen lane and accumulate scan progress")
        check(denseSource.requests.count == 3 && denseSource.requests.last?.tagID == 900, "Continuation does not re-probe other tags")

        // A true AND intersection excludes one-sided matches even if both lanes end.
        let andSource = CandidateStub()
        let shared = item(10,[11,22]), leftOnly = item(11,[11]), rightOnly = item(12,[22])
        andSource.fetch = { request in request.tagID == 11 ? page([shared,leftOnly], nil) : page([shared,rightOnly], nil) }
        let andResult = try await TagConjunctionPager.page(criteria: criteria([11,22]), filter: filter, cursor: nil, source: andSource)
        check(andResult.items.map(\.id) == [10], "Conjunction keeps the intersection and does not degrade to OR")
        check(andResult.metadata.nextCursor == nil && andResult.searchProgress?.anchorTagID == 11, "Equal exhausted candidates choose one complete lane")

        // Zero matches with an upstream cursor is a scan continuation, not a final empty result.
        let zeroSource = CandidateStub()
        zeroSource.fetch = { request in request.tagID == 31 ? page([item(31,[31])], "lane-1") : page([item(32,[32])], "lane-2") }
        let zeroFirst = try await TagConjunctionPager.page(criteria: criteria([31,32]), filter: filter, cursor: nil, source: zeroSource)
        check(zeroFirst.items.isEmpty && zeroFirst.metadata.nextCursor != nil && zeroFirst.searchProgress?.matches == 0, "An empty filtered page with upstream cursor remains resumable")
        zeroSource.fetch = { request in
            check(request.tagID == 31 && request.cursor == "lane-1", "Zero-match continuation uses the selected lane")
            return page([item(33,[31,32])], nil)
        }
        let zeroSecond = try await TagConjunctionPager.page(criteria: criteria([31,32]), filter: filter, cursor: zeroFirst.metadata.nextCursor, source: zeroSource)
        check(zeroSecond.items.map(\.id) == [33] && zeroSecond.searchProgress?.matches == 1, "A later upstream match appears after an empty result page")

        let exhausted = CandidateStub()
        exhausted.fetch = { request in
            check(request.tagID == 41, "An empty exhausted stream proves the intersection empty immediately")
            return page([], nil)
        }
        let trulyEmpty = try await TagConjunctionPager.page(criteria: criteria([41,42]), filter: filter, cursor: nil, source: exhausted)
        check(trulyEmpty.items.isEmpty && trulyEmpty.metadata.nextCursor == nil && exhausted.requests.count == 1, "A short empty candidate stream produces a genuine completed empty result")

        // Probe budget is bounded by the validated eight-tag criteria maximum.
        let bounded = CandidateStub()
        let eight = criteria(Array(101...108))
        bounded.fetch = { request in page([item(5_000 + request.tagID, Array(101...108))], "cursor-\(request.tagID)") }
        let boundedResult = try await TagConjunctionPager.page(criteria: eight, filter: filter, cursor: nil, source: bounded)
        check(bounded.requests.count == 8 && bounded.requests.allSatisfy { $0.limit == 100 }, "A first batch probes no more than eight labels at no more than 100 items each")
        check(boundedResult.searchProgress?.pages == 8 && boundedResult.searchProgress?.candidates == 1, "Progress separates probed pages from chosen-lane candidate count")
        try await expectClientError("invalid") {
            try await TagConjunctionPager.page(criteria: criteria(Array(201...209)), filter: filter, cursor: nil, source: bounded)
        }

        // Cursor context binds tags, account and feed filter; malformed tokens fail closed.
        let contextSource = CandidateStub()
        contextSource.fetch = { request in page([item(6_001,[51,52])], "ctx-next") }
        let contextCriteria = criteria([51,52])
        let contextPage = try await TagConjunctionPager.page(criteria: contextCriteria, filter: filter, cursor: nil, source: contextSource)
        let priorCalls = contextSource.requests.count
        try await expectClientError("account") {
            try await TagConjunctionPager.page(criteria: criteria([51,53]), filter: filter, cursor: contextPage.metadata.nextCursor, source: contextSource)
        }
        var changedFilter = filter; changedFilter.kind = .image
        try await expectClientError("account") {
            try await TagConjunctionPager.page(criteria: contextCriteria, filter: changedFilter, cursor: contextPage.metadata.nextCursor, source: contextSource)
        }
        contextSource.feedIdentity = "account-B"
        try await expectClientError("account") {
            try await TagConjunctionPager.page(criteria: contextCriteria, filter: filter, cursor: contextPage.metadata.nextCursor, source: contextSource)
        }
        contextSource.feedIdentity = "account-A"
        try await expectClientError("account") {
            try await TagConjunctionPager.page(criteria: contextCriteria, filter: filter, cursor: "tags1.not-base64", source: contextSource)
        }
        check(contextSource.requests.count == priorCalls, "Changed conditions, account, and malformed cursor are rejected before an upstream read")

        // The candidate endpoint must honor both anchor-tag and selected-author scope.
        let badTag = CandidateStub()
        badTag.fetch = { _ in page([item(7_001,[62])], nil) }
        try await expectClientError("format") {
            try await TagConjunctionPager.page(criteria: criteria([61,62]), filter: filter, cursor: nil, source: badTag)
        }
        let badAuthor = CandidateStub()
        badAuthor.fetch = { _ in page([item(7_002,[63,64],username:"someone-else")], nil) }
        try await expectClientError("format") {
            try await TagConjunctionPager.page(criteria: criteria([63,64], author: author), filter: filter, cursor: nil, source: badAuthor)
        }
        let badAccount = CandidateStub()
        badAccount.fetch = { _ in badAccount.feedIdentity = "account-B"; return page([item(7_003,[65,66])], "next") }
        try await expectClientError("account") {
            try await TagConjunctionPager.page(criteria: criteria([65,66]), filter: filter, cursor: nil, source: badAccount)
        }
        check(badTag.requests.count == 1 && badAuthor.requests.allSatisfy { $0.authorID == author.id }, "Scope mismatches fail after one bounded request with author passed through")

        // Partial tag metadata is an error, never a permissive match.
        let missingMetadata = CandidateStub()
        missingMetadata.fetch = { _ in page([item(8_001,[71],missingTagMetadata:true)], nil) }
        try await expectClientError("format") {
            try await TagConjunctionPager.page(criteria: criteria([71,72]), filter: filter, cursor: nil, source: missingMetadata)
        }

        // A repeated upstream cursor halts instead of looping indefinitely.
        let repeatSource = CandidateStub()
        repeatSource.fetch = { _ in page([item(9_001,[81,82])], "same-position") }
        let repeatFirst = try await TagConjunctionPager.page(criteria: criteria([81,82]), filter: filter, cursor: nil, source: repeatSource)
        try await expectClientError("format") {
            try await TagConjunctionPager.page(criteria: criteria([81,82]), filter: filter, cursor: repeatFirst.metadata.nextCursor, source: repeatSource)
        }
        check(repeatSource.requests.count == 3, "Repeated cursor stops after one continuation request following two probes")

        // Cancellation and network failures stay failures; they are not converted to empty pages.
        let gateSource = CandidateStub(), started = CandidateGate(), release = CandidateGate()
        gateSource.fetch = { _ in started.open(); await release.wait(); return page([item(10_001,[91,92])], "pending") }
        let pending = Task { try await TagConjunctionPager.page(criteria: criteria([91,92]), filter: filter, cursor: nil, source: gateSource) }
        await started.wait(); pending.cancel(); release.open()
        do { _ = try await pending.value; preconditionFailure("Cancelled probe must throw") }
        catch is CancellationError { }
        catch { preconditionFailure("Expected cancellation, got \(error)") }
        check(gateSource.requests.count == 1, "Cancellation remains observable after the in-flight probe returns")
        let failed = CandidateStub(); failed.fetch = { _ in throw URLError(.timedOut) }
        do { _ = try await TagConjunctionPager.page(criteria: criteria([93,94]), filter: filter, cursor: nil, source: failed); preconditionFailure("Network error must throw") }
        catch is URLError { }
        catch { preconditionFailure("Expected network error, got \(error)") }
        check(failed.requests.count == 1, "Network error is not converted into a successful empty result")

        print("TagConjunctionChecks: \(checks) regression assertions passed")
    }
}
