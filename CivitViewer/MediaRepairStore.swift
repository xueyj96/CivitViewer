import Foundation
import CryptoKit

enum MediaRepairStage: Equatable {
    case waiting, downloading, inspecting, remuxing, transcoding, validating
    var title: String {
        switch self {
        case .waiting: "正在等待视频修复…"
        case .downloading: "正在下载修复所需的视频…"
        case .inspecting: "正在检查视频格式…"
        case .remuxing: "正在无损转封装…"
        case .transcoding: "正在转换为兼容视频…"
        case .validating: "正在验证修复结果…"
        }
    }
}

enum MediaRepairError: LocalizedError {
    case unavailable, damaged, unsupported, hdr, lowSpace, storageUnknown, paused, output, validation, expired
    var errorDescription: String? {
        switch self {
        case .unavailable: "原视频暂时无法取得，请稍后重试"
        case .damaged: "视频文件无法完整读取，未生成替代文件"
        case .unsupported: "此视频超出当前本机转换支持范围，可尝试兼容播放"
        case .hdr: "此 HDR 视频无法直接转封装，当前版本暂不转换其色彩"
        case .lowSpace: "可用空间或存储额度不足，已停止转换"
        case .storageUnknown: "暂时无法统计存储空间，已停止转换，请稍后重试"
        case .paused: "手机温度较高或已进入省电模式，转换已暂停"
        case .output: "修复文件未能保存，原文件已保留"
        case .validation: "转换后仍无法原生播放，可尝试兼容播放"
        case .expired: "转换耗时超过本次上限，可稍后重试"
        }
    }
}

/// An alias binds one original cache identity to a content-addressed derivative.
/// Only hashes and numeric file attributes are persisted, never media URLs.
enum MediaRepairStore {
    struct Identity: Codable, Equatable {
        let size: Int64
        let inode: UInt64
        let created: TimeInterval
    }
    struct Receipt: Codable {
        let version: Int
        let source: Identity
        let content: String
        let transcoded: Bool
        let outputBytes: Int64
    }
    static let prefix = "cvr1-"
    static func addressKey(_ address: URL) -> String {
        SHA256.hash(data: Data(address.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func stem(_ address: URL) -> String { prefix + addressKey(address) }
    static func identity(_ file: URL) -> Identity? {
        guard file.isFileURL, let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.int64Value > 0,
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let created = attributes[.creationDate] as? Date else { return nil }
        return .init(size: size.int64Value, inode: inode.uint64Value, created: created.timeIntervalSince1970)
    }
    static func contentHash(_ file: URL) throws -> String {
        guard let before = identity(file) else { throw MediaRepairError.unavailable }
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var hash = SHA256(), total: Int64 = 0
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            total += Int64(data.count)
            guard total <= 1_073_741_824 else { throw MediaRepairError.unsupported }
            hash.update(data: data)
        }
        guard identity(file) == before, total == before.size else { throw MediaRepairError.unavailable }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func outputName(_ address: URL, content: String, transcoded: Bool) -> String {
        stem(address) + "-" + content + (transcoded ? "-t.mp4" : "-r.mp4")
    }
    static func receiptURL(_ address: URL, directory: URL) -> URL { directory.appendingPathComponent(stem(address) + ".json") }
    static func receipt(_ address: URL, directory: URL) -> Receipt? {
        let file = receiptURL(address, directory: directory)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue > 0, size.intValue <= 1024,
              let data = try? Data(contentsOf: file), let record = try? JSONDecoder().decode(Receipt.self, from: data),
              record.version == 1, record.source.size > 0, record.outputBytes > 0,
              record.content.count == 64, record.content.allSatisfy({ $0.isASCII && ($0.isNumber || ("a"..."f").contains(String($0))) }) else { return nil }
        return record
    }
    static func cached(_ address: URL, original: URL?, directory: URL) -> (url: URL, transcoded: Bool)? {
        guard let receipt = receipt(address, directory: directory) else { return nil }
        // Local/offline originals must still exist. A remote cache alias keeps
        // the same URL identity policy as the original browsing cache.
        if address.isFileURL || original != nil {
            guard let original, identity(original) == receipt.source else { return nil }
        }
        let output = directory.appendingPathComponent(outputName(address, content: receipt.content, transcoded: receipt.transcoded))
        guard identity(output)?.size == receipt.outputBytes else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: output.path)
        return (output, receipt.transcoded)
    }
    static func commit(_ address: URL, original: URL, content: String, transcoded: Bool, output: URL, directory: URL) throws {
        guard let source = identity(original), let size = identity(output)?.size else { throw MediaRepairError.output }
        let receipt = Receipt(version: 1, source: source, content: content, transcoded: transcoded, outputBytes: size)
        try JSONEncoder().encode(receipt).write(to: receiptURL(address, directory: directory), options: .atomic)
    }
    static func associatedFiles(_ address: URL, directory: URL) -> [URL] {
        let start = stem(address)
        return ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []).filter {
            let name = $0.lastPathComponent
            return name == start + ".json" || (name.hasPrefix(start + "-") && ["mp4", "partial"].contains($0.pathExtension))
        }
    }
    static func associatedBytes(_ address: URL, directory: URL) -> Int64 {
        associatedFiles(address, directory: directory).reduce(0) { $0 + (identity($1)?.size ?? 0) }
    }
    /// One directory snapshot for any number of offline records, rather than a
    /// complete directory enumeration for each record on the main actor.
    static func familySnapshot(_ files: [URL], sizes: [String: Int64]? = nil) -> (files: [String: [URL]], bytes: [String: Int64]) {
        var grouped: [String: [URL]] = [:], bytes: [String: Int64] = [:]
        for file in files {
            let name = file.lastPathComponent
            guard name.hasPrefix(prefix), name.count > prefix.count + 64 else { continue }
            let key = String(name.prefix(prefix.count + 64))
            let digest = key.dropFirst(prefix.count)
            guard digest.allSatisfy({ $0.isASCII && ($0.isNumber || ("a"..."f").contains(String($0))) }),
                  name == key + ".json" || (name.hasPrefix(key + "-") && ["mp4", "partial"].contains(file.pathExtension)) else { continue }
            grouped[key, default: []].append(file)
            bytes[key, default: 0] += sizes?[file.standardizedFileURL.path] ?? identity(file)?.size ?? 0
        }
        return (grouped, bytes)
    }
    static func removeAssociated(_ address: URL, directory: URL) throws {
        for file in associatedFiles(address, directory: directory) {
            // Delete only the precise file family belonging to this original.
            try FileManager.default.removeItem(at: file)
        }
    }
}
