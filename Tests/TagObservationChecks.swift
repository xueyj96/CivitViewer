import Foundation

@main struct TagObservationChecks {
    @MainActor static func main() async throws {
        var assertions = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            assertions += 1
            precondition(condition(), message)
        }
        func item(_ id: Int, tags: [Int], url: String? = nil, name: String = "public fixture") -> MediaItem {
            MediaItem(id: id, url: url ?? "https://images.example.test/asset-\(id)", width: 10, height: 10,
                type: "image", username: name, browsingLevel: 1, thumbnail: nil, creatorID: nil,
                tags: tags.map { .init(id: $0, name: "tag-\($0)") }, postID: nil, metadata: nil)
        }

        var instant = Date(timeIntervalSince1970: 1_800_000_000)
        let policy = TagAvailabilityPolicy()
        let memory = TagObservationStore(now: { instant })
        check(memory.estimate(tagID: 1, scope: "account-a", policy: policy) == nil, "Unobserved tags have no estimate")
        let uuid = "11111111-2222-4333-8444-555555555555"
        memory.observe(items: [item(11, tags: [1], url: "https://image.civitai.com/images/\(uuid)/preview"),
                              item(12, tags: [1], url: "https://image.civitai.com/images/\(uuid)/preview"),
                              item(13, tags: [1], url: "https://image.civitai.com/images/\(uuid)/preview")], scope: "account-a", policy: policy)
        check(memory.estimate(tagID: 1, scope: "account-a", policy: policy)?.countLowerBound == 1,
              "Civitai UUID witnesses deduplicate across media IDs")
        memory.observe(items: [item(21, tags: [1]), item(22, tags: [1]), item(23, tags: [1])], scope: "account-a", policy: policy)
        check(memory.estimate(tagID: 1, scope: "account-a", policy: policy)?.countLowerBound == 4,
              "Non-Civitai URL assets fall back to numeric media IDs")
        check(memory.estimate(tagID: 1, scope: "account-b", policy: policy) == nil, "Account scopes are isolated")
        let blockedPolicy = TagAvailabilityPolicy(blockedTags: ["private"])
        check(memory.estimate(tagID: 1, scope: "account-a", policy: blockedPolicy) == nil, "Policies are isolated")
        check(memory.estimate(tagID: 1, scope: "account-a", policy: policy)?.isRecommended == true,
              "Three recent distinct assets enable recommendation")

        let noDedup = TagAvailabilityPolicy(deduplicateMediaAssets: false)
        let noDedupStore = TagObservationStore(now: { instant })
        let sharedURL = "https://image.civitai.com/images/\(uuid)/preview"
        noDedupStore.observe(items: [item(31, tags: [2], url: sharedURL), item(32, tags: [2], url: sharedURL), item(33, tags: [2], url: sharedURL)],
                              scope: "account-a", policy: noDedup)
        check(noDedupStore.estimate(tagID: 2, scope: "account-a", policy: noDedup)?.countLowerBound == 3,
              "Disabling asset deduplication counts numeric IDs")

