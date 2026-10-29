import Foundation
import Combine
import CryptoKit

enum FilterPresetScope: String, Codable, CaseIterable {
    case recommendation, following, search
    var title: String { switch self { case .recommendation: "推荐"; case .following: "关注"; case .search: "搜索" } }
}

private struct PresetSearchSnapshot: Codable, Equatable {
    var titlePrefix: String?
    var authorID: Int?
    var authorUsername: String?
    var tags: [PresetTagSnapshot]

    init(_ criteria: MediaSearchCriteria) {
        let title = MediaSearchText.normalized(criteria.text)
        titlePrefix = title.isEmpty ? nil : title
        authorID = criteria.author?.id
        authorUsername = criteria.author?.username
        tags = criteria.tags.map { PresetTagSnapshot(id: $0.id, name: $0.name, nsfwLevel: $0.nsfwLevel) }
    }

    var criteria: MediaSearchCriteria {
        MediaSearchCriteria(text: titlePrefix ?? "", author: authorID.flatMap { id in
            guard let authorUsername else { return nil }
            return Creator(id: id, username: authorUsername, image: nil)
        }, tags: tags.map { SearchTag(id: $0.id, name: $0.name, nsfwLevel: $0.nsfwLevel) })
    }

    var valid: Bool {
        guard tags.count <= 8, tags.allSatisfy({
            let name = $0.name
            return $0.id > 0 && !name.isEmpty && name.count <= 80 && !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }), Set(tags.map(\.id)).count == tags.count else { return false }
        guard (authorID == nil) == (authorUsername == nil), (authorID.map { $0 > 0 } ?? true) else { return false }
        if let authorUsername, !MediaSearchText.valid(authorUsername, mode: .author) { return false }
        if let titlePrefix, !MediaSearchText.valid(titlePrefix, mode: .title) { return false }
        return criteria.valid
    }
}

private struct PresetTagSnapshot: Codable, Equatable {
    let id: Int
    let name: String
    let nsfwLevel: Int?
}

struct FilterPresetSnapshot: Codable, Equatable {
    var filter: FeedFilter
    private var search: PresetSearchSnapshot?

    init(filter: FeedFilter, criteria: MediaSearchCriteria? = nil) {
        var normalized = filter
        if normalized.videoDurationRange != nil { normalized.kind = .video }
        self.filter = normalized
        self.search = criteria.map(PresetSearchSnapshot.init)
    }

    private enum CodingKeys: String, CodingKey { case filter, search }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        var decodedFilter = try values.decode(FeedFilter.self, forKey: .filter)
        if decodedFilter.videoDurationRange != nil { decodedFilter.kind = .video }
        let decodedSearch = try values.decodeIfPresent(PresetSearchSnapshot.self, forKey: .search)
        // Validate the persisted fields before converting them to search criteria;
        // an incomplete author pair must never silently widen a saved search.
        if let decodedSearch, !decodedSearch.valid { throw FilterPresetError.invalidSnapshot }
        filter = decodedFilter
        search = decodedSearch
    }

    var criteria: MediaSearchCriteria? { search?.criteria }
    func matches(_ other: FilterPresetSnapshot) -> Bool {
        filter == other.filter && criteria?.id == other.criteria?.id &&
            criteria?.author?.username.lowercased() == other.criteria?.author?.username.lowercased()
    }

    func validated(for scope: FilterPresetScope) throws {
        guard FeedSort(rawValue: filter.sort) != nil,
              FeedPeriod(rawValue: filter.period) != nil,
              ["", "SDXL 1.0", "Flux.1 D", "Wan Video"].contains(filter.baseModel),
              (filter.videoDurationRange == nil || filter.effectiveKind == .video) else { throw FilterPresetError.invalidSnapshot }
        switch scope {
        case .search:
            guard let search, search.valid else { throw FilterPresetError.invalidSnapshot }
        case .recommendation, .following:
            guard search == nil else { throw FilterPresetError.invalidSnapshot }
        }
    }
}

struct FilterPreset: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var snapshot: FilterPresetSnapshot
    let createdAt: Date
    var updatedAt: Date
    var summary: String {
        ([snapshot.filter.summary] + (snapshot.criteria.map { [$0.summary] } ?? [])).joined(separator: " · ")
    }
}

enum FilterPresetError: Error, LocalizedError, Equatable {
    case invalidName, duplicateName, invalidSnapshot, malformedFile, tooManyPresets, fileTooLarge, writeFailed
    var errorDescription: String? {
        switch self {
        case .invalidName: "名称需为 1—40 个字符。"
        case .duplicateName: "此范围已有同名方案。"
        case .invalidSnapshot: "筛选条件无效，请检查后重试。"
        case .malformedFile: "筛选方案文件损坏，原数据已保留。"
        case .tooManyPresets: "每个账号最多保存 50 个筛选方案。"
        case .fileTooLarge: "筛选方案存储已达到 1 MiB 上限。"
        case .writeFailed: "无法保存筛选方案，请检查本机存储空间。"
        }
    }
}

@MainActor final class FilterPresetStore: ObservableObject {
    static let shared = FilterPresetStore()
    @Published private(set) var revision = 0
    private struct Document: Codable { let schema: Int; var scopes: [String: [FilterPreset]] }
    private struct OwnerKey: Hashable { let ownerID: Int? }
    private var cache: [OwnerKey: Document] = [:]
    private var cachedOwners: [Int?] = []
    private let root: URL
    private let fm: FileManager
    private let encoder: JSONEncoder

