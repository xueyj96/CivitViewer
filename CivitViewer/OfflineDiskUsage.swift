import Foundation

enum OfflineDiskSnapshotError: Error {
    case nonRegularFile(path: String)
    case invalidMetadata(path: String)
    case totalSizeOverflow
}

struct OfflineDiskSnapshot {
    let files: [URL]
    let sizes: [String: Int64]
    let created: [String: Date]
    let totalBytes: Int64

    static func read(
        directory: URL,
        list: ((URL) throws -> [URL])? = nil,
        attributes: ((URL) throws -> [FileAttributeKey: Any])? = nil
    ) throws -> Self {
        let fileManager = FileManager.default
        let enumeratedFiles = try (list ?? { url in
            try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [])
        })(directory)

        var sizes: [String: Int64] = [:]
        var created: [String: Date] = [:]
        var totalBytes: Int64 = 0

        for file in enumeratedFiles {
            let metadata = try (attributes ?? { url in
                try fileManager.attributesOfItem(atPath: url.path)
            })(file)
            let path = file.standardizedFileURL.path
            guard let type = metadata[.type] as? FileAttributeType, type == .typeRegular else {
                throw OfflineDiskSnapshotError.nonRegularFile(path: path)
            }
            guard let sizeValue = metadata[.size] as? NSNumber,
                  sizeValue.int64Value >= 0,
                  let creationDate = metadata[.creationDate] as? Date else {
                throw OfflineDiskSnapshotError.invalidMetadata(path: path)
            }

            let size = sizeValue.int64Value
            let (nextTotal, overflow) = totalBytes.addingReportingOverflow(size)
            guard !overflow else { throw OfflineDiskSnapshotError.totalSizeOverflow }
            totalBytes = nextTotal
            sizes[path] = size
            created[path] = creationDate
        }

        return Self(files: enumeratedFiles, sizes: sizes, created: created, totalBytes: totalBytes)
    }
}
