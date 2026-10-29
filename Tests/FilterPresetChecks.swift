import Foundation

@main struct FilterPresetChecks {
    @MainActor static func main() throws {
        var checks = 0
        func check(_ condition: Bool, _ message: String) { precondition(condition, message); checks += 1 }
        func expect(_ expected: FilterPresetError, _ operation: () throws -> Void) {
            do { try operation(); preconditionFailure("expected \(expected)") }
            catch let actual as FilterPresetError { precondition(actual == expected, "expected \(expected), got \(actual)"); checks += 1 }
            catch { preconditionFailure("unexpected error \(error)") }
        }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("preset-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = FilterPresetStore(root: base)
        let criteria = MediaSearchCriteria(text: "Portrait", author: Creator(id: 91, username: "ArtistA", image: nil), tags: [SearchTag(id: 7, name: "portrait", nsfwLevel: 1)])
        let snapshot = FilterPresetSnapshot(filter: FeedFilter(kind: .video, sort: "Newest", period: "Month", baseModel: "Flux.1 D", onlyPG: true, videoDurationRange: VideoDurationRange(minimumSeconds: 9, maximumSeconds: 45)), criteria: criteria)
        let saved = try store.save(ownerID: 17, scope: .search, name: "Portraits", snapshot: snapshot)
        let restarted = FilterPresetStore(root: base)
        let loaded = try restarted.list(ownerID: 17, scope: .search)
        check(loaded == [saved] && loaded[0].snapshot.criteria == criteria && loaded[0].snapshot.filter == snapshot.filter, "round trip preserves all filter and search DTO fields")
        let equivalentRangeFilter = FeedFilter(kind: .all, videoDurationRange: VideoDurationRange(minimumSeconds: 12, maximumSeconds: 30))
        let normalizedSnapshot = FilterPresetSnapshot(filter: equivalentRangeFilter)
        check(normalizedSnapshot.filter.kind == .video && normalizedSnapshot.filter.effectiveKind == .video, "active duration range normalizes effective kind to video")
        let legacyJSON = String(data: try JSONEncoder().encode(normalizedSnapshot), encoding: .utf8)!.replacingOccurrences(of: "\"kind\":\"video\"", with: "\"kind\":\"all\"")
        let decodedLegacy = try JSONDecoder().decode(FilterPresetSnapshot.self, from: Data(legacyJSON.utf8))
        check(decodedLegacy.filter.kind == .video && decodedLegacy.filter.videoDurationRange != nil, "equivalent decoded all plus duration representation is normalized")
        let underscoreCriteria = MediaSearchCriteria(tags: [SearchTag(id: 5, name: "_site_tag%")])
        let underscoreSnapshot = FilterPresetSnapshot(filter: FeedFilter(), criteria: underscoreCriteria)
        _ = try store.save(ownerID: 17, scope: .search, name: "Canonical tag", snapshot: underscoreSnapshot)
        check(try FilterPresetStore(root: base).list(ownerID: 17, scope: .search).contains(where: { $0.snapshot.criteria == underscoreCriteria }), "canonical resolved tag names may contain underscore and percent")
        check(try restarted.list(ownerID: 17, scope: .following).isEmpty && restarted.list(ownerID: 18, scope: .search).isEmpty && restarted.list(ownerID: nil, scope: .search).isEmpty, "scope, owner, and anonymous storage are isolated")
        expect(.duplicateName) { _ = try restarted.save(ownerID: 17, scope: .search, name: " portraits ", snapshot: snapshot) }
        expect(.invalidName) { _ = try restarted.save(ownerID: 17, scope: .search, name: "   ", snapshot: snapshot) }
        expect(.invalidSnapshot) { _ = try restarted.save(ownerID: 17, scope: .following, name: "bad-scope", snapshot: snapshot) }
        let repeatedTag = MediaSearchCriteria(tags: [SearchTag(id: 1, name: "cat"), SearchTag(id: 1, name: "dog")])
        expect(.invalidSnapshot) { _ = try restarted.save(ownerID: 17, scope: .search, name: "invalid-tag", snapshot: FilterPresetSnapshot(filter: FeedFilter(), criteria: repeatedTag)) }
        // Derive the generated target by seeding through the store, then corrupt its one JSON file.
        let isolated = base.appendingPathComponent("corrupt", isDirectory: true)
        let seed = FilterPresetStore(root: isolated)
        _ = try seed.save(ownerID: 88, scope: .recommendation, name: "keep", snapshot: FilterPresetSnapshot(filter: FeedFilter()))
        let file = try FileManager.default.contentsOfDirectory(at: isolated, includingPropertiesForKeys: nil).first!
        try Data("not-json".utf8).write(to: file)
        expect(.malformedFile) { _ = try FilterPresetStore(root: isolated).list(ownerID: 88, scope: .recommendation) }
        check((try Data(contentsOf: file)) == Data("not-json".utf8), "malformed file remains untouched")

        for missingField in ["authorID", "authorUsername"] {
            let damagedRoot = base.appendingPathComponent("damaged-\(missingField)", isDirectory: true)
            _ = try FilterPresetStore(root: damagedRoot).save(ownerID: 77, scope: .search, name: "Constrained", snapshot: snapshot)
            let damagedFile = try FileManager.default.contentsOfDirectory(at: damagedRoot, includingPropertiesForKeys: nil).first!
            var document = try JSONSerialization.jsonObject(with: Data(contentsOf: damagedFile)) as! [String: Any]
            var scopes = document["scopes"] as! [String: Any]
            var rows = scopes["search"] as! [[String: Any]]
            var persistedSnapshot = rows[0]["snapshot"] as! [String: Any]
            var persistedSearch = persistedSnapshot["search"] as! [String: Any]
            persistedSearch.removeValue(forKey: missingField)
            persistedSnapshot["search"] = persistedSearch
            rows[0]["snapshot"] = persistedSnapshot
            scopes["search"] = rows; document["scopes"] = scopes
            let damagedData = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
            try damagedData.write(to: damagedFile)
            let damagedStore = FilterPresetStore(root: damagedRoot)
            expect(.invalidSnapshot) { _ = try damagedStore.list(ownerID: 77, scope: .search) }
            expect(.invalidSnapshot) { _ = try damagedStore.save(ownerID: 77, scope: .following, name: "Other scope", snapshot: FilterPresetSnapshot(filter: FeedFilter())) }
            check((try Data(contentsOf: damagedFile)) == damagedData && damagedStore.revision == 0,
                  "missing \(missingField) is rejected without widening or rewriting the owner document")
        }

        let oversizedRoot = base.appendingPathComponent("oversized", isDirectory: true)
        _ = try FilterPresetStore(root: oversizedRoot).save(ownerID: 89, scope: .recommendation, name: "keep", snapshot: FilterPresetSnapshot(filter: FeedFilter()))
        let oversizedFile = try FileManager.default.contentsOfDirectory(at: oversizedRoot, includingPropertiesForKeys: nil).first!
        try Data(repeating: 0x41, count: 1_048_577).write(to: oversizedFile)
        expect(.fileTooLarge) { _ = try FilterPresetStore(root: oversizedRoot).list(ownerID: 89, scope: .recommendation) }
        check((try Data(contentsOf: oversizedFile)).count == 1_048_577, "oversized file remains untouched")

        let capacityRoot = base.appendingPathComponent("capacity", isDirectory: true)
        let capacity = FilterPresetStore(root: capacityRoot)
        for i in 1...49 { _ = try capacity.save(ownerID: 3, scope: .recommendation, name: "P\(i)", snapshot: FilterPresetSnapshot(filter: FeedFilter())) }
        _ = try capacity.save(ownerID: 3, scope: .following, name: "F1", snapshot: FilterPresetSnapshot(filter: FeedFilter()))
        expect(.tooManyPresets) { _ = try capacity.save(ownerID: 3, scope: .search, name: "S1", snapshot: FilterPresetSnapshot(filter: FeedFilter(), criteria: MediaSearchCriteria(text: "Search"))) }
        check(try capacity.list(ownerID: 3, scope: .recommendation).count + capacity.list(ownerID: 3, scope: .following).count == 50, "50 preset limit is shared across scopes")

        let firstCapacityPreset = try capacity.list(ownerID: 3, scope: .recommendation)[0]
        try capacity.delete(ownerID: 3, scope: .recommendation, id: firstCapacityPreset.id)
        let backupRoot = base.appendingPathComponent("capacity-backup", isDirectory: true)
        try FileManager.default.moveItem(at: capacityRoot, to: backupRoot)
        try Data("block".utf8).write(to: capacityRoot)
        let revisionBeforeFailure = capacity.revision
        expect(.writeFailed) { _ = try capacity.save(ownerID: 3, scope: .following, name: "F2", snapshot: FilterPresetSnapshot(filter: FeedFilter())) }
        let cachedRecommendationCount = try capacity.list(ownerID: 3, scope: .recommendation).count
        check(capacity.revision == revisionBeforeFailure && cachedRecommendationCount == 48, "failed owner-document write preserves cached content and revision")
        check(try FilterPresetStore(root: backupRoot).list(ownerID: 3, scope: .following).count == 1, "failed owner-document write preserves prior disk file")

        let failureRoot = base.appendingPathComponent("not-a-directory")
        try Data("block".utf8).write(to: failureRoot)
        let failedStore = FilterPresetStore(root: failureRoot)
        expect(.writeFailed) { _ = try failedStore.save(ownerID: 5, scope: .recommendation, name: "fail", snapshot: FilterPresetSnapshot(filter: FeedFilter())) }
        check(failedStore.revision == 0, "failed atomic write does not publish a successful revision")
        print("FilterPresetChecks: \(checks) checks passed")
    }
}