    init(root: URL? = nil, fileManager: FileManager = .default) {
        self.fm = fileManager
        self.root = root ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CivitViewer/FilterPresets", isDirectory: true)
        self.encoder = JSONEncoder(); self.encoder.outputFormatting = [.sortedKeys]
    }

    func list(ownerID: Int?, scope: FilterPresetScope) throws -> [FilterPreset] { try load(ownerID: ownerID).scopes[scope.rawValue] ?? [] }

    @discardableResult
    func save(ownerID: Int?, scope: FilterPresetScope, name rawName: String, snapshot: FilterPresetSnapshot) throws -> FilterPreset {
        var doc = try load(ownerID: ownerID)
        var rows = doc.scopes[scope.rawValue] ?? []
        let name = try normalizedName(rawName)
        try ensureUnique(name, excluding: nil, rows: rows)
        try snapshot.validated(for: scope)
        guard doc.scopes.values.reduce(0, { $0 + $1.count }) < 50 else { throw FilterPresetError.tooManyPresets }
        let now = Date(), item = FilterPreset(id: UUID(), name: name, snapshot: snapshot, createdAt: now, updatedAt: now)
        rows.append(item); doc.scopes[scope.rawValue] = rows; try persist(doc, ownerID: ownerID); return item
    }

    @discardableResult
    func updateName(ownerID: Int?, scope: FilterPresetScope, id: UUID, name rawName: String) throws -> FilterPreset {
        var doc = try load(ownerID: ownerID)
        var rows = doc.scopes[scope.rawValue] ?? []
        guard let index = rows.firstIndex(where: { $0.id == id }) else { throw FilterPresetError.malformedFile }
        let name = try normalizedName(rawName); try ensureUnique(name, excluding: id, rows: rows)
        rows[index].name = name; rows[index].updatedAt = Date()
        doc.scopes[scope.rawValue] = rows; try persist(doc, ownerID: ownerID); return rows[index]
    }

    func delete(ownerID: Int?, scope: FilterPresetScope, id: UUID) throws {
        var doc = try load(ownerID: ownerID)
        var rows = doc.scopes[scope.rawValue] ?? []
        guard rows.contains(where: { $0.id == id }) else { return }
        rows.removeAll { $0.id == id }; doc.scopes[scope.rawValue] = rows; try persist(doc, ownerID: ownerID)
    }

    private func normalizedName(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...40).contains(value.count), !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw FilterPresetError.invalidName }
        return value
    }
    private func ensureUnique(_ name: String, excluding id: UUID?, rows: [FilterPreset]) throws {
        guard !rows.contains(where: { $0.id != id && $0.name.compare(name, options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")) == .orderedSame }) else { throw FilterPresetError.duplicateName }
    }
    private func load(ownerID: Int?) throws -> Document {
        guard ownerID.map({ $0 > 0 }) ?? true else { throw FilterPresetError.invalidSnapshot }
        let key = OwnerKey(ownerID: ownerID)
        if let doc = cache[key] { touch(ownerID); return doc }
        let url = fileURL(ownerID: ownerID)
        guard fm.fileExists(atPath: url.path) else {
            let empty = Document(schema: 1, scopes: [:]); cache[key] = empty; touch(ownerID); return empty
        }
        do {
            let reader = try FileHandle(forReadingFrom: url)
            defer { try? reader.close() }
            let data = try reader.read(upToCount: 1_048_577) ?? Data()
            guard data.count <= 1_048_576 else { throw FilterPresetError.fileTooLarge }
            let doc = try JSONDecoder().decode(Document.self, from: data)
            guard doc.schema == 1, Set(doc.scopes.keys).isSubset(of: Set(FilterPresetScope.allCases.map(\.rawValue))),
                  doc.scopes.values.reduce(0, { $0 + $1.count }) <= 50 else { throw FilterPresetError.malformedFile }
            var allIDs = Set<UUID>()
            for (scopeKey, rows) in doc.scopes {
                guard let scope = FilterPresetScope(rawValue: scopeKey) else { throw FilterPresetError.malformedFile }
                for item in rows {
                    try item.snapshot.validated(for: scope); _ = try normalizedName(item.name)
                    guard allIDs.insert(item.id).inserted else { throw FilterPresetError.malformedFile }
                }
                for left in rows.indices {
                    for right in rows.indices where right > left {
                        try ensureUnique(rows[left].name, excluding: rows[left].id, rows: [rows[right]])
                    }
                }
            }
            cache[key] = doc; touch(ownerID); return doc
        } catch let error as FilterPresetError { throw error }
        catch { throw FilterPresetError.malformedFile }
    }
    private func persist(_ doc: Document, ownerID: Int?) throws {
        do {
            let data = try encoder.encode(doc)
            guard data.count <= 1_048_576 else { throw FilterPresetError.fileTooLarge }
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            try data.write(to: fileURL(ownerID: ownerID), options: .atomic)
            cache[OwnerKey(ownerID: ownerID)] = doc; touch(ownerID); revision += 1
        } catch let error as FilterPresetError { throw error }
        catch { throw FilterPresetError.writeFailed }
    }
    private func touch(_ ownerID: Int?) {
        cachedOwners.removeAll { $0 == ownerID }; cachedOwners.append(ownerID)
        while cachedOwners.count > 4 {
            let evicted = cachedOwners.removeFirst(); cache.removeValue(forKey: OwnerKey(ownerID: evicted))
        }
    }
    private func fileURL(ownerID: Int?) -> URL {
        let identity = ownerID.map(String.init) ?? "anonymous"
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent("\(digest).json")
    }
}
