import Foundation
import WebKit
import Combine

/// OAuth credentials stay in this app's Keychain. A non-persistent real-origin
/// WebKit context is used only for anonymous site requests when needed.
@MainActor
final class SiteSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, PublicationSource, MediaSearchSource, TagDirectorySource, FollowingListSource, TagCandidateSource, TagLibrarySource, TimelineReading {
    static let origin = "https://civitai.red"
    @Published private(set) var account: Account?
    @Published private(set) var following = Set<Int>()
    @Published private(set) var followingRevision = 0
    @Published private(set) var followsKnown = false
    @Published private(set) var pendingUsers = Set<Int>()
    @Published private(set) var unknownUsers = Set<Int>()
    @Published var message: String?
    @Published var showLogin = false
    @Published private(set) var loginForCollections = false
    @Published private(set) var collections: [SavedCollection] = []
    @Published private(set) var collectionsKnown = false
    @Published private(set) var savedMemberships: [Int: Set<Int>] = [:]
    @Published private(set) var pendingFavorites = Set<Int>()
    @Published private(set) var collectionRevision = 0
    @Published private(set) var savedMembershipUpdate: SavedMembershipUpdate?
    private let collectionRead = CollectionRead<[SavedCollection]>()
    private var creatingCollection = false
    private var membershipReadAt: [Int: Date] = [:]
    private var membershipReads: [Int: CollectionRead<Set<Int>>] = [:]
    let oauth = OAuthLogin()
    let webView: WKWebView
    private var loadingDocument = false
    private var authGeneration = 0
    #if DEBUG
    private(set) var tagRPCReads = 0
    #endif
    var feedIdentity: String { "\(authGeneration):\(account?.id ?? -1):\(account?.browsingLevel ?? -1)" }
    var followingIdentity: String { "\(authGeneration):\(account?.id ?? -1):\(account?.username ?? "")" }
    var followingActorID: Int? { account?.id }
    var followingMemberIDs: Set<Int> { following }
    var tagLibraryOwnerID: Int? { account?.id ?? oauth.storedAccountID }
    var tagLibraryIdentity: String { "\(authGeneration):\(tagLibraryOwnerID ?? -1)" }
    var tagLookupIdentity: String { tagLibraryIdentity + "|" + feedIdentity }

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.allowsInlineMediaPlayback = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        oauth.onAuthenticated = { [weak self] in
            self?.authGeneration += 1
            self?.clearCollectionState()
            self?.account = nil
            self?.showLogin = false
            await self?.refreshAccount()
        }
    }

    var hasCollectionAccess: Bool {
        #if DEBUG && targetEnvironment(simulator)
        if CollectionPagingQA.enabled {
            return !ProcessInfo.processInfo.arguments.contains("--qa-no-collection-access49") && account?.id == CollectionPagingQA.ownerID
        }
        #endif
        return account != nil && oauth.hasCollectionAccess
    }
    #if DEBUG && targetEnvironment(simulator)
    func configureForCollectionPagingQA() {
        guard CollectionPagingQA.enabled else { return }
        if ProcessInfo.processInfo.arguments.contains("--qa-tag-availability55") {
            UserDefaults.standard.set(false, forKey: "tagDirectory.showSparse")
        }
        account = Account(id: CollectionPagingQA.ownerID, username: "PagingFixture", browsingLevel: 1,
                          blurNsfw: ProcessInfo.processInfo.arguments.contains("--qa-image-failure55"))
        collections = [CollectionPagingQA.collection]; collectionsKnown = true
        if VisualControlsQA.enabled {
            following = []; followsKnown = true; savedMemberships = [:]
            if VisualControlsQA.state == "busy" { pendingUsers = [VisualControlsQA.creatorID] }
            if VisualControlsQA.state == "unknown" { unknownUsers = [VisualControlsQA.creatorID] }
        }
        if ViewportAuditQA.enabled { following = [CollectionPagingQA.ownerID]; followsKnown = true }
    }
    #endif
    var defaultCollectionIDs: Set<Int> {
        guard let actorID = account?.id else { return [] }
        let available = Set(collections.map(\.id))
        let remembered = Set(UserDefaults.standard.array(forKey: "favoriteFolders.\(actorID)") as? [Int] ?? []).intersection(available)
        if !remembered.isEmpty { return remembered }
        if let folder = collections.first(where: { $0.name == "收藏作品" && $0.read == "Private" }) ?? collections.first(where: { $0.read == "Private" }) { return [folder.id] }
        return []
    }
    func rememberCollectionSelection(_ ids: Set<Int>) {
        guard let actorID = account?.id, !ids.isEmpty else { return }
        UserDefaults.standard.set(ids.sorted(), forKey: "favoriteFolders.\(actorID)")
    }

    func openLogin(forCollections: Bool = false) {
        loginForCollections = forCollections || oauth.hasCollectionAccess
        showLogin = true
    }

    func refreshAccount() async {
        #if DEBUG && targetEnvironment(simulator)
        if ViewportAuditQA.enabled { return }
        if ResumePromptQA.enabled { return }
        #endif
        let generation = authGeneration
        guard oauth.hasCredentials else { account = nil; following = []; followsKnown = false; clearCollectionState(); return }
        do {
            let value: Account? = try await request(path: "/api/auth/session", sessionIdentityOnly: true)
            guard generation == authGeneration, oauth.hasCredentials else { return }
            if account?.id != value?.id { following = []; followsKnown = false; unknownUsers = []; clearCollectionState() }
            account = value
            if let value { try? oauth.bindAccountIdentity(value.id) }
            if value != nil { try await refreshFollowing() }
            else { following = []; followsKnown = false }
        } catch ClientError.signedOut {
            guard generation == authGeneration else { return }
            account = nil; following = []; followsKnown = false; message = ClientError.signedOut.localizedDescription
        } catch { message = error.localizedDescription }
    }

    func refreshFollowing() async throws {
        #if DEBUG && targetEnvironment(simulator)
        if ViewportAuditQA.enabled { return }
        #endif
        guard let actorID = account?.id else { throw ClientError.signedOut }
        let generation = authGeneration
        do {
            let ids: [Int] = try await rpc("user.getFollowingUsers")
            guard generation == authGeneration, account?.id == actorID, oauth.hasCredentials else { throw ClientError.accountChanged }
            let confirmed = Set(ids)
            if confirmed != following { followingRevision += 1 }
            following = confirmed; followsKnown = true; unknownUsers = []
        } catch ClientError.signedOut {
            guard generation == authGeneration, account?.id == actorID else { throw ClientError.accountChanged }
            account = nil; following = []; followsKnown = false
            throw ClientError.signedOut
        }
    }

    #if DEBUG && targetEnvironment(simulator)
    func configureForResumePromptQA() {
        guard ResumePromptQA.enabled else { return }
        account = Account(id: ResumePromptQA.ownerID, username: "NativeResumePattern", browsingLevel: 1, blurNsfw: false)
        following = ResumePromptQA.scenario.contains("following") ? [ResumePromptQA.ownerID] : []
        followsKnown = true; authGeneration = 29_001
    }
    #endif

    func refreshFollowingIDs() async throws -> Set<Int> {
        let identity = followingIdentity
        try await refreshFollowing()
        guard identity == followingIdentity else { throw ClientError.accountChanged }
        return following
    }

    func followingPage(page: Int, limit: Int) async throws -> FollowingPage {
        guard let actor = account, !actor.username.isEmpty else { throw ClientError.signedOut }
        guard page > 0, (1...200).contains(limit) else { throw ClientError.invalidResponse }
        let identity = followingIdentity
        let result: FollowingPage = try await rpc("user.getList", input: ["username": actor.username, "type": "following", "page": page, "limit": limit])
        guard identity == followingIdentity, oauth.hasCredentials else { throw ClientError.accountChanged }
        return result
    }

    func setFollowing(_ desired: Bool, creator: Creator) async {
        #if DEBUG && targetEnvironment(simulator)
        if VisualControlsQA.enabled {
            guard account?.id == CollectionPagingQA.ownerID, creator.id == VisualControlsQA.creatorID else { return }
            if desired { following.insert(creator.id) } else { following.remove(creator.id) }
            return // Controlled in-memory interaction; never issue a site write.
        }
        #endif
        guard let actorID = account?.id else { message = ClientError.signedOut.localizedDescription; return }
        guard pendingUsers.isEmpty else { return }
        pendingUsers.insert(creator.id)
        defer { pendingUsers.remove(creator.id) }
        // This is a toggle API: always read before deciding to issue ONE mutation.
        do {
            let identity: Account? = try await request(path: "/api/auth/session", sessionIdentityOnly: true)
            guard identity?.id == actorID else {
                account = identity; following = []; followsKnown = false
                throw ClientError.accountChanged
            }
            try await refreshFollowing()
            guard following.contains(creator.id) != desired else { return }
            guard account?.id == actorID && !showLogin else { throw ClientError.accountChanged }
        } catch { message = error.localizedDescription; return }
        do {
            let _: FollowResult = try await rpc("user.toggleFollow", input: ["targetUserId": creator.id, "username": creator.username], mutation: true)
            try await refreshFollowing()
            if following.contains(creator.id) != desired {
                unknownUsers.insert(creator.id); message = ClientError.writeUnknown.localizedDescription
            }
        } catch {
            // A timeout may have happened after the write. Read back, never auto-toggle again.
            do {
                try await refreshFollowing()
                if following.contains(creator.id) != desired {
                    unknownUsers.insert(creator.id); message = ClientError.writeUnknown.localizedDescription
                }
            } catch {
                unknownUsers.insert(creator.id); message = ClientError.writeUnknown.localizedDescription
            }
        }
    }

    func mediaPage(filter: FeedFilter, cursor: String?, creator: Creator?, followed: Bool = false, includeTags: Bool = false) async throws -> MediaPage {
        #if DEBUG && targetEnvironment(simulator)
        if AutoContinuationQA.enabled { return try await AutoContinuationQA.page(filter: filter, cursor: cursor) }
        if ViewportAuditQA.enabled { return ViewportAuditQA.page(filter: filter, cursor: cursor, creator: creator) }
        if CollectionPagingQA.enabled {
            return MediaPage(items: cursor == nil ? CollectionPagingQA.items.filter { filter.effectiveKind == .all || $0.isVideo == (filter.effectiveKind == .video) } : [], metadata: .init(nextCursor: nil))
        }
        if ResumePromptQA.enabled {
            ResumePromptQA.recordPageRequest(filter: filter, cursor: cursor, creator: creator, followed: followed)
            if ResumePromptQA.scenario == "restart-presentation" {
                if cursor == nil { return MediaPage(items: ResumePromptQA.items, metadata: .init(nextCursor: "qa-next")) }
                var next = MediaItem(id: ResumePromptQA.itemIDs[3], url: "https://example.invalid/extra-paging-image.png", width: 192, height: 256,
                                 type: "image", username: "NativeResumePattern", browsingLevel: 1, thumbnail: nil, creatorID: ResumePromptQA.ownerID, tags: [])
                next.offlineMediaURL = ResumePromptQA.imageURL(for: next.id)
                return MediaPage(items: [next], metadata: .init(nextCursor: nil))
            }
            if ResumePromptQA.scenario.hasPrefix("restart-short-"), cursor != nil { throw ClientError.http(503) }
            if ResumePromptQA.manualUI, ResumePromptQA.scenario == "restore-stale-cursor", cursor != nil {
                throw ClientError.http(503)
            }
            if ResumePromptQA.manualUI, ResumePromptQA.scenario == "restore-legacy-nil-then-restart-failure", cursor == nil {
                throw ClientError.http(503)
            }
            return MediaPage(items: ResumePromptQA.items, metadata: .init(nextCursor: nil))
        }
        #endif
        if followed { return try await followingPage(filter: filter, cursor: cursor, includeTags: includeTags) }
        var components = URLComponents(string: Self.origin + "/api/v1/images")!
        components.queryItems = filter.query(cursor: cursor, creator: creator)
        if includeTags { components.queryItems?.append(.init(name: "withTags", value: "true")) }
        if !filter.onlyPG, let level = account?.browsingLevel {
            components.queryItems?.append(.init(name: "browsingLevel", value: String(level)))
        }
        if oauth.hasCredentials {
            return try await request(path: components.url!.path + "?" + (components.percentEncodedQuery ?? ""))
        }
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard let response = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        if response.statusCode == 403 {
            // Some site edges reject non-browser clients. Use the real embedded
            // website session; do not spoof browser headers or bypass challenges.
            return try await request(path: components.url!.path + "?" + (components.percentEncodedQuery ?? ""))
        }
        guard response.statusCode == 200 else { throw ClientError.http(response.statusCode) }
        return try JSONDecoder().decode(MediaPage.self, from: data)
    }

    private func followingPage(filter: FeedFilter, cursor: String?, includeTags: Bool) async throws -> MediaPage {
        guard account != nil else { throw ClientError.signedOut }
        if !followsKnown { try await refreshFollowing() }
        // The website's old DB route can fall back to a global feed for zero follows.
        // Refuse that meaning: an empty following set is an empty following feed.
        guard !following.isEmpty else { return MediaPage(items: [], metadata: .init(nextCursor: nil)) }
        var input: [String: Any] = ["followed": true, "limit": 20, "sort": filter.sort,
                                    "period": filter.period, "include": [String]()]
        if let cursor { input["cursor"] = cursor }
        if filter.effectiveKind != .all { input["types"] = [filter.effectiveKind.rawValue] }
        if !filter.baseModel.isEmpty { input["baseModels"] = [filter.baseModel] }
        input["browsingLevel"] = filter.onlyPG ? 1 : (account?.browsingLevel ?? 1)
        let identity = feedIdentity
        let page: FollowingIndexPage = try await rpc("image.getInfinite", input: input)
        guard identity == feedIdentity else { throw ClientError.accountChanged }
        let scoped = page.items.filter { following.contains($0.user.id) }
        guard !scoped.isEmpty else { return MediaPage(items: [], metadata: .init(nextCursor: page.nextCursor)) }
        // One batched hydration gives us the site's real media URLs and safe video
        // thumbnails. It is not one request per creator or per media item.
        var components = URLComponents(string: "/api/v1/images")!
        components.queryItems = [
            .init(name: "ids", value: scoped.map { String($0.id) }.joined(separator: ",")),
            .init(name: "limit", value: String(scoped.count)),
            .init(name: "browsingLevel", value: String(filter.onlyPG ? 1 : (account?.browsingLevel ?? 1)))
        ]
        if includeTags { components.queryItems?.append(.init(name: "withTags", value: "true")) }
        let media: MediaPage = try await request(path: components.string!)
        guard identity == feedIdentity else { throw ClientError.accountChanged }
        let byID = Dictionary(media.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = scoped.compactMap { row -> MediaItem? in
            guard var item = byID[row.id] else { return nil }
            item.creatorID = row.user.id
            if let metadata = row.metadata { item.metadata = metadata }
            return item
        }
        return MediaPage(items: ordered, metadata: .init(nextCursor: page.nextCursor))
    }

    /// `postIds` with original IDs selects the official narrow DB route, whose
    /// technical metadata includes duration. IDs alone can use an index without it.
    func videoDurationMetadata(ids: [Int], postIDs: [Int], onlyPG: Bool) async throws -> [VideoDurationRecord] {
        guard !ids.isEmpty, ids.count <= 20, Set(ids).count == ids.count,
              ids.allSatisfy({ $0 > 0 }), !postIDs.isEmpty, postIDs.count <= ids.count,
              Set(postIDs).count == postIDs.count, postIDs.allSatisfy({ $0 > 0 }) else {
            throw ClientError.format("视频时长范围")
        }
        let identity = feedIdentity
        let result: VideoDurationMetadataPage = try await rpc("image.getInfinite", input: [
            "ids": ids, "postIds": postIDs, "types": ["video"], "limit": ids.count,
            "browsingLevel": onlyPG ? 1 : (account?.browsingLevel ?? 1), "include": [String]()
        ])
        guard identity == feedIdentity else { throw ClientError.accountChanged }
        return result.items.filter { ids.contains($0.id) }
    }

    func creator(username: String) async throws -> Creator {
        #if DEBUG && targetEnvironment(simulator)
        if CollectionPagingQA.enabled { return Creator(id: VisualControlsQA.enabled ? VisualControlsQA.creatorID : CollectionPagingQA.ownerID, username: username) }
        #endif
        var components = URLComponents(string: Self.origin + "/api/v1/users")!
        components.queryItems = [.init(name: "query", value: username)]
        let response: UserPage = try await request(path: components.url!.path + "?" + (components.percentEncodedQuery ?? ""))
        guard let creator = response.items.first(where: { $0.username.lowercased() == username.lowercased() }) else { throw ClientError.missingCreator }
        return creator
    }

    func creatorBiography(_ creator: Creator) async throws -> CreatorBiography {
        #if DEBUG && targetEnvironment(simulator)
        if CollectionPagingQA.enabled {
            let variant = CollectionPagingQA.biographyCase ?? "english"
            return CreatorBiography(id: creator.id, username: creator.username, profile: .init(bio: CollectionPagingQAView.biography(variant)), blockedByThem: false)
        }
        #endif
        let identity = feedIdentity
        let result: CreatorBiography = try await rpc("userProfile.get", input: ["username": creator.username])
        guard identity == feedIdentity, result.id == creator.id else { throw ClientError.accountChanged }
        return result
    }

    func creators(ids: [Int]) async throws -> [Creator] {
        guard !ids.isEmpty else { return [] }
        var components = URLComponents(string: Self.origin + "/api/v1/users")!
        components.queryItems = [.init(name: "ids", value: ids.map(String.init).joined(separator: ","))]
        let page: UserPage = try await request(path: components.url!.path + "?" + (components.percentEncodedQuery ?? ""))
        return page.items
    }

    func leaderboard(_ board: Board) async throws -> [LeaderboardEntry] {
        #if DEBUG && targetEnvironment(simulator)
        if CollectionPagingQA.enabled {
            return (0..<8).map { index in
                LeaderboardEntry(position: index + 1, user: Creator(id: CollectionPagingQA.ownerID + index, username: "Pattern Creator \(index + 1)"))
            }
        }
        #endif
        return try await rpc(board.procedure, input: ["id": "images-nsfw"])
    }

    func latestPublication(creator: Creator) async throws -> PublicationResult {
        let identity = feedIdentity
        var cursor: PublicationCursor?
        var scan = PublicationScan(creatorID: creator.id)
        for _ in 0..<4 {
            try Task.checkCancellation()
            var input: [String: Any] = ["username": creator.username, "sort": "Newest", "period": "AllTime", "limit": 5,
                                        "browsingLevel": account?.browsingLevel ?? 1, "include": [String](), "draftOnly": false, "scheduled": false]
            if let cursor { input["cursor"] = cursor.value }
            let page: PublicationPage = try await rpc("post.getInfinite", input: input)
            guard identity == feedIdentity else { throw ClientError.accountChanged }
            if let result = scan.consume(page) { return result }
            cursor = page.nextCursor
        }
        return .unverified // Bounded or incomplete scanning is never a negative result.
    }

    func mediaItem(id: Int, includeTags: Bool = true) async throws -> MediaItem? {
        try await mediaItems(ids: [id], includeTags: includeTags).first
    }

    func mediaItems(ids: [Int], includeTags: Bool = true) async throws -> [MediaItem] {
        #if DEBUG && targetEnvironment(simulator)
        if ViewportAuditQA.enabled { return ViewportAuditQA.mediaItems(ids: ids) }
        if ResumePromptQA.enabled {
            if ResumePromptQA.scenario == "restore-failure" {
                return ResumePromptQA.fixtureItems(for: ids.filter { $0 != ResumePromptQA.itemIDs[2] })
            }
            return ResumePromptQA.fixtureItems(for: ids)
        }
        #endif
        guard !ids.isEmpty, ids.count <= 30 else { return [] }
        var components = URLComponents(string: "/api/v1/images")!
        components.queryItems = [.init(name: "ids", value: ids.map(String.init).joined(separator: ",")), .init(name: "limit", value: String(ids.count)),
                                 .init(name: "browsingLevel", value: String(account?.browsingLevel ?? 1))]
        if includeTags { components.queryItems?.append(.init(name: "withTags", value: "true")) }
        let page: MediaPage = try await request(path: components.string!)
        guard page.items.allSatisfy({ ids.contains($0.id) }) else { throw ClientError.invalidResponse }
        return page.items
    }

    func searchAuthors(keyword: String) async throws -> [Creator] {
        #if DEBUG && targetEnvironment(simulator)
        if ViewportAuditQA.enabled {
            let creator = Creator(id: CollectionPagingQA.ownerID, username: "PagingFixture")
            return creator.username.localizedCaseInsensitiveContains(MediaSearchText.normalized(keyword)) ? [creator] : []
        }
        #endif
        guard MediaSearchText.valid(keyword, mode: .author) else { throw ClientError.format("作者关键词") }
        return try await rpc("user.getAll", input: ["query": MediaSearchText.normalized(keyword), "limit": 20, "include": [String]()])
    }

    func searchTags(keyword: String, page: Int) async throws -> [SearchTag] {
        guard MediaSearchText.valid(keyword, mode: .tag), page > 0 else { throw ClientError.format("标签关键词") }
        return try await LocalTagLibrary.shared.legacyPage(ownerID: tagLibraryOwnerID, keyword: keyword, page: page)
    }

    func commonTags() async throws -> [SearchTag] {
        try await LocalTagLibrary.shared.legacyPage(ownerID: tagLibraryOwnerID, keyword: "", page: 1, common: true)
    }
    func catalogTags(keyword: String, page: Int) async throws -> [SearchTag] {
        guard page > 0, keyword.isEmpty || MediaSearchText.valid(keyword, mode: .tag) else { throw ClientError.format("标签目录查询") }
        return try await LocalTagLibrary.shared.legacyPage(ownerID: tagLibraryOwnerID, keyword: keyword, page: page)
    }
    func directoryPage(mode: TagDirectoryMode, keyword: String, cursor: TagDirectoryCursor?) async throws -> TagDirectoryPage {
        #if DEBUG && targetEnvironment(simulator)
        if CollectionPagingQA.enabled && (ProcessInfo.processInfo.arguments.contains("--qa-style48") || ProcessInfo.processInfo.arguments.contains("--qa-tag-availability55")) {
            let normalized = TagPolicy.normalize(keyword)
            let tags = CollectionPagingQA.neutralDetailsTags.compactMap { value -> SearchTag? in
                guard let id = value.id, let name = value.name,
                      normalized.isEmpty || TagPolicy.normalize(name).contains(normalized) else { return nil }
                return SearchTag(id: id, name: name)
            }
            return .init(items: cursor == nil ? tags : [], next: nil)
        }
        #endif
        let result = try await LocalTagLibrary.shared.page(ownerID: tagLibraryOwnerID, keyword: keyword, common: mode == .common, cursor: cursor?.local, limit: mode == .common ? 200 : 20)
        return .init(items: result.items, next: result.next.map { .init(page: (cursor?.page ?? 1) + 1, local: $0) })
    }
    func onlineTagPage(mode: TagDirectoryMode, keyword: String, page: Int) async throws -> [SearchTag]? {
        #if DEBUG && targetEnvironment(simulator)
        if CollectionPagingQA.enabled && (ProcessInfo.processInfo.arguments.contains("--qa-style48") || ProcessInfo.processInfo.arguments.contains("--qa-tag-availability55")) {
            if mode == .common && keyword.isEmpty {
                return CollectionPagingQA.neutralDetailsTags.compactMap { value in
                    guard let id = value.id, let name = value.name else { return nil }
                    return SearchTag(id: id, name: name)
                }
            }
            return []
        }
        #endif
        guard page > 0, keyword.isEmpty || MediaSearchText.valid(keyword, mode: .tag) else { throw ClientError.format("标签查询") }
        let identity = tagLookupIdentity
        let result: [SearchTag]
        if mode == .common && keyword.isEmpty { result = try await remoteCommonTags() }
        else {
            struct TagPage: Decodable { let items: [SearchTag] }
            let response: TagPage = try await rpc("tag.getAll", input: TagCatalogQuery.input(keyword: keyword, page: page))
            result = response.items
        }
        guard identity == tagLookupIdentity else { throw ClientError.accountChanged }
        return result
    }
    func rememberTags(_ tags: [SearchTag], common: Bool, identity: String) async throws {
        guard identity == tagLookupIdentity, !Task.isCancelled else { throw ClientError.accountChanged }
        try await LocalTagLibrary.shared.rememberDiscovered(ownerID: tagLibraryOwnerID, tags: tags, common: common)
        guard identity == tagLookupIdentity else { throw ClientError.accountChanged }
    }
    func remoteTagPage(prefix: String, page: Int, limit: Int) async throws -> [SearchTag] {
        guard MediaSearchText.valid(prefix, mode: .tag), page > 0, (1...200).contains(limit) else { throw LocalTagError.invalidPage }
        struct TagPage: Decodable { let items: [SearchTag] }
        var input = TagCatalogQuery.input(keyword: prefix, page: page); input["limit"] = limit
        let result: TagPage = try await rpc("tag.getAll", input: input)
        return result.items
    }
    func remoteCommonTags() async throws -> [SearchTag] { try await rpc("tag.getFeedTagBar") }
    func exactTag(name: String) async throws -> SearchTag? {
        let name = MediaSearchText.normalized(name)
        guard !name.isEmpty else { throw ClientError.invalidResponse }
        let tags: [SearchTag] = try await rpc("tag.getTagWithModelCount", input: ["name": name])
        return tags.first { $0.id > 0 && TagPolicy.normalize($0.name) == TagPolicy.normalize(name) }
    }

    func searchTitlePosts(keyword: String, filter: FeedFilter, cursor: PublicationCursor?) async throws -> SearchPostPage {
        guard MediaSearchText.valid(keyword, mode: .title) else { throw ClientError.format("标题关键词") }
        var input: [String: Any] = ["query": MediaSearchText.normalized(keyword), "limit": 5, "sort": filter.sort, "period": filter.period,
                                   "include": [String](), "draftOnly": false, "scheduled": false,
                                   "browsingLevel": filter.onlyPG ? 1 : (account?.browsingLevel ?? 1)]
        if let cursor { input["cursor"] = cursor.value }
        return try await rpc("post.getInfinite", input: input)
    }

    func searchPostMedia(postID: Int, filter: FeedFilter, cursor: String?, includeTags: Bool) async throws -> MediaPage {
        guard postID > 0 else { throw ClientError.invalidResponse }
        return try await scopedSearchMedia(filter: filter, cursor: cursor, extra: [.init(name: "postId", value: String(postID))], includeTags: includeTags)
    }

    func searchMediaPage(target: MediaSearchTarget, filter: FeedFilter, cursor: String?, includeTags: Bool) async throws -> MediaPage {
        #if DEBUG && targetEnvironment(simulator)
        if ViewportAuditQA.enabled { return try ViewportAuditQA.searchPage(target: target, filter: filter, cursor: cursor) }
        #endif
        switch target {
        case .author(let creator):
            let page = try await mediaPage(filter: filter, cursor: cursor, creator: creator, includeTags: includeTags)
            guard page.items.allSatisfy({ $0.username?.lowercased() == creator.username.lowercased() }) else { throw ClientError.format("作者搜索返回范围不符") }
            return page
        case .tag(let tag):
            guard tag.id > 0 else { throw ClientError.invalidResponse }
            let page = try await scopedSearchMedia(filter: filter, cursor: cursor, extra: [.init(name: "tags", value: String(tag.id))], includeTags: true)
            guard page.items.allSatisfy({ $0.tags?.contains(where: { $0.id == tag.id }) == true }) else { throw ClientError.format("标签搜索返回范围待核实") }
            return page
        case .title(let keyword):
            return try await TitleMediaPager.page(keyword: keyword, filter: filter, cursor: cursor, includeTags: includeTags, source: self)
        case .combined(let criteria):
            guard criteria.valid else { throw ClientError.format("请至少选择一个有效搜索条件") }
            if !criteria.normalizedText.isEmpty {
                return try await TitleMediaPager.page(keyword: criteria.normalizedText, filter: filter, cursor: cursor, includeTags: true, source: self, criteria: criteria)
            }
            if criteria.tags.count > 1 {
                return try await TagConjunctionPager.page(criteria: criteria, filter: filter, cursor: cursor, source: self)
            }
            let firstTag = criteria.tags.sorted { $0.id < $1.id }.first
            let extra: [URLQueryItem] = firstTag.map { [.init(name: "tags", value: String($0.id))] } ?? []
            let page = try await scopedSearchMedia(filter: filter, cursor: cursor, extra: extra, includeTags: true, creator: criteria.author)
            if let author = criteria.author {
                guard page.items.allSatisfy({ $0.username?.lowercased() == author.username.lowercased() }) else { throw ClientError.format("作者搜索返回范围不符") }
            }
            if let firstTag {
                guard page.items.allSatisfy({ $0.tags?.contains(where: { $0.id == firstTag.id }) == true }) else { throw ClientError.format("标签搜索返回范围待核实") }
            }
            return .init(items: try page.items.filter { try criteria.matches($0) }, metadata: page.metadata)
        }
    }

    func tagCandidates(tagID: Int, author: Creator?, filter: FeedFilter, cursor: String?, limit: Int) async throws -> MediaPage {
        guard tagID > 0, (1...100).contains(limit) else { throw ClientError.invalidResponse }
        #if DEBUG && targetEnvironment(simulator)
        if CollectionPagingQA.enabled && ProcessInfo.processInfo.arguments.contains("--qa-tag-availability55") {
            if tagID == 42_002 { return .init(items: [], metadata: .init(nextCursor: nil)) }
            if tagID == 42_003 { throw URLError(.timedOut) }
            let items = (0..<3).map { offset in
                MediaItem(id: 55_100 + offset, url: "", width: 1, height: 1, type: offset == 0 ? "video" : "image",
                          username: "LocalFixture", browsingLevel: 1, thumbnail: nil, tags: [.init(id: tagID, name: "fixture")])
            }
            return .init(items: items, metadata: .init(nextCursor: nil))
        }
        #endif
        return try await scopedSearchMedia(filter: filter, cursor: cursor, extra: [.init(name: "tags", value: String(tagID))], includeTags: true, creator: author, limit: limit)
    }

    private func scopedSearchMedia(filter: FeedFilter, cursor: String?, extra: [URLQueryItem], includeTags: Bool, creator: Creator? = nil, limit: Int = 20) async throws -> MediaPage {
        var components = URLComponents(string: "/api/v1/images")!
        components.queryItems = filter.query(cursor: cursor, creator: creator) + extra
        components.queryItems?.removeAll { $0.name == "limit" }
        components.queryItems?.append(.init(name: "limit", value: String(limit)))
        if includeTags { components.queryItems?.append(.init(name: "withTags", value: "true")) }
        if !filter.onlyPG { components.queryItems?.append(.init(name: "browsingLevel", value: String(account?.browsingLevel ?? 1))) }
        return try await request(path: components.string!)
    }

    func saveBrowsingPreferences(level: Int, blur: Bool?) async -> Bool {
        guard let actorID = account?.id, (0...31).contains(level) else { message = ClientError.signedOut.localizedDescription; return false }
        var input: [String: Any] = ["browsingLevel": level]
        if let blur { input["blurNsfw"] = blur }
        do {
            let identity: Account? = try await request(path: "/api/auth/session", sessionIdentityOnly: true)
            guard identity?.id == actorID else { throw ClientError.accountChanged }
            do { let _: Bool? = try await rpc("user.updateBrowsingMode", input: input, mutation: true) }
            catch {
                // Do not repeat an ambiguous write. Continue with a server readback.
            }
            let updated: Account? = try await request(path: "/api/auth/session", sessionIdentityOnly: true)
            guard updated?.id == actorID, account?.id == actorID, oauth.hasCredentials else { throw ClientError.accountChanged }
            account = updated
            guard updated?.browsingLevel == level, blur == nil || updated?.blurNsfw == blur else {
                message = "服务器尚未确认这组偏好，保留当前读回值。"; return false
            }
            message = "账号偏好已读回确认。"; return true
        } catch { message = error.localizedDescription; return false }
    }

    private func clearCollectionState() {
        collectionRead.invalidate()
        for read in membershipReads.values { read.invalidate() }
        collections = []; collectionsKnown = false; savedMemberships = [:]
        membershipReadAt = [:]; membershipReads = [:]
        collectionRevision += 1
    }

    func refreshCollections() async throws {
        #if DEBUG && targetEnvironment(simulator)
        if CollectionPagingQA.enabled { return }
        #endif
        guard let actorID = account?.id else { throw ClientError.signedOut }
        guard hasCollectionAccess else { throw ClientError.collectionAuthorization }
        let generation = authGeneration
        _ = try await collectionRead.task(load: {
            let values: [SavedCollection] = try await self.rpc("collection.getAllUser", input: ["type": "Image", "contributingOnly": true])
            guard generation == self.authGeneration, self.account?.id == actorID, self.hasCollectionAccess else { throw ClientError.accountChanged }
            return values.filter { $0.isPersonalMedia(actorID: actorID) }.sorted {
                if ($0.mode == "Bookmark") != ($1.mode == "Bookmark") { return $0.mode == "Bookmark" }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }, commit: { values in self.collections = values; self.collectionsKnown = true }).value
        guard generation == authGeneration, account?.id == actorID, hasCollectionAccess else { throw ClientError.accountChanged }
    }

    @discardableResult
    func refreshSavedMembership(_ imageID: Int, force: Bool = false) async throws -> Set<Int> {
        #if DEBUG && targetEnvironment(simulator)
        if VisualControlsQA.enabled { return savedMemberships[imageID] ?? [] }
        if CollectionPagingQA.enabled {
            savedMemberships[imageID] = []; membershipReadAt[imageID] = Date()
            return []
        }
        #endif
        guard let actorID = account?.id, hasCollectionAccess else { throw ClientError.collectionAuthorization }
        if !force, let date = membershipReadAt[imageID], Date().timeIntervalSince(date) < 60,
           let known = savedMemberships[imageID] { return known }
        if !collectionsKnown { try await refreshCollections() }
        let generation = authGeneration
        let read = membershipReads[imageID] ?? CollectionRead<Set<Int>>()
        membershipReads[imageID] = read
        let ids = try await read.task(load: {
            let rows: [CollectionMembership] = try await self.rpc("collection.getUserCollectionItemsByItem", input: ["imageId": imageID, "type": "Image"])
            guard generation == self.authGeneration, self.account?.id == actorID, self.hasCollectionAccess else { throw ClientError.accountChanged }
            return Set(rows.map(\.collectionId)).intersection(Set(self.collections.map(\.id)))
        }, commit: { ids in self.savedMemberships[imageID] = ids; self.membershipReadAt[imageID] = Date() }).value
        guard generation == authGeneration, account?.id == actorID, hasCollectionAccess else { throw ClientError.accountChanged }
        return ids
    }

    private func invalidateMembershipRead(_ imageID: Int) {
        membershipReads[imageID]?.invalidate()
        membershipReadAt[imageID] = nil
    }

    /// Cleanup must also preserve references in shared/contest folders that the
    /// personal-folder picker intentionally does not offer for writes.
    func allSavedMembership(_ imageID: Int) async throws -> Set<Int> {
        guard let actorID = account?.id, hasCollectionAccess else { throw ClientError.collectionAuthorization }
        let generation = authGeneration
        let rows: [CollectionMembership] = try await rpc("collection.getUserCollectionItemsByItem", input: ["imageId": imageID, "type": "Image"])
        guard generation == authGeneration, account?.id == actorID, hasCollectionAccess else { throw ClientError.accountChanged }
        return Set(rows.map(\.collectionId))
    }

    func saveCollectionSelection(imageID: Int, original: Set<Int>, selected: Set<Int>) async throws {
        #if DEBUG && targetEnvironment(simulator)
        if VisualControlsQA.enabled {
            guard account?.id == CollectionPagingQA.ownerID,
                  CollectionPagingQA.items.contains(where: { $0.id == imageID }),
                  original == (savedMemberships[imageID] ?? []),
                  selected.isSubset(of: [CollectionPagingQA.collection.id]) else { throw ClientError.invalidResponse }
            savedMemberships[imageID] = selected; collectionRevision += 1
            return // Controlled in-memory interaction; never issue a site write.
        }
        #endif
        guard let actorID = account?.id, hasCollectionAccess else { throw ClientError.collectionAuthorization }
        guard pendingFavorites.isEmpty, !creatingCollection else { throw ClientError.collectionBusy }
        let generation = authGeneration
        pendingFavorites.insert(imageID); defer { pendingFavorites.remove(imageID) }
        invalidateMembershipRead(imageID)
        let identity: Account? = try await request(path: "/api/auth/session", sessionIdentityOnly: true)
        guard identity?.id == actorID, generation == authGeneration, !showLogin else { throw ClientError.accountChanged }
        try await refreshCollections()
        let current = try await refreshSavedMembership(imageID, force: true)
        let change = CollectionSelectionChange(original: original, selected: selected, editable: Set(collections.map(\.id)), current: current)
        guard !change.isEmpty else { return }
        guard generation == authGeneration, account?.id == actorID, !showLogin else { throw ClientError.accountChanged }
        do {
            let _: CollectionWriteResult = try await rpc("collection.saveItem", input: [
                "imageId": imageID, "type": "Image",
                "collections": change.additions.sorted().map { ["collectionId": $0] },
                "removeFromCollectionIds": change.removals.sorted()
            ], mutation: true)
        } catch {
            // The server may have committed before a timeout. Read, never replay.
        }
        collectionRevision += 1
        invalidateMembershipRead(imageID)
        do {
            let after = try await refreshSavedMembership(imageID, force: true)
            guard change.isConfirmed(by: after) else { throw ClientError.collectionWriteUnknown }
            savedMembershipUpdate = .init(accountID: actorID, imageID: imageID, collectionIDs: after)
        } catch {
            savedMemberships[imageID] = nil
            membershipReadAt[imageID] = nil
            throw ClientError.collectionWriteUnknown
        }
    }

    func createPrivateCollection(name: String) async throws -> SavedCollection {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf16.count <= 30, let actorID = account?.id, hasCollectionAccess else { throw ClientError.invalidResponse }
        guard !creatingCollection, pendingFavorites.isEmpty else { throw ClientError.collectionBusy }
        creatingCollection = true; defer { creatingCollection = false }
        let generation = authGeneration
        let identity: Account? = try await request(path: "/api/auth/session", sessionIdentityOnly: true)
        guard identity?.id == actorID, generation == authGeneration, !showLogin else { throw ClientError.accountChanged }
        try await refreshCollections()
        guard generation == authGeneration, account?.id == actorID, !showLogin else { throw ClientError.accountChanged }
        // Reuse an exact existing private folder rather than create duplicates on retry.
        if let existing = collections.first(where: { $0.name == name && $0.read == "Private" }) { return existing }
        let before = Set(collections.map(\.id))
        do {
            let _: SavedCollection = try await rpc("collection.upsert", input: ["name": name, "type": "Image", "read": "Private", "write": "Private"], mutation: true)
        } catch { /* Read back once; never repeat an uncertain create. */ }
        guard generation == authGeneration, account?.id == actorID else { throw ClientError.accountChanged }
        try await refreshCollections()
        let created = collections.filter { !before.contains($0.id) && $0.name == name && $0.read == "Private" }
        guard created.count == 1, let value = created.first else { throw ClientError.collectionWriteUnknown }
        collectionRevision += 1
        return value
    }

    func collectionPage(id: Int, filter: FeedFilter, cursor: String?, allAccessibleLevels: Bool = false, includeTags: Bool = false) async throws -> MediaPage {
        #if DEBUG && targetEnvironment(simulator)
        if CollectionPagingQA.enabled {
            guard id == CollectionPagingQA.collection.id else { throw ClientError.invalidResponse }
            return MediaPage(items: cursor == nil ? CollectionPagingQA.items.filter { filter.effectiveKind == .all || $0.isVideo == (filter.effectiveKind == .video) } : [], metadata: .init(nextCursor: nil))
        }
        #endif
        guard let actorID = account?.id, hasCollectionAccess else { throw ClientError.collectionAuthorization }
        let generation = authGeneration
        if !collectionsKnown { try await refreshCollections() }
        guard collections.contains(where: { $0.id == id }) else { throw ClientError.invalidResponse }
        let level = allAccessibleLevels ? 31 : (filter.onlyPG ? 1 : (account?.browsingLevel ?? 1))
        var input: [String: Any] = ["collectionId": id, "limit": 30, "browsingLevel": level]
        if let cursor { input["cursor"] = cursor }
        let index: CollectionIndexPage = try await rpc("collection.getAllCollectionItems", input: input)
        guard generation == authGeneration, account?.id == actorID else { throw ClientError.accountChanged }
        guard !index.mediaIDs.isEmpty else { return MediaPage(items: [], metadata: .init(nextCursor: index.nextCursor, sourceIDs: index.mediaIDs)) }
        var components = URLComponents(string: "/api/v1/images")!
        components.queryItems = [.init(name: "ids", value: index.mediaIDs.map(String.init).joined(separator: ",")),
                                 .init(name: "limit", value: String(index.mediaIDs.count)),
                                 .init(name: "browsingLevel", value: String(level))]
        if includeTags { components.queryItems?.append(.init(name: "withTags", value: "true")) }
        let media: MediaPage = try await request(path: components.string!)
        guard generation == authGeneration, account?.id == actorID else { throw ClientError.accountChanged }
        let byID = Dictionary(media.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = index.mediaIDs.compactMap { byID[$0] }
        for item in ordered { savedMemberships[item.id, default: []].insert(id) }
        return MediaPage(items: ordered, metadata: .init(nextCursor: index.nextCursor, sourceIDs: index.mediaIDs))
    }

    private struct CollectionWriteResult: Decodable { let status: String }

    func rpc<T: Decodable>(_ procedure: String, input: [String: Any]? = nil, mutation: Bool = false) async throws -> T {
        #if DEBUG && targetEnvironment(simulator)
        if CollectionPagingQA.enabled { throw ClientError.format("本地测试不使用站点接口") }
        #endif
        #if DEBUG
        if procedure.hasPrefix("tag.") && !mutation { tagRPCReads += 1 }
        #endif
        let allowed = ["user.getFollowingUsers", "user.getList", "user.toggleFollow", "user.updateBrowsingMode", "leaderboard.getLeaderboard", "leaderboard.getLeadboardLegends", "image.getInfinite",
                       "collection.getAllUser", "collection.getUserCollectionItemsByItem", "collection.getAllCollectionItems", "collection.saveItem", "collection.upsert", "post.getInfinite", "tag.getAll", "tag.getFeedTagBar", "tag.getTagWithModelCount", "tag.getById", "user.getAll", "userProfile.get"]
        guard allowed.contains(procedure) else { throw ClientError.invalidResponse }
        let envelope: [String: Any] = ["json": input.map { $0 as Any } ?? NSNull()]
        let data = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        let body = String(decoding: data, as: UTF8.self)
        var components = URLComponents(string: "/api/trpc/" + procedure)!
        if !mutation { components.queryItems = [.init(name: "input", value: body)] }
        return try await request(path: components.string!, method: mutation ? "POST" : "GET", body: mutation ? body : "", rpc: true)
    }

    private func ensureOrigin() async throws {
        guard !showLogin else { throw ClientError.loadingSite }
        if webView.url?.host == "civitai.red" && !webView.isLoading { return }
        if !loadingDocument {
            loadingDocument = true
            webView.load(URLRequest(url: URL(string: Self.origin + "/api/auth/session")!))
        }
        for _ in 0..<80 {
            try Task.checkCancellation()
            if webView.url?.host == "civitai.red" && !webView.isLoading { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw ClientError.siteUnavailable
    }

    private func request<T: Decodable>(path: String, method: String = "GET", body: String = "", rpc: Bool = false, sessionIdentityOnly: Bool = false) async throws -> T {
        #if DEBUG && targetEnvironment(simulator)
        if CollectionPagingQA.enabled { throw ClientError.format("本地测试不使用站点接口") }
        #endif
        let requestGeneration = authGeneration
        func checkCurrentSession() throws {
            try Task.checkCancellation()
            guard requestGeneration == authGeneration else { throw CancellationError() }
        }
        try checkCurrentSession()
        guard path.hasPrefix("/api/"), !path.hasPrefix("//") else { throw ClientError.invalidResponse }
        if oauth.hasCredentials {
            var request = URLRequest(url: URL(string: Self.origin + path)!)
            request.httpMethod = method; request.cachePolicy = .reloadIgnoringLocalCacheData
            if method == "POST" {
                request.httpBody = body.data(using: .utf8)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let data: Data, response: HTTPURLResponse
            do { (data, response) = try await oauth.authorizedData(for: request) }
            catch { try checkCurrentSession(); throw error }
            try checkCurrentSession()
            guard response.statusCode != 401 else { throw ClientError.signedOut }
            guard response.statusCode == 200 else { throw ClientError.http(response.statusCode) }
            let value = try JSONSerialization.jsonObject(with: data)
            var payload: Any = value
            if rpc {
                guard let root = value as? [String: Any], root["error"] == nil,
                      let result = root["result"] as? [String: Any], let data = result["data"] else { throw ClientError.invalidResponse }
                payload = (data as? [String: Any])?["json"] ?? data
            }
            if sessionIdentityOnly {
                let user = (value as? [String: Any])?["user"] as? [String: Any]
                payload = user.map { ["id": $0["id"] ?? NSNull(), "username": $0["username"] ?? NSNull(),
                                      "browsingLevel": $0["browsingLevel"] ?? NSNull(), "blurNsfw": $0["blurNsfw"] ?? NSNull()] } ?? NSNull()
            }
            return try decode(T.self, data: JSONSerialization.data(withJSONObject: payload, options: [.fragmentsAllowed]))
        }
        do { try await ensureOrigin() } catch { try checkCurrentSession(); throw error }
        try checkCurrentSession()
        let script = """
        if (location.origin !== origin) throw new Error('origin');
        const abort = new AbortController();
        const timer = setTimeout(() => abort.abort(), 25000);
        try {
          const options = {method, credentials:'include', cache:'no-store', signal:abort.signal};
          if (method === 'POST') { options.headers={'Content-Type':'application/json'}; options.body=body; }
          const r = await fetch(path, options);
          if (!r.ok) return JSON.stringify({ok:false,status:r.status});
          const value = await r.json();
          if (rpc && value.error) return JSON.stringify({ok:false,status:value.error.json?.data?.httpStatus || 400});
          let payload = rpc ? value.result?.data : value;
          if (rpc && payload && Object.prototype.hasOwnProperty.call(payload,'json')) payload = payload.json;
          if (identity) payload = payload?.user ? {id:payload.user.id,username:payload.user.username,browsingLevel:payload.user.browsingLevel ?? null,blurNsfw:payload.user.blurNsfw ?? null} : null;
          return JSON.stringify({ok:true,payload});
        } finally { clearTimeout(timer); }
        """
        let result: Any
        do { result = try await webView.callAsyncJavaScript(script, arguments: ["origin": Self.origin, "path": path, "method": method, "body": body, "rpc": rpc, "identity": sessionIdentityOnly], in: nil, contentWorld: .page) }
        catch { try checkCurrentSession(); throw error }
        try checkCurrentSession()
        guard let text = result as? String, let data = text.data(using: .utf8),
              let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ClientError.invalidResponse }
        guard envelope["ok"] as? Bool == true else {
            let status = envelope["status"] as? Int ?? 500
            if status == 401 { throw ClientError.signedOut }; throw ClientError.http(status)
        }
        let payload = envelope["payload"] ?? NSNull()
        let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.fragmentsAllowed])
        return try decode(T.self, data: payloadData)
    }

    private func decode<T: Decodable>(_ type: T.Type, data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch DecodingError.typeMismatch(_, let c) { throw ClientError.format(c.codingPath.map(\.stringValue).joined(separator: ".")) }
        catch DecodingError.valueNotFound(_, let c) { throw ClientError.format(c.codingPath.map(\.stringValue).joined(separator: ".")) }
        catch DecodingError.keyNotFound(let key, let c) { throw ClientError.format((c.codingPath.map(\.stringValue) + [key.stringValue]).joined(separator: ".")) }
    }

    func clearLocalLogin() async {
        authGeneration += 1
        oauth.clear()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await webView.configuration.websiteDataStore.removeData(ofTypes: types, modifiedSince: .distantPast)
        account = nil; following = []; followsKnown = false; unknownUsers = []
        clearCollectionState()
        MediaCache.shared.clear()
        webView.load(URLRequest(url: URL(string: Self.origin + "/api/auth/session")!))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loadingDocument = false }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { loadingDocument = false }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }; return nil
    }
    private struct FollowResult: Decodable { let following: Bool }
    private struct UserPage: Decodable { let items: [Creator] }

}
