import Foundation

@main
struct OfflineDiskUsageChecks {
    private static var assertions = 0

    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-disk-usage-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let empty = root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)
        let emptySnapshot = try OfflineDiskSnapshot.read(directory: empty)
        check(emptySnapshot.files.isEmpty, "empty files")
        check(emptySnapshot.sizes.isEmpty, "empty sizes")
        check(emptySnapshot.created.isEmpty, "empty creation dates")
        check(emptySnapshot.totalBytes == 0, "empty total is zero")

        let populated = root.appendingPathComponent("populated", isDirectory: true)
        try FileManager.default.createDirectory(at: populated, withIntermediateDirectories: false)
        let first = populated.appendingPathComponent("a.bin")
        let second = populated.appendingPathComponent("b.bin")
        try Data(repeating: 0x11, count: 7).write(to: first)
        try Data(repeating: 0x22, count: 13).write(to: second)
        let full = try OfflineDiskSnapshot.read(directory: populated)
        check(full.files.count == 2, "all files returned")
        check(full.totalBytes == 20, "complete byte sum")
        check(full.sizes[first.standardizedFileURL.path] == 7, "first size")
        check(full.sizes[second.standardizedFileURL.path] == 13, "second size")
        check(full.created.count == 2 && full.created.values.allSatisfy { $0.timeIntervalSince1970 > 0 }, "all creation dates")

        var listCalls = 0
        do {
            _ = try OfflineDiskSnapshot.read(directory: root, list: { _ in
                listCalls += 1
                throw InjectedFailure.enumeration
            })
            check(false, "enumeration failure throws")
        } catch InjectedFailure.enumeration {
            check(true, "enumeration failure throws")
        }
        check(listCalls == 1, "enumeration called once")

        let fakeFiles = (0..<3).map { root.appendingPathComponent("injected-\($0)") }
        do {
            _ = try OfflineDiskSnapshot.read(directory: root, list: { _ in fakeFiles }, attributes: { url in
                if url == fakeFiles[1] { throw InjectedFailure.attributes }
                return regularMetadata(size: 5)
            })
            check(false, "entry stat failure throws")
        } catch InjectedFailure.attributes {
            check(true, "entry stat failure throws")
        }

        do {
            _ = try OfflineDiskSnapshot.read(directory: root, list: { _ in fakeFiles }, attributes: { url in
                if url == fakeFiles[1] {
                    return [.type: FileAttributeType.typeDirectory, .size: NSNumber(value: 0), .creationDate: Date()]
                }
                return regularMetadata(size: 5)
            })
            check(false, "non-regular entry throws")
        } catch OfflineDiskSnapshotError.nonRegularFile {
            check(true, "non-regular entry throws")
        }

        do {
            _ = try OfflineDiskSnapshot.read(directory: root, list: { _ in [fakeFiles[0]] }, attributes: { _ in
                regularMetadata(size: -1)
            })
            check(false, "negative size throws")
        } catch OfflineDiskSnapshotError.invalidMetadata {
            check(true, "negative size throws")
        }
        do {
            _ = try OfflineDiskSnapshot.read(directory: root, list: { _ in [fakeFiles[0]] }, attributes: { _ in
                [.type: FileAttributeType.typeRegular, .size: NSNumber(value: 1)]
            })
            check(false, "missing creation date throws")
        } catch OfflineDiskSnapshotError.invalidMetadata {
            check(true, "missing creation date throws")
        }

        var largeListCalls = 0
        var largeAttributeCalls = 0
        let many = (0..<1000).map { root.appendingPathComponent("many-\($0)") }
        let large = try OfflineDiskSnapshot.read(directory: root, list: { _ in
            largeListCalls += 1
            return many
        }, attributes: { _ in
            largeAttributeCalls += 1
            return regularMetadata(size: 3)
        })
        check(largeListCalls == 1, "large listing called once")
        check(largeAttributeCalls == many.count, "one metadata read per file")
        check(large.files.count == 1000 && large.totalBytes == 3000, "large complete snapshot")

        print("OfflineDiskUsageChecks: PASS (\(assertions) assertions)")
    }

    private static func regularMetadata(size: Int64) -> [FileAttributeKey: Any] {
        [.type: FileAttributeType.typeRegular, .size: NSNumber(value: size), .creationDate: Date()]
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        assertions += 1
        guard condition() else {
            fputs("FAIL: \(label)\n", stderr)
            exit(1)
        }
    }
}

private enum InjectedFailure: Error {
    case enumeration
    case attributes
}
