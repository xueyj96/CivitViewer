import Foundation

#if DEBUG
/// Explicit launch-only acceptance harness. Uses the app's normal session;
/// never exports its credentials, response bodies or media URLs. No account,
/// follow, collection or preference writes are performed. Tag probes persist
/// public metadata; the unified probe also decodes up to three PG thumbnails
/// into a disposable QA directory and removes it, outside user media storage.
@MainActor enum AppReadback {
    private static var started = false
    static func runIfRequested(session: SiteSession) async {
        let args = ProcessInfo.processInfo.arguments
        if !started, args.contains("--probe-video-duration") {
            started = true
            await durationReadback(session: session)
            return
        }
        if !started, args.contains("--readback-unified-tags") {
            started = true
            await unifiedTagsReadback(session: session)
            return
        }
        if !started, args.contains("--readback-local-search") {
            started = true
            await localSearchReadback(session: session)
            return
        }
        if !started, let position = args.firstIndex(of: "--probe-tag"), args.indices.contains(position + 1), MediaSearchText.valid(args[position + 1], mode: .tag) {
            started = true
            await probeTag(MediaSearchText.normalized(args[position + 1]), session: session)
            return
        }
        guard !started, ProcessInfo.processInfo.arguments.contains("--readback-client") else { return }
        started = true
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        var report: [String: Any] = ["build": build, "version": "0.3.0", "readOnly": true,
                                   "authenticated": session.account != nil, "uiObserved": false]
        let identity = session.feedIdentity
        report["accountMediaMask"] = session.account?.browsingLevel ?? 1
        report["tagVocabularyScope"] = "All public tag types; no client media-grade, target or moderation-class filter"
        let filter = FeedFilter(kind: .all, sort: "Newest", period: "AllTime", onlyPG: true)
        do {
            let authors = try await session.searchAuthors(keyword: "MixFixer")
            report["authorLookup"] = ["status": authors.isEmpty ? "EMPTY" : "PASS", "count": authors.count, "limit": 20]
            if let author = authors.first(where: { $0.username.lowercased() == "mixfixer" }) {
                do {
                    let page = try await session.searchMediaPage(target: .author(author), filter: filter, cursor: nil, includeTags: true)
                    report["authorMedia"] = ["status": page.items.isEmpty ? "EMPTY" : "PASS", "count": page.items.count, "next": page.metadata.nextCursor != nil,
                                            "namedTagCoverage": page.items.filter { $0.tagNames != nil }.count]
                } catch { report["authorMedia"] = failure(error) }
                do {
                    let biography = try await session.creatorBiography(author)
                    report["biography"] = ["status": "PASS", "ownerMatched": biography.id == author.id, "visibleTextCharacters": BiographyText.plain(biography.profile?.bio ?? "").count,
                                           "blockedByAuthor": biography.blockedByThem ?? false]
                } catch { report["biography"] = failure(error) }
                do {
                    let value = try await session.latestPublication(creator: author)
                    let state: String
                    switch value { case .published: state = "PUBLISHED"; case .noVisibleWorks: state = "NO_VISIBLE_WORKS"; case .unverified: state = "UNVERIFIED" }
                    report["recentPublication"] = ["status": "PASS_RESPONSE", "result": state]
                } catch { report["recentPublication"] = failure(error) }
            } else { report["authorMedia"] = ["status": "NO_EXACT_CANDIDATE"] }
        } catch { report["authorLookup"] = failure(error) }
        var example: MediaItem?
        do {
            let tags = try await session.searchTags(keyword: "city", page: 1)
            report["tagLookup"] = ["status": tags.isEmpty ? "EMPTY" : "PASS", "count": tags.count,
                                   "prefixMatched": tags.allSatisfy { MediaSearchText.matchesPrefix($0.name, keyword: "city") }]
            if let tag = tags.first(where: { $0.name.lowercased() == "city" }) ?? tags.first {
                do {
                    let page = try await session.searchMediaPage(target: .tag(tag), filter: filter, cursor: nil, includeTags: true)
                    example = page.items.first
                    report["tagMedia"] = ["status": page.items.isEmpty ? "EMPTY" : "PASS", "count": page.items.count, "next": page.metadata.nextCursor != nil,
                                         "tagScopeVerified": page.items.allSatisfy { $0.tags?.contains(where: { $0.id == tag.id }) == true }]
                } catch { report["tagMedia"] = failure(error) }
            }
        } catch { report["tagLookup"] = failure(error) }
        do {
            let tags = try await session.catalogTags(keyword: "f", page: 1)
            report["userTagQueryF"] = ["status": tags.isEmpty ? "EMPTY" : "PASS", "count": tags.count,
                                       "prefixMatched": tags.allSatisfy { MediaSearchText.matchesPrefix($0.name, keyword: "f") },
                                       "usefulCount": tags.filter { TagDirectoryQuality.includes($0.name) }.count]
        } catch { report["userTagQueryF"] = failure(error) }
        do {
            struct TagPage: Decodable { let items: [SearchTag] }
            let prior: TagPage = try await session.rpc("tag.getAll", input: ["query": "f", "entityType": ["Image"], "limit": 20, "page": 1,
                                                                               "moderation": false, "include": ["nsfwLevel"], "nsfwLevel": session.account?.browsingLevel ?? 1])
            report["sameAccountPriorMaskF"] = ["status": "PASS_RESPONSE", "count": prior.items.count, "scope": "Read-only control using original media mask, same account/query"]
        } catch { report["sameAccountPriorMaskF"] = failure(error) }
        do {
            let tags = try await session.commonTags()
            report["commonTags"] = ["status": tags.isEmpty ? "EMPTY" : "PASS", "count": tags.count, "scope": "Server curated list, no client grade filter"]
        } catch { report["commonTags"] = failure(error) }
        do {
            let raw: [SearchTag] = try await session.rpc("tag.getFeedTagBar")
            report["commonTagMetadata"] = ["rawCount": raw.count, "knownGradeCount": raw.filter { $0.nsfwLevel != nil }.count,
                                           "originalMaskMatched": raw.filter { ($0.nsfwLevel ?? 0) & (session.account?.browsingLevel ?? 1) != 0 }.count]
        } catch { report["commonTagMetadata"] = failure(error) }
        do {
            let first = try await session.catalogTags(keyword: "", page: 1)
            let second = first.count == 20 ? try await session.catalogTags(keyword: "", page: 2) : []
            report["tagCatalog"] = ["status": first.isEmpty ? "EMPTY" : "PASS", "firstCount": first.count, "secondCount": second.count,
                                     "uniqueLoaded": Set((first + second).map(\.id)).count, "totalKnown": false, "scope": "Default public PG directory, bounded two-page read"]
        } catch { report["tagCatalog"] = failure(error) }
        do {
            let tag = try await session.exactTag(name: "city")
            report["exactTag"] = ["status": tag == nil ? "UNRESOLVED" : "PASS", "validID": (tag?.id ?? 0) > 0]
        } catch { report["exactTag"] = failure(error) }
        if let example {
            let tags = (example.tags ?? []).compactMap { value -> SearchTag? in
                guard let id = value.id, let name = value.name else { return nil }
                return .init(id: id, name: name)
            }
            if tags.count >= 2 {
                do {
                    let criteria = MediaSearchCriteria(tags: Array(tags.prefix(2)))
                    let page = try await session.searchMediaPage(target: .combined(criteria), filter: filter, cursor: nil, includeTags: true)
                    report["multiTag"] = ["status": page.items.isEmpty ? "EMPTY_WITHIN_BOUNDED_READ" : "PASS", "count": page.items.count, "next": page.metadata.nextCursor != nil,
                                          "allConditionsMatched": try page.items.allSatisfy { try criteria.matches($0) }]
                } catch { report["multiTag"] = failure(error) }
            }
        }
        do {
            var cursor: String?, found = 0, knownTags = 0, pages = 0
            repeat {
                let page = try await session.searchMediaPage(target: .title("City"), filter: filter, cursor: cursor, includeTags: true)
                found += page.items.count; knownTags += page.items.filter { $0.tagNames != nil }.count
                cursor = page.metadata.nextCursor; pages += 1
            } while cursor != nil && pages < 2
            report["titleMedia"] = ["status": found == 0 ? "EMPTY_WITHIN_BOUNDED_READ" : "PASS", "mediaCount": found, "pages": pages, "next": cursor != nil, "namedTagCoverage": knownTags,
                                     "scope": "Title prefix; matching post id validated on every media row; up to two media pages"]
        } catch { report["titleMedia"] = failure(error) }
        if session.account != nil {
            let following = FollowingListStore()
            let key = FollowingListKey(identity: session.followingIdentity, memberIDs: session.following, revision: session.followingRevision)
            await following.reload(key: key, source: session)
            let ids = following.creators.map(\.id)
            let expected = Set(session.following.filter { $0 > 0 && $0 != session.account?.id })
            let byName = following.ordered(.name)
            let locale = Locale(identifier: "en_US_POSIX")
            let orderedNames = zip(byName, byName.dropFirst()).allSatisfy { left, right in
                let order = left.username.compare(right.username, options: [.caseInsensitive, .diacriticInsensitive, .numeric], range: nil, locale: locale)
                return order == .orderedAscending || (order == .orderedSame && left.id < right.id)
            }
            report["followingOrder"] = ["status": following.error != nil ? "FAILED" : (following.complete ? "PASS" : "INCOMPLETE_BATCH_LIMIT"),
                                        "complete": following.complete, "loadedCount": ids.count, "serverTotal": following.totalItems,
                                        "membershipMatched": Set(ids) == expected && ids.count == expected.count,
                                        "timeOrderPreserved": following.ordered(.followed).map(\.id) == ids,
                                        "reverseTimeMatched": following.ordered(.followed, reverse: true).map(\.id) == Array(ids.reversed()),
                                        "nameOrderVerified": following.complete && orderedNames && byName.count == ids.count,
                                        "sameContext": key.identity == session.followingIdentity && key.memberIDs == session.following && key.revision == session.followingRevision,
                                        "uiObserved": false]
        }
        report["sameAccountContext"] = identity == session.feedIdentity
        report["finished"] = true
        write(report, filename: "client-build\(build).json")
    }
    private static func unifiedTagsReadback(session: SiteSession) async {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        let identity = session.tagLookupIdentity
        var report: [String: Any] = ["build": build, "authenticated": session.account != nil, "uiObserved": false,
                                   "scope": "tag metadata plus at most three PG video stills; no account writes", "wholeSiteComplete": false]
        await LocalTagLibrary.shared.bind(ownerID: session.tagLibraryOwnerID)
        var lookups: [String: Any] = [:]
        for keyword in ["f", "gaping", "city", ""] {
            guard identity == session.tagLookupIdentity else { break }
            let store = TagDirectoryStore(debounceNanoseconds: 0)
            let key = TagDirectoryStore.Key(mode: keyword.isEmpty ? .common : .catalog, keyword: keyword, identity: identity)
            let before = session.tagRPCReads
            await store.reload(key: key, source: session)
            let firstIDs = store.tags.map(\.id)
            let reads = session.tagRPCReads - before
            let onlineFailed = store.onlineError != nil
            let cacheFailed = store.cacheError != nil
            let exact = store.tags.contains { TagPolicy.normalize($0.name) == keyword }
            let repeatBefore = session.tagRPCReads
            await store.reload(key: key, source: session)
            lookups[keyword.isEmpty ? "common" : keyword] = ["loaded": store.tags.count, "uniqueIDs": Set(store.tags.map(\.id)).count,
                "prefixMatched": keyword.isEmpty || store.tags.allSatisfy { TagPolicy.normalize($0.name).hasPrefix(keyword) }, "exactMatch": exact,
                "onlineFailed": onlineFailed, "localSaveFailed": cacheFailed, "initialRPCs": reads,
                "repeatRPCs": session.tagRPCReads - repeatBefore, "repeatOrderedIDsEqual": firstIDs == store.tags.map(\.id),
                "continuation": !store.reachedEnd]
        }
        report["lookups"] = lookups
        let qaRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ThumbnailProbe-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: qaRoot) }
        let cache = MediaCache(directoryURL: qaRoot, monitorNetwork: false)
        do {
            let page = try await session.mediaPage(filter: FeedFilter(kind: .video, sort: "Most Reactions", period: "AllTime", onlyPG: true), cursor: nil, creator: nil, includeTags: true)
            var results: [[String: Any]] = []
            for item in page.items.filter({ $0.browsingLevel == 1 }).prefix(3) {
                guard identity == session.tagLookupIdentity else { break }
                guard let poster = item.posterURL else { results.append(["status": "NO_POSTER"]); continue }
                do {
                    let image = try await cache.loadImage(poster)
                    results.append(["status": "DECODED", "positiveDimensions": image.size.width > 0 && image.size.height > 0])
                } catch MediaDownloadError.http(let code) { results.append(["status": "HTTP_FAILURE", "code": code]) }
                catch MediaDownloadError.notImage { results.append(["status": "NOT_IMAGE_MIME"]) }
                catch ImageLoadError.decode { results.append(["status": "DECODE_FAILURE"]) }
                catch { results.append(["status": "OTHER_FAILURE", "errorType": String(describing: type(of: error))]) }
            }
            report["pgVideoPosters"] = results
        } catch { report["pgVideoPosters"] = failure(error) }
        report["sameAccountContext"] = identity == session.tagLookupIdentity
        report["finished"] = true
        write(report, filename: "unified-tags-build\(build).json")
    }

    private static func localSearchReadback(session: SiteSession) async {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        let identity = session.feedIdentity
        var report: [String: Any] = ["build": build, "authenticated": session.account != nil, "networkReadOnly": true,
                                   "mediaMetadataOnly": true, "localTagIndexWrites": true, "uiObserved": false]
        do {
            let names = ["gaping", "realistic"]
            var tags: [SearchTag] = []
            for name in names { if let tag = try await session.exactTag(name: name) { tags.append(tag) } }
            report["exactTagCount"] = tags.count
            if tags.count == 2 {
                let criteria = MediaSearchCriteria(tags: tags)
                let filter = FeedFilter(kind: .all, sort: "Newest", period: "AllTime")
                if let anchor = tags.sorted(by: { $0.id < $1.id }).first {
                    var cursor: String?, pages = 0, candidates = 0, matches = 0
                    repeat {
                        let page = try await session.tagCandidates(tagID: anchor.id, author: nil, filter: filter, cursor: cursor, limit: 20)
                        pages += 1; candidates += page.items.count
                        matches += try page.items.filter { try criteria.matches($0) }.count
                        cursor = page.metadata.nextCursor
                    } while pages < 4 && cursor != nil
                    report["priorStrategy"] = ["anchor": anchor.name, "pages": pages, "candidateRecords": candidates, "matches": matches, "next": cursor != nil, "pageSize": 20]
                }
                var cursor: String?, pages = 0, matches = 0, allMatched = true
                var progress: SearchScanProgress?
                repeat {
                    let page = try await session.searchMediaPage(target: .combined(criteria), filter: filter, cursor: cursor, includeTags: true)
                    pages += 1; matches += page.items.count
                    let pageMatched = try page.items.allSatisfy { try criteria.matches($0) }
                    allMatched = allMatched && pageMatched
                    progress = page.searchProgress; cursor = page.metadata.nextCursor
                } while pages < 4 && matches == 0 && cursor != nil
                report["conjunction"] = ["status": matches > 0 ? "PASS" : (cursor == nil ? "EMPTY_EXHAUSTED" : "INCOMPLETE_BOUNDED_SCAN"),
                                          "matches": matches, "allConditionsMatched": allMatched, "next": cursor != nil,
                                          "candidatePages": progress?.pages ?? 0, "selectedLaneRecords": progress?.candidates ?? 0,
                                          "anchor": tags.first(where: { $0.id == progress?.anchorTagID })?.name ?? "unknown", "pageSize": 100]
            }
        } catch { report["conjunction"] = failure(error) }
        let library = LocalTagLibrary.shared
        await library.bind(ownerID: session.tagLibraryOwnerID); library.setActive(true)
        for _ in 0..<8 {
            if library.canNetwork { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        for prefix in ["gaping", "realistic", "city", "f"] {
            library.requestSync(source: session, prefix: prefix, manual: true)
            await library.waitForSync()
        }
        do {
            let start = Date()
            let remoteReads = session.tagRPCReads
            let named = try await session.catalogTags(keyword: "gaping", page: 1)
            let common = try await session.commonTags()
            let f = try await session.catalogTags(keyword: "f", page: 1)
            let first = try await session.directoryPage(mode: .catalog, keyword: "", cursor: nil)
            var secondIDs = Set<Int>()
            if let cursor = first.next {
                let second = try await session.directoryPage(mode: .catalog, keyword: "", cursor: cursor)
                secondIDs = Set(second.items.map(\.id))
            }
            report["localLibrary"] = ["status": named.contains(where: { $0.name == "gaping" }) ? "PASS" : "INCOMPLETE",
                                       "stored": library.stats.stored, "visible": library.stats.visible, "bytes": library.stats.bytes,
                                       "commonCount": common.count, "queryFCount": f.count, "exactGapingFound": named.contains { $0.name == "gaping" },
                                       "queryDurationMilliseconds": Date().timeIntervalSince(start) * 1000,
                                       "tagNetworkReadsDuringLocalQueries": session.tagRPCReads - remoteReads,
                                       "twoLocalPagesDisjoint": Set(first.items.map(\.id)).isDisjoint(with: secondIDs),
                                       "localSecondPageCount": secondIDs.count,
                                       "libraryError": library.error == nil ? "NONE" : "SYNC_ERROR", "wholeSiteComplete": false]
        } catch { report["localLibrary"] = failure(error) }
        report["sameAccountContext"] = identity == session.feedIdentity; report["finished"] = true
        write(report, filename: "local-search-build\(build).json")
    }
    private static func probeTag(_ keyword: String, session: SiteSession) async {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        let identity = session.feedIdentity
        var report: [String: Any] = ["build": build, "keyword": keyword, "readOnly": true, "metadataOnly": true,
                                   "authenticated": session.account != nil, "vocabularyScope": "All public tag types without client grade/class filters"]
        struct Page: Decodable { let items: [SearchTag] }
        do {
            let values = try await session.catalogTags(keyword: keyword, page: 1)
            report["clientLookup"] = ["status": "PASS_RESPONSE", "count": values.count,
                                      "hasExactName": values.contains { TagPolicy.normalize($0.name) == TagPolicy.normalize(keyword) },
                                      "prefixMatched": values.allSatisfy { MediaSearchText.matchesPrefix($0.name, keyword: keyword) }]
        } catch { report["clientLookup"] = failure(error) }
        let common: [String: Any] = ["query": keyword, "limit": 20, "page": 1, "include": ["nsfwLevel"]]
        var variants: [(String, [String: Any])] = []
        var scoped = common; scoped["entityType"] = ["Image"]; scoped["moderation"] = false; scoped["nsfwLevel"] = 31
        variants.append(("imageOnlyControl", scoped))
        var noGrade = scoped; noGrade.removeValue(forKey: "nsfwLevel"); variants.append(("withoutGradeFilter", noGrade))
        var withModeration = scoped; withModeration.removeValue(forKey: "moderation"); variants.append(("includingModerationTypes", withModeration))
        var anyTarget = scoped; anyTarget.removeValue(forKey: "entityType"); variants.append(("anyTarget", anyTarget))
        variants.append(("publicMetadata", common))
        for (name, input) in variants {
            do {
                let page: Page = try await session.rpc("tag.getAll", input: input)
                report[name] = ["status": "PASS_RESPONSE", "count": page.items.count,
                                "hasExactName": page.items.contains { TagPolicy.normalize($0.name) == TagPolicy.normalize(keyword) },
                                "prefixMatched": page.items.allSatisfy { MediaSearchText.matchesPrefix($0.name, keyword: keyword) },
                                "grades": Set(page.items.compactMap(\.nsfwLevel)).sorted()]
            } catch { report[name] = failure(error) }
        }
        do {
            if let exact = try await session.exactTag(name: keyword) {
                report["exact"] = ["status": "PASS", "validID": exact.id > 0]
                struct Info: Decodable { let id: Int; let name: String; let type: String }
                do {
                    let info: Info? = try await session.rpc("tag.getById", input: ["id": exact.id])
                    report["exactMetadata"] = ["status": info == nil ? "EMPTY" : "PASS", "type": info?.type ?? "unknown",
                                               "identityMatched": info?.id == exact.id && TagPolicy.normalize(info?.name ?? "") == TagPolicy.normalize(keyword)]
                } catch { report["exactMetadata"] = failure(error) }
            } else { report["exact"] = ["status": "NOT_RESOLVED"] }
        } catch { report["exact"] = failure(error) }
        report["sameAccountContext"] = identity == session.feedIdentity; report["finished"] = true
        write(report, filename: "tag-probe-build\(build).json")
    }
    /// At most three metadata-only requests. No media bytes, identities, URLs or
    /// credentials are exported, and no account or collection state is changed.
    private static func durationReadback(session: SiteSession) async {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        let identity = session.feedIdentity
        var report: [String: Any] = ["build": build, "readOnly": true, "authenticated": session.account != nil,
                                    "scope": "20 PG video records per path; duration metadata only", "wholeSiteComplete": false]
        guard session.account != nil else {
            report["status"] = "AUTH_UNAVAILABLE"; report["finished"] = true
            write(report, filename: "video-duration-build\(build).json"); return
        }
        do {
            let index: VideoDurationMetadataPage = try await session.rpc("image.getInfinite", input: ["types": ["video"], "limit": 20,
                "sort": "Newest", "period": "AllTime", "browsingLevel": 1, "include": [String]()])
            let known = index.items.compactMap { $0.metadata?.duration }
            report["index"] = ["status": index.items.isEmpty ? "EMPTY_RESPONSE" : "PASS_RESPONSE", "returned": index.items.count,
                               "knownSeconds": known.count, "unknown": index.items.count - known.count,
                               "atLeast120": known.filter { $0 >= 120 }.count]
        } catch { report["index"] = failure(error) }
        guard identity == session.feedIdentity else {
            report["status"] = "CONTEXT_CHANGED"; report["finished"] = true
            write(report, filename: "video-duration-build\(build).json"); return
        }
        do {
            let filter = FeedFilter(kind: .video, sort: "Newest", period: "AllTime", onlyPG: true, videoDurationRange: .init())
            let page = try await session.mediaPage(filter: filter, cursor: nil, creator: nil, followed: false, includeTags: false)
            let enriched = try await session.enrichVideoDurations(in: page, filter: filter) { identity == session.feedIdentity }
            report["restAndBoundedEnrichment"] = ["status": enriched.durationEnrichmentFailed ? "METADATA_READ_FAILED" : "PASS_RESPONSE",
                "returned": page.items.count, "knownBefore": page.items.filter { $0.durationSeconds != nil }.count,
                "knownAfter": enriched.items.filter { $0.durationSeconds != nil }.count,
                "unknownAfter": enriched.items.filter { $0.durationSeconds == nil }.count,
                "atLeast120": enriched.items.filter { ($0.durationSeconds ?? -1) >= 120 }.count]
        } catch { report["restAndBoundedEnrichment"] = failure(error) }
        report["sameAccountContext"] = identity == session.feedIdentity
        report["status"] = identity == session.feedIdentity ? "FINISHED_READBACK" : "CONTEXT_CHANGED"
        report["finished"] = true
        write(report, filename: "video-duration-build\(build).json")
    }

    private static func write(_ report: [String: Any], filename: String) {
        do {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("QAReadback", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: root.appendingPathComponent(filename), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { /* Do not log the session or raw errors if evidence writing fails. */ }
    }
    private static func failure(_ error: Error) -> [String: Any] {
        if case ClientError.http(let code) = error { return ["status": "FAILED", "httpStatus": code] }
        if let value = error as? ClientError {
            let category: String
            switch value { case .format: category = "FORMAT_OR_SCOPE"; case .invalidResponse: category = "INVALID_RESPONSE"; case .accountChanged: category = "CONTEXT_CHANGED"; case .signedOut: category = "AUTH_UNAVAILABLE"; default: category = "CLIENT_ERROR" }
            return ["status": "FAILED", "category": category]
        }
        return ["status": "FAILED", "errorType": String(describing: type(of: error))]
    }
}
#endif