        memory.recordEmpty(tagID: 1, scope: "account-a", policy: policy)
        let empty = memory.estimate(tagID: 1, scope: "account-a", policy: policy)
        check(empty?.emptyUntil == instant.addingTimeInterval(86_400) && empty?.isRecommended == false,
              "A complete empty observation suppresses recommendation for 24 hours")
        instant.addTimeInterval(86_401)
        check(memory.estimate(tagID: 1, scope: "account-a", policy: policy)?.isRecommended == true,
              "Expired empty evidence no longer suppresses a recent positive estimate")
        memory.recordEmpty(tagID: 1, scope: "account-a", policy: policy)
        memory.observe(items: [item(24, tags: [1])], scope: "account-a", policy: policy)
        check(memory.estimate(tagID: 1, scope: "account-a", policy: policy)?.emptyUntil == nil,
              "A new positive witness revokes negative evidence")
        instant.addTimeInterval(31 * 24 * 60 * 60)
        check(memory.estimate(tagID: 1, scope: "account-a", policy: policy)?.countLowerBound == 0,
              "Witness counts expire after the 30-day observation window")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tag-observation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let secretScope = "account-private-name@example.test"
        let secretHandlePolicy = TagAvailabilityPolicy(blockedAuthorHandles: ["private-user-token"])
        let persisted = TagObservationStore(rootURL: root, now: { instant })
        // Exercise pre-activation observations: disk data must merge instead of being replaced.
        let initial = TagObservationStore(rootURL: root, now: { instant })
        await initial.activate(scope: secretScope)
        initial.observe(items: [item(41, tags: [4]), item(42, tags: [4]), item(43, tags: [4])], scope: secretScope, policy: secretHandlePolicy)
        initial.recordEmpty(tagID: 4, scope: secretScope, policy: secretHandlePolicy)
        await initial.flush()
        instant.addTimeInterval(1)
        persisted.observe(items: [item(44, tags: [4])], scope: secretScope, policy: secretHandlePolicy)
        await persisted.activate(scope: secretScope)
        check(persisted.estimate(tagID: 4, scope: secretScope, policy: secretHandlePolicy)?.countLowerBound == 4,
              "Activation merges existing persisted data with observations made before load")
        check(persisted.estimate(tagID: 4, scope: secretScope, policy: secretHandlePolicy)?.emptyUntil == nil,
              "Newer pre-load positive observation overrides persisted empty evidence")
        let racingActivation = TagObservationStore(rootURL: root, now: { instant })
        racingActivation.observe(items: [item(45, tags: [4])], scope: secretScope, policy: secretHandlePolicy)
        async let activateAgainA: Void = racingActivation.activate(scope: secretScope)
        async let activateAgainB: Void = racingActivation.activate(scope: secretScope)
        _ = await (activateAgainA, activateAgainB)
        let racedEstimate = racingActivation.estimate(tagID: 4, scope: secretScope, policy: secretHandlePolicy)
        check((4...5).contains(racedEstimate?.countLowerBound ?? 0) &&
              racedEstimate?.emptyUntil == nil,
              "Concurrent first activation loads once and preserves a newer in-memory positive")
        await persisted.flush()
        let diskURL = root.appendingPathComponent("observations-v1.json")
        let bytes = try Data(contentsOf: diskURL)
        let text = String(decoding: bytes, as: UTF8.self)
        check(!text.contains(secretScope) && !text.contains("private-user-token") && !text.contains("images.example.test"),
              "Persistence stores hashed context and no scope, handle, or media URL")
        check(!text.contains("url:"), "Persistence never stores URL-prefixed asset keys")
        let resourceValues = try root.resourceValues(forKeys: [.isExcludedFromBackupKey, .fileProtectionKey])
        check(resourceValues.isExcludedFromBackup == true, "Observation directory is excluded from device backup")
        check(resourceValues.fileProtection == .completeUntilFirstUserAuthentication,
              "Observation directory uses first-unlock file protection")
        let fileResourceValues = try diskURL.resourceValues(forKeys: [.isExcludedFromBackupKey, .fileProtectionKey])
        check(fileResourceValues.isExcludedFromBackup == true, "Observation file is excluded from device backup")
        check(fileResourceValues.fileProtection == .completeUntilFirstUserAuthentication,
              "Observation file uses first-unlock file protection")
        func preservesInvalidSnapshot(_ mutate: (inout [String: Any]) -> Void) async throws -> Bool {
            let invalidRoot = FileManager.default.temporaryDirectory.appendingPathComponent("tag-observation-invalid-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: invalidRoot) }
            try FileManager.default.createDirectory(at: invalidRoot, withIntermediateDirectories: true)
            var object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
            mutate(&object)
            let invalidBytes = try JSONSerialization.data(withJSONObject: object)
            let url = invalidRoot.appendingPathComponent("observations-v1.json")
            try invalidBytes.write(to: url)
            let invalidStore = TagObservationStore(rootURL: invalidRoot, now: { instant })
            await invalidStore.activate(scope: "validation")
            invalidStore.recordEmpty(tagID: 99, scope: "validation", policy: policy)
            await invalidStore.flush()
            return try Data(contentsOf: url) == invalidBytes
        }
        let badHashPreserved = try await preservesInvalidSnapshot { object in
            var contexts = object["contexts"] as! [[String: Any]]
            contexts[0]["hash"] = "not-a-sha256"
            object["contexts"] = contexts
        }
        check(badHashPreserved, "Invalid context hash is rejected and preserved")
        let duplicateContextPreserved = try await preservesInvalidSnapshot { object in
            var contexts = object["contexts"] as! [[String: Any]]
            contexts.append(contexts[0])
            object["contexts"] = contexts
        }
        check(duplicateContextPreserved, "Duplicate context hashes are rejected and preserved")
        let duplicateTagPreserved = try await preservesInvalidSnapshot { object in
            var contexts = object["contexts"] as! [[String: Any]]
            var tags = contexts[0]["tags"] as! [[String: Any]]
            tags.append(tags[0])
            contexts[0]["tags"] = tags
            object["contexts"] = contexts
        }
        check(duplicateTagPreserved, "Duplicate tag IDs within a context are rejected and preserved")
        let excessWitnessesPreserved = try await preservesInvalidSnapshot { object in
            var contexts = object["contexts"] as! [[String: Any]]
            var tags = contexts[0]["tags"] as! [[String: Any]]
            var tag = tags[0]
            var record = tag["record"] as! [String: Any]
            let witnesses = record["witnesses"] as! [[String: Any]]
            record["witnesses"] = Array(repeating: witnesses[0], count: 9)
            tag["record"] = record
            tags[0] = tag
            contexts[0]["tags"] = tags
            object["contexts"] = contexts
        }
        check(excessWitnessesPreserved, "More than eight persisted witnesses are rejected and preserved")
        let duplicateWitnessPreserved = try await preservesInvalidSnapshot { object in
            var contexts = object["contexts"] as! [[String: Any]]
            var tags = contexts[0]["tags"] as! [[String: Any]]
            var tag = tags[0]
            var record = tag["record"] as! [String: Any]
            var witnesses = record["witnesses"] as! [[String: Any]]
            witnesses[1]["key"] = witnesses[0]["key"]
            record["witnesses"] = witnesses
            tag["record"] = record
            tags[0] = tag
            contexts[0]["tags"] = tags
            object["contexts"] = contexts
        }
        check(duplicateWitnessPreserved, "Duplicate witness keys are rejected and preserved")
        let badDatePreserved = try await preservesInvalidSnapshot { object in
            var contexts = object["contexts"] as! [[String: Any]]
            var tags = contexts[0]["tags"] as! [[String: Any]]
            var tag = tags[0]
            var record = tag["record"] as! [String: Any]
            record["touchedAt"] = "not-a-finite-date"
            tag["record"] = record
            tags[0] = tag
            contexts[0]["tags"] = tags
            object["contexts"] = contexts
        }
        check(badDatePreserved, "Malformed persisted dates are rejected and preserved")
        let restarted = TagObservationStore(rootURL: root, now: { instant })
        await restarted.activate(scope: secretScope)
        check(restarted.estimate(tagID: 4, scope: secretScope, policy: secretHandlePolicy)?.countLowerBound == 4,
              "JSON persistence survives store restart")

        let corruptRoot = FileManager.default.temporaryDirectory.appendingPathComponent("tag-observation-bad-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: corruptRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: corruptRoot) }
        let corruptURL = corruptRoot.appendingPathComponent("observations-v1.json")
        let corrupt = Data("not a valid observation file".utf8)
        try corrupt.write(to: corruptURL)
        let damagedStore = TagObservationStore(rootURL: corruptRoot, now: { instant })
        await damagedStore.activate(scope: "x")
        damagedStore.observe(items: [item(51, tags: [5])], scope: "x", policy: policy)
        await damagedStore.flush()
        let preservedCorrupt = try Data(contentsOf: corruptURL)
        check(preservedCorrupt == corrupt, "Corrupt file is preserved and never interpreted or overwritten as zero")

        let invalidWitnessRoot = FileManager.default.temporaryDirectory.appendingPathComponent("tag-observation-witness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: invalidWitnessRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: invalidWitnessRoot) }
        var encodedObject = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        var diskContexts = encodedObject["contexts"] as! [[String: Any]]
        var firstContext = diskContexts[0]
        var diskTags = firstContext["tags"] as! [[String: Any]]
        var firstTag = diskTags[0]
        var record = firstTag["record"] as! [String: Any]
        var witnesses = record["witnesses"] as! [[String: Any]]
        witnesses[0]["key"] = "url:https://private.example/media"
        record["witnesses"] = witnesses
        firstTag["record"] = record
        diskTags[0] = firstTag
        firstContext["tags"] = diskTags
        diskContexts[0] = firstContext
        encodedObject["contexts"] = diskContexts
        let invalidWitnessBytes = try JSONSerialization.data(withJSONObject: encodedObject)
        let invalidWitnessURL = invalidWitnessRoot.appendingPathComponent("observations-v1.json")
        try invalidWitnessBytes.write(to: invalidWitnessURL)
        let invalidWitnessStore = TagObservationStore(rootURL: invalidWitnessRoot, now: { instant })
        await invalidWitnessStore.activate(scope: "x")
        invalidWitnessStore.observe(items: [item(61, tags: [6])], scope: "x", policy: policy)
        await invalidWitnessStore.flush()
        let preservedInvalidWitness = try Data(contentsOf: invalidWitnessURL)
        check(preservedInvalidWitness == invalidWitnessBytes,
              "A URL-shaped witness is rejected and the file is not overwritten")

        let oversizedRoot = FileManager.default.temporaryDirectory.appendingPathComponent("tag-observation-large-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: oversizedRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: oversizedRoot) }
        let oversizedURL = oversizedRoot.appendingPathComponent("observations-v1.json")
        let oversized = Data(repeating: 0x41, count: 8 * 1024 * 1024 + 1)
        try oversized.write(to: oversizedURL)
        let oversizedStore = TagObservationStore(rootURL: oversizedRoot, now: { instant })
        await oversizedStore.activate(scope: "x")
        oversizedStore.recordEmpty(tagID: 7, scope: "x", policy: policy)
        await oversizedStore.flush()
        let stillOversized = try Data(contentsOf: oversizedURL)
        check(stillOversized.count == oversized.count, "Oversized persistence input is rejected before decode and preserved")

        let autosaveRoot = FileManager.default.temporaryDirectory.appendingPathComponent("tag-observation-auto-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: autosaveRoot) }
        let autosave = TagObservationStore(rootURL: autosaveRoot, now: { instant })
        await autosave.activate(scope: "auto")
        autosave.observe(items: [item(71, tags: [8])], scope: "auto", policy: policy)
        autosave.observe(items: [item(72, tags: [8])], scope: "auto", policy: policy)
        try await Task.sleep(for: .milliseconds(1_100))
        let autoFile = autosaveRoot.appendingPathComponent("observations-v1.json")
        let autoRestart = TagObservationStore(rootURL: autosaveRoot, now: { instant })
        await autoRestart.activate(scope: "auto")
        check(autoRestart.estimate(tagID: 8, scope: "auto", policy: policy)?.countLowerBound == 2 &&
              FileManager.default.fileExists(atPath: autoFile.path),
              "Debounced autosave coalesces rapid observations into the latest snapshot")

        let bounded = TagObservationStore(now: { instant })
        for scopeIndex in 0..<5 {
            bounded.recordEmpty(tagID: scopeIndex + 1, scope: "scope-\(scopeIndex)", policy: policy)
        }
        check((0..<5).filter { bounded.estimate(tagID: $0 + 1, scope: "scope-\($0)", policy: policy) != nil }.count == 4,
              "At most four contexts are retained")
        let manyTags = (1...5_005).map { item(10_000 + $0, tags: [10_000 + $0]) }
        bounded.observe(items: manyTags, scope: "capacity", policy: policy)
        let retainedTagCount = (10_001...15_005).filter {
            bounded.estimate(tagID: $0, scope: "capacity", policy: policy) != nil
        }.count
        check(retainedTagCount == 5_000, "At most 5000 tags are retained per context")
        let witnessItems = (20_001...20_020).map { item($0, tags: [6]) }
        let witnessStore = TagObservationStore(now: { instant })
        witnessStore.observe(items: witnessItems, scope: "witness-cap", policy: policy)
        check(witnessStore.estimate(tagID: 6, scope: "witness-cap", policy: policy)?.countLowerBound == 8,
              "At most eight recent witnesses are retained per tag")

        let scaleRoot = FileManager.default.temporaryDirectory.appendingPathComponent("tag-observation-scale-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scaleRoot) }
        var scaleClock = instant
        let scaleStore = TagObservationStore(rootURL: scaleRoot, now: { scaleClock })
        for index in 0..<4 { await scaleStore.activate(scope: "scale-context-\(index)") }
        let scaleTagIDs = Array(100_001...105_000)
        for contextIndex in 0..<4 {
            let observations = (0..<8).map { witnessIndex in
                let uuid = String(format: "00000000-0000-4000-8000-%012d", contextIndex * 8 + witnessIndex + 1)
                return item(200_000 + contextIndex * 10 + witnessIndex, tags: scaleTagIDs,
                            url: "https://image.civitai.com/images/\(uuid)/preview")
            }
            scaleStore.observe(items: observations, scope: "scale-context-\(contextIndex)", policy: policy)
            scaleClock.addTimeInterval(1)
        }
        check((0..<4).allSatisfy {
            scaleStore.estimate(tagID: scaleTagIDs[0], scope: "scale-context-\($0)", policy: policy)?.countLowerBound == 8
        }, "Scale fixture represents 5000 tags with eight UUID witnesses in all four contexts")
        await scaleStore.flush()
        let scaleFile = scaleRoot.appendingPathComponent("observations-v1.json")
        let scaleSize = (try FileManager.default.attributesOfItem(atPath: scaleFile.path)[.size] as? NSNumber)?.uint64Value ?? .max
        check(scaleSize <= 8 * 1024 * 1024, "Four 5000-tag by eight-witness contexts prune to the byte budget")
        check(scaleStore.estimate(tagID: scaleTagIDs[0], scope: "scale-context-0", policy: policy)?.countLowerBound == 8,
              "Disk byte pruning leaves the full in-memory LRU records intact")
        let scaleRestart = TagObservationStore(rootURL: scaleRoot, now: { scaleClock })
        await scaleRestart.activate(scope: "scale-context-3")
        check(scaleRestart.estimate(tagID: scaleTagIDs[0], scope: "scale-context-3", policy: policy)?.countLowerBound == 8,
              "Newest representative-scale context survives byte-budget pruning and restart")
        scaleStore.observe(items: [item(300_001, tags: [106_000])], scope: "scale-context-new", policy: policy)
        await scaleStore.flush()
        let scaleRestartAfterUpdate = TagObservationStore(rootURL: scaleRoot, now: { scaleClock })
        await scaleRestartAfterUpdate.activate(scope: "scale-context-new")
        check(scaleRestartAfterUpdate.estimate(tagID: 106_000, scope: "scale-context-new", policy: policy)?.countLowerBound == 1,
              "A post-pruning observation can be saved and read after restart")

        print("TagObservationChecks: \(assertions) assertions passed")
    }
}
