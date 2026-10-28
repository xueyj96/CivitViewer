import Foundation

extension HistoryMediaReading {
    /// Rehydrates a bounded set of history IDs through the active account, then
    /// resolves missing following author IDs from current canonical usernames.
    func resumeMediaItems(ids: [Int], followingIDs: Set<Int>?, isCurrent: @MainActor () -> Bool) async throws -> [MediaItem] {
        guard ids.count <= 60, Set(ids).count == ids.count, ids.allSatisfy({ $0 > 0 }) else {
            throw ClientError.format("历史作品范围")
        }
        let capturedIdentity = feedIdentity
        let capturedFollowing = followingIDs

        func checkCurrent() throws {
            try Task.checkCancellation()
            guard capturedIdentity == feedIdentity, isCurrent(),
                  capturedFollowing == nil || followingMemberIDs == capturedFollowing else {
                throw CancellationError()
            }
        }

        try checkCurrent()
        var items: [MediaItem] = []
        for start in stride(from: 0, to: ids.count, by: 30) {
            try checkCurrent()
            let batch = Array(ids[start..<min(ids.count, start + 30)])
            let page: [MediaItem]
            do {
                page = try await mediaItems(ids: batch, includeTags: true)
                try checkCurrent()
            } catch {
                try checkCurrent()
                throw error
            }
            guard page.allSatisfy({ batch.contains($0.id) }) else { throw ClientError.invalidResponse }
            items.append(contentsOf: page)
        }

        guard let capturedFollowing else { return items }
        var resolved: [Creator] = []
        let names = AuthorHandlePolicy.followingUsernamesNeedingResolution(items, limit: 30)
        for username in names {
            try checkCurrent()
            do {
                let creator = try await creator(username: username)
                try checkCurrent()
                if capturedFollowing.contains(creator.id) { resolved.append(creator) }
            } catch ClientError.missingCreator {
                try checkCurrent()
            } catch {
                try checkCurrent()
                throw error
            }
        }
        try checkCurrent()
        return AuthorHandlePolicy.attachingFollowingCreatorIDs(items, resolved: resolved, followingIDs: capturedFollowing)
    }
}
