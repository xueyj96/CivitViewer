import Foundation
import Combine

struct BlockedAuthor: Codable, Equatable, Identifiable {
    let id: Int
    var username: String
}

@MainActor final class AuthorBlocklist: ObservableObject {
    private struct Envelope: Codable {
        let schemaVersion: Int
        let entries: [BlockedAuthor]
    }

    static let shared = AuthorBlocklist()
    static let storageKey = "blockedAuthors.v1"
    private static let schemaVersion = 1
    private static let maximumEntries = 200
    private static let maximumBytes = 128 * 1024

    @Published private(set) var entries: [BlockedAuthor] = []
    @Published private(set) var error: String?
    private let defaults: UserDefaults
    private let key: String
    private var persistenceValid = true

    var blockedIDs: Set<Int> { Set(entries.map(\.id)) }
    var blockedHandles: Set<String> {
        let grouped = Dictionary(grouping: entries, by: { AuthorHandlePolicy.normalize($0.username) })
        return Set(grouped.compactMap { handle, matches in matches.count == 1 ? handle : nil })
    }

    init(defaults: UserDefaults = .standard, key: String = "blockedAuthors.v1") {
        self.defaults = defaults
        self.key = key
        load()
    }

    @discardableResult
    func add(_ creator: Creator) -> Bool {
        guard persistenceValid, creator.id > 0, let username = Self.validUsername(creator.username),
              !entries.contains(where: { $0.id == creator.id }), entries.count < Self.maximumEntries else {
            if persistenceValid { error = "无法屏蔽该作者；请确认作者资料有效且名单未达到上限。" }
            return false
        }
        var updated = entries
        updated.append(BlockedAuthor(id: creator.id, username: username))
        return commit(updated)
    }

    func remove(id: Int) {
        guard persistenceValid, entries.contains(where: { $0.id == id }) else { return }
        _ = commit(entries.filter { $0.id != id })
    }

    func contains(id: Int) -> Bool { blockedIDs.contains(id) }

    func blocks(_ item: MediaItem) -> Bool {
        AuthorHandlePolicy.blocks(creatorID: item.creatorID, username: item.username,
                                  blockedIDs: blockedIDs, blockedHandles: blockedHandles)
    }

    func blocks(_ record: HistoryRecord) -> Bool {
        AuthorHandlePolicy.blocks(creatorID: record.creatorID, username: record.authorName,
                                  blockedIDs: blockedIDs, blockedHandles: blockedHandles)
    }

    func refreshKnownCreators(_ creators: [Creator]) {
        guard persistenceValid, !entries.isEmpty else { return }
        let updates = Dictionary(creators.filter { $0.id > 0 }.compactMap { creator in
            Self.validUsername(creator.username).map { (creator.id, $0) }
        }, uniquingKeysWith: { _, latest in latest })
        var changed = false
        let updated = entries.map { entry -> BlockedAuthor in
            guard let username = updates[entry.id], username != entry.username else { return entry }
            changed = true
            return BlockedAuthor(id: entry.id, username: username)
        }
        if changed { _ = commit(updated) }
    }

    private static func validUsername(_ value: String) -> String? {
        let username = value.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = AuthorHandlePolicy.normalize(username)
        guard !normalized.isEmpty,
              !username.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !normalized.contains("://"), !normalized.contains("/"), !normalized.contains("\\"),
              !normalized.contains("?"), !normalized.contains("#"), !normalized.hasPrefix("www."),
              !["http:", "https:", "ftp:"].contains(where: normalized.hasPrefix),
              URLComponents(string: username)?.scheme == nil else { return nil }
        return username
    }

    private func load() {
        guard let raw = defaults.object(forKey: key) else { return }
        guard let data = raw as? Data, data.count <= Self.maximumBytes else {
            rejectStoredValue(); return
        }
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.schemaVersion == Self.schemaVersion,
                  envelope.entries.count <= Self.maximumEntries,
                  envelope.entries.allSatisfy({ $0.id > 0 && Self.validUsername($0.username) == $0.username }),
                  Set(envelope.entries.map(\.id)).count == envelope.entries.count else {
                rejectStoredValue(); return
            }
            entries = envelope.entries
        } catch { rejectStoredValue() }
    }

    private func commit(_ values: [BlockedAuthor]) -> Bool {
        guard persistenceValid, values.count <= Self.maximumEntries else { return false }
        let envelope = Envelope(schemaVersion: Self.schemaVersion, entries: values)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(envelope), data.count <= Self.maximumBytes else {
            error = "屏蔽名单无法保存；现有名单保持不变。"
            return false
        }
        defaults.set(data, forKey: key)
        entries = values
        error = nil
        return true
    }

    private func rejectStoredValue() {
        persistenceValid = false
        error = "屏蔽名单文件损坏或版本不兼容；原数据已保留，暂不允许覆写。"
    }
}

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit

struct AuthorBlocklistView: View {
    @ObservedObject private var blocklist = AuthorBlocklist.shared

    var body: some View {
        List {
            Section {
                Text("仅在本机隐藏已屏蔽作者的作品，不会取消关注、移除收藏或删除浏览记录与媒体。")
                    .font(.footnote).foregroundStyle(.secondary)
                if let error = blocklist.error { Text(error).font(.caption).foregroundStyle(.red) }
                if blocklist.entries.isEmpty { Text("尚未屏蔽作者").foregroundStyle(.secondary) }
            }
            Section("已屏蔽 · \(blocklist.entries.count)") {
                ForEach(blocklist.entries) { author in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("@" + author.username).font(.body.weight(.medium))
                            Text("作者 ID \(author.id)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("取消屏蔽", role: .destructive) { blocklist.remove(id: author.id) }
                            .accessibilityLabel("取消屏蔽作者 " + author.username)
                    }.padding(.vertical, 3)
                }
            }
        }
        .navigationTitle("屏蔽作者")
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
