import Foundation

@main struct MediaRepairStoreChecks {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CivitRepairStoreChecks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            precondition(condition(), name); count += 1
        }
        let source = root.appendingPathComponent("original.mp4")
        let second = root.appendingPathComponent("other.mp4")
        try Data("synthetic local input".utf8).write(to: source)
        try Data("unrelated original".utf8).write(to: second)
        let content = try MediaRepairStore.contentHash(source)
        check(content.count == 64, "streamed content hash")
        let otherHash = try MediaRepairStore.contentHash(second)
        check(content != otherHash, "different input never shares content identity")
        let address = URL(string: "https://example.invalid/media?credential=DO_NOT_PERSIST")!
        let output = root.appendingPathComponent(MediaRepairStore.outputName(address, content: content, transcoded: false))
        try Data("synthetic derivative".utf8).write(to: output)
        try MediaRepairStore.commit(address, original: source, content: content, transcoded: false, output: output, directory: root)
        check(MediaRepairStore.cached(address, original: source, directory: root)?.url == output, "matching original reuses derivative")
        let encoded = try String(contentsOf: MediaRepairStore.receiptURL(address, directory: root), encoding: .utf8)
        check(!encoded.contains("credential") && !encoded.contains("DO_NOT_PERSIST") && !encoded.contains("https") && !encoded.contains(source.path), "receipt stores no URL/path/credential")
        check(MediaRepairStore.cached(second, original: source, directory: root) == nil, "different address never aliases")
        check(MediaRepairStore.cached(address, original: nil, directory: root)?.url == output, "remote cached binding survives original LRU eviction")
        try Data("different original".utf8).write(to: source, options: .atomic)
        check(MediaRepairStore.cached(address, original: source, directory: root) == nil, "replacement source invalidates receipt")
        let localHash = try MediaRepairStore.contentHash(source)
        let localOutput = root.appendingPathComponent(MediaRepairStore.outputName(source, content: localHash, transcoded: true))
        try Data("synthetic local repair".utf8).write(to: localOutput)
        try MediaRepairStore.commit(source, original: source, content: localHash, transcoded: true, output: localOutput, directory: root)
        check(MediaRepairStore.cached(source, original: source, directory: root)?.transcoded == true, "offline repair mode retained")
        check(MediaRepairStore.cached(source, original: nil, directory: root) == nil, "offline reuse requires original")
        check(MediaRepairStore.associatedBytes(source, directory: root) > (MediaRepairStore.identity(localOutput)?.size ?? 0), "space includes derivative and receipt")
        let listed = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let snapshot = MediaRepairStore.familySnapshot(listed)
        check(snapshot.bytes[MediaRepairStore.stem(source)] == MediaRepairStore.associatedBytes(source, directory: root), "one-pass family accounting matches exact per-original usage")
        check(snapshot.files[MediaRepairStore.stem(source)]?.count == 2, "family snapshot includes only receipt and derivative")
        try MediaRepairStore.removeAssociated(source, directory: root)
        check(!FileManager.default.fileExists(atPath: localOutput.path), "precise local derivative cleanup")
        check(FileManager.default.fileExists(atPath: source.path) && FileManager.default.fileExists(atPath: second.path) && FileManager.default.fileExists(atPath: output.path), "cleanup preserves originals and other families")
        let receiptFile = MediaRepairStore.receiptURL(address, directory: root)
        try Data(repeating: 65, count: 1025).write(to: receiptFile)
        check(MediaRepairStore.receipt(address, directory: root) == nil, "oversized receipt rejected")
        try Data("{\"content\":\"../../other\"}".utf8).write(to: receiptFile)
        check(MediaRepairStore.receipt(address, directory: root) == nil, "malformed/traversal receipt rejected")
        print("MediaRepairStore checks passed: \(count)")
    }
}
