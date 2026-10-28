import Foundation

@main struct MediaDedupChecks {
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            precondition(condition(), message)
        }
        func media(_ id: Int, _ url: String, type: String = "image", creatorID: Int? = 7, tags: [MediaTag]? = []) -> MediaItem {
            MediaItem(id: id, url: url, width: 640, height: 480, type: type, username: "fixture",
                      browsingLevel: 1, thumbnail: nil, creatorID: creatorID, tags: tags)
        }
        func page(_ items: [MediaItem], cursor: String? = nil) -> MediaPage {
            MediaPage(items: items, metadata: .init(nextCursor: cursor))
        }
        let uuidA = "1B8CB1F8-AC2B-4E7D-93D0-0D2BF22F3BA1"
        let uuidB = "2B8CB1F8-AC2B-4E7D-93D0-0D2BF22F3BA1"

        let imageSmall = media(1, "https://image.civitai.com/images/\(uuidA)/width=512/file.png", type: "image")
        let imageLarge = media(2, "https://image.civitai.com/images/\(uuidA)/width=1024/file.png", type: "image")
        check(imageSmall.mediaAssetKey == imageLarge.mediaAssetKey && imageSmall.mediaAssetKey == "civitai:image:\(uuidA.lowercased())", "Image UUID identity ignores width variants and normalizes the UUID")

        let videoSmall = media(3, "https://image.civitai.com/videos/\(uuidA)/width=512/file.mp4", type: "video")
        let videoLarge = media(4, "https://image.civitai.com/videos/\(uuidA)/width=1024/file.mp4", type: "video")
        check(videoSmall.mediaAssetKey == videoLarge.mediaAssetKey && videoSmall.mediaAssetKey == "civitai:video:\(uuidA.lowercased())", "Video width variants share a typed UUID key")
        check(videoSmall.mediaAssetKey == videoLarge.mediaAssetKey && videoSmall.mediaAssetKey != imageSmall.mediaAssetKey,
              "The single typed media asset key merges video variants while keeping image identity separate")

        let similarA = media(5, "https://image.civitai.com/\(uuidA)/width=512/same-title.png", type: "image")
        let similarB = media(6, "https://image.civitai.com/\(uuidB)/width=512/same-title.png", type: "image")
        check(similarA.mediaAssetKey != similarB.mediaAssetKey, "Similar names and variants do not merge different Civitai UUIDs")
        let foreignA = media(7, "https://cdn.example.test/path/photo.jpg?width=512&token=x", type: "image")
        let foreignB = media(8, "https://cdn.example.test/path/photo.jpg?width=1024&token=x", type: "image")
        check(foreignA.mediaAssetKey?.contains("?width=512&token=x") == true && foreignA.mediaAssetKey != foreignB.mediaAssetKey, "Unknown hosts retain the complete HTTPS URL and query")
        check(media(9, foreignA.url, type: "audio").mediaAssetKey == nil && media(10,"http://image.civitai.com/\(uuidA)").mediaAssetKey == nil, "Unsupported type and non-HTTPS URLs do not receive a guessed key")

        var accumulator = FeedAccumulator()
        accumulator.append(page([imageSmall,imageLarge,videoSmall,videoLarge]))
        check(accumulator.items.map(\.id) == [1,2,3,4], "Raw catalog defaults to showing all distinct work IDs")
        accumulator.setDeduplicateMediaAssets(true)
        check(accumulator.items.map(\.id) == [1,3] && accumulator.duplicateCount == 2, "Opt-in asset dedupe merges image and video variants")
        accumulator.setDeduplicateMediaAssets(false)
        check(accumulator.items.map(\.id) == [1,2,3,4], "Turning dedupe off rebuilds from preserved original IDs")
        accumulator.append(page([imageSmall]))
        check(accumulator.items.map(\.id) == [1,2,3,4] && accumulator.duplicateCount == 1, "Same work ID is always deduplicated regardless of asset setting")

        let blocked = media(20, "https://image.civitai.com/\(uuidA)/blocked.png", creatorID: 20, tags: [.init(id: 1, name: "hide")])
        let visibleAlias = media(21, "https://image.civitai.com/\(uuidA)/visible.png", creatorID: 21, tags: [.init(id: 2, name: "safe")])
        var filtered = FeedAccumulator(blockedTags: ["hide"], deduplicateMediaAssets: true)
        filtered.append(page([blocked,visibleAlias]))
        check(filtered.items.map(\.id) == [21] && filtered.blockedCount == 1, "Tag filtering happens before choosing an asset representative")

        let unfollowedAlias = media(30, "https://image.civitai.com/\(uuidB)/first.png", creatorID: 301, tags: [.init(id: 3, name: "safe")])
        let followedAlias = media(31, "https://image.civitai.com/\(uuidB)/second.png", creatorID: 302, tags: [.init(id: 4, name: "safe")])
        let unrelated = media(32, "https://cdn.example.test/unrelated.png", creatorID: 999, tags: [.init(id: 5, name: "safe")])
        var following = FeedAccumulator(blockedTags: ["hide"], deduplicateMediaAssets: true)
        following.append(page([unfollowedAlias,followedAlias,unrelated], cursor: "next-page"))
        check(following.items.map(\.id) == [30,32] && !following.reachedEnd, "Initial representative can precede the followed alias")
        following.retainFollowing([302], current: nil)
        check(following.items.map(\.id) == [31] && following.blockedTags == ["hide"], "Following reconciliation uses raw candidates and retains the matching hidden asset alias")
        check(following.cursor == nil && !following.reachedEnd && following.duplicateCount == 0, "Following reconciliation clears cursor/end and repeated-ID state for a new feed")

        let oldAlias = media(40, "https://image.civitai.com/\(uuidA)/old.png")
        let sameAssetReplacement = media(41, "https://image.civitai.com/\(uuidA)/new.png")
        let nextWork = media(42, "https://image.civitai.com/\(uuidB)/next.png")
        let previousItems = [oldAlias,nextWork]
        let visibleItems = [sameAssetReplacement,nextWork]
        check(MediaFocusPolicy.target(current: 40, previousItems: previousItems, items: visibleItems) == 41, "Focus transfers to a visible alias when its original work is merged")
        check(MediaFocusPolicy.target(current: 42, previousItems: previousItems, items: visibleItems) == 42, "Focus keeps the same work ID when still visible")
        check(MediaFocusPolicy.target(current: 42, previousItems: [oldAlias,nextWork,media(43,"https://cdn.example.test/third.png")], items: [sameAssetReplacement,media(43,"https://cdn.example.test/third.png")]) == 43, "When current work disappears, focus advances using prior order")
        check(MediaFocusPolicy.target(current: -1, previousItems: [oldAlias], items: [sameAssetReplacement,oldAlias]) == 41, "Initial focus chooses the newly visible item after a list rebuild")

        print("MediaDedupChecks: \(checks) regression assertions passed")
    }
}
