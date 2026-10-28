import Foundation

@main struct AuthorBlocklistChecks {
    @MainActor static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1; precondition(condition(), message)
        }
        func media(_ id: Int, creatorID: Int?, username: String?) -> MediaItem {
            MediaItem(id: id, url: "https://example.invalid/media", width: 1, height: 1, type: "image",
                      username: username, browsingLevel: 1, thumbnail: nil, creatorID: creatorID)
        }
        let suite = "AuthorBlocklistChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "fixture.blockedAuthors.v1"
        let list = AuthorBlocklist(defaults: defaults, key: key)
        check(list.entries.isEmpty && list.error == nil, "Missing local envelope starts as an empty valid list")
        check(!list.add(Creator(id: 0, username: "Invalid", image: nil)) && !list.add(Creator(id: -2, username: "Invalid", image: nil)), "Nonpositive author IDs are refused")
        check(!list.add(Creator(id: 1, username: "  \n ", image: nil)) && !list.add(Creator(id: 2, username: "https://example.com/a", image: nil)), "Empty and URL-shaped usernames are refused")
        check(!list.add(Creator(id: 3, username: "bad\u{0007}name", image: nil)), "Control characters are refused in usernames")

        check(list.add(Creator(id: 10, username: " Alice ", image: nil)), "Valid creator is stored by stable ID and trimmed canonical username")
        check(list.add(Creator(id: 11, username: "ALICE", image: nil)), "A different stable ID with the same handle is retained without conflating identity")
        check(list.add(Creator(id: 12, username: "Unique", image: nil)), "Unique author can be added")
        check(!list.add(Creator(id: 10, username: "Alice Changed", image: nil)), "Duplicate ID cannot silently replace the stored canonical username")
        check(list.contains(id: 10) && list.blockedIDs == [10,11,12], "ID membership is explicit and local")

        check(list.blocks(media(100, creatorID: 10, username: "someone")), "Known blocked creator ID takes precedence over a different reported handle")
        check(!list.blocks(media(101, creatorID: 99, username: "alice")), "Known nonblocked ID is not blocked by a matching duplicate handle")
        check(!list.blocks(media(102, creatorID: nil, username: "alice")), "Ambiguous duplicate handles do not block anonymous-ID works")
        check(list.blocks(media(103, creatorID: nil, username: " UNIQUE ")), "Unique verified handle can block when creator ID is missing")
        check(!list.blocks(media(104, creatorID: nil, username: nil)), "Missing ID and username never broad-match")
        let history = HistoryRecord(id: 500, kind: .video, authorName: "Other", creatorID: 10, viewedAt: Date())
        let anonymousHistory = HistoryRecord(id: 501, kind: .image, authorName: "Unique", creatorID: nil, viewedAt: Date())
        check(list.blocks(history) && list.blocks(anonymousHistory), "History records use creator ID first and unique validated handle fallback")

        let sharedShapes = [
            media(200, creatorID: 10, username: "different-handle"),
            media(201, creatorID: 99, username: "unique"),
            media(202, creatorID: nil, username: " UNIQUE "),
            media(203, creatorID: nil, username: nil)
        ]
        let expectedBlocked = [true, false, true, false]
        let mediaDecisions = sharedShapes.map { list.blocks($0) }
        let historyDecisions = sharedShapes.map { item in
            list.blocks(HistoryRecord(id: item.id, kind: .image, authorName: item.username,
                                      creatorID: item.creatorID, viewedAt: Date()))
        }
        let offlineDecisions = sharedShapes.map { item in
            let record = OfflineRecord(id: item.id, video: false, username: item.username, creatorID: item.creatorID,
                                       browsingLevel: 1, collectionIDs: [], cloudState: .localOnly)
            return AuthorHandlePolicy.blocks(creatorID: record.creatorID, username: record.username,
                                             blockedIDs: list.blockedIDs, blockedHandles: list.blockedHandles)
        }
        var feed = FeedAccumulator()
        feed.append(.init(items: sharedShapes, metadata: .init(nextCursor: nil)))
        feed.applyBlockedAuthors(ids: list.blockedIDs, handles: list.blockedHandles)
        check(mediaDecisions == expectedBlocked && historyDecisions == expectedBlocked && offlineDecisions == expectedBlocked,
              "Media, history, and offline metadata apply identical ID-first and unique-handle fallback decisions")
        check(feed.items.map(\.id) == [201, 203] && feed.blockedAuthorCount == 2,
              "FeedAccumulator uses the shared policy while retaining known nonblocked IDs and anonymous works")
        check(AuthorHandlePolicy.blocks(creatorID: 0, username: "unique", blockedIDs: list.blockedIDs, blockedHandles: list.blockedHandles) == false &&
              AuthorHandlePolicy.blocks(creatorID: -7, username: "unique", blockedIDs: list.blockedIDs, blockedHandles: list.blockedHandles) == false,
              "Present nonpositive IDs retain ID-priority behavior instead of falling back to a matching handle")

        list.refreshKnownCreators([Creator(id: 12, username: "Renamed", image: nil), Creator(id: 99, username: "Unlisted", image: nil)])
        check(list.entries.first(where: { $0.id == 12 })?.username == "Renamed" && !list.contains(id: 99), "Refresh updates known blocked IDs only and never adds IDs")
        list.remove(id: 10)
        check(!list.contains(id: 10) && list.entries.count == 2, "Removing one ID persists a single-author unblock")
        check(list.blocks(media(105, creatorID: nil, username: "alice")), "After one duplicate handle is removed, the remaining unique handle fallback works")
        let restored = AuthorBlocklist(defaults: defaults, key: key)
        check(restored.entries == list.entries, "Reconstructed store reloads the versioned local envelope")

        let cappedKey = "fixture.authorCap"
        let capped = AuthorBlocklist(defaults: defaults, key: cappedKey)
        for id in 1...200 { check(capped.add(Creator(id: id, username: "author-\(id)", image: nil)), "Bounded list accepts entry \(id)") }
        check(capped.entries.count == 200 && !capped.add(Creator(id: 201, username: "author-201", image: nil)), "Author count is capped at 200")
        let oversized = AuthorBlocklist(defaults: defaults, key: "fixture.authorBytes")
        check(!oversized.add(Creator(id: 1, username: String(repeating: "a", count: 140_000), image: nil)) && oversized.entries.isEmpty, "Encoded storage exceeding 128 KiB is rejected without changing entries")

        let corruptKey = "fixture.corrupt"
        let corruptBytes = Data("not-json".utf8); defaults.set(corruptBytes, forKey: corruptKey)
        let corrupt = AuthorBlocklist(defaults: defaults, key: corruptKey)
        check(corrupt.entries.isEmpty && corrupt.error != nil && !corrupt.add(Creator(id: 1, username: "Alice", image: nil)), "Corrupt data is preserved and mutations are refused")
        check(defaults.data(forKey: corruptKey) == corruptBytes, "Failed load never overwrites corrupt original data")

        let schemaKey = "fixture.unknownSchema"
        let schemaBytes = Data(#"{"schemaVersion":9,"entries":[]}"#.utf8); defaults.set(schemaBytes, forKey: schemaKey)
        let incompatible = AuthorBlocklist(defaults: defaults, key: schemaKey)
        incompatible.remove(id: 999)
        check(incompatible.error != nil && defaults.data(forKey: schemaKey) == schemaBytes, "Unknown schema remains intact and cannot be overwritten")

        let invalidShapeKey = "fixture.invalidEnvelope"
        let invalidShape = Data(#"{"schemaVersion":1,"entries":[{"id":-1,"username":"bad"}]}"#.utf8)
        defaults.set(invalidShape, forKey: invalidShapeKey)
        let invalidEnvelope = AuthorBlocklist(defaults: defaults, key: invalidShapeKey)
        check(invalidEnvelope.error != nil && defaults.data(forKey: invalidShapeKey) == invalidShape, "Invalid persisted identities are rejected without replacing their source bytes")

        print("AuthorBlocklistChecks: \(checks) local assertions passed")
    }
}
