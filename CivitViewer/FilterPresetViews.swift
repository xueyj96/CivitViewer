import SwiftUI

@MainActor struct FilterPresetRequest: Identifiable {
    let id = UUID()
    let ownerID: Int?
    let identity: String
    let scope: FilterPresetScope
    let snapshot: FilterPresetSnapshot
    init(session: SiteSession, scope: FilterPresetScope, filter: FeedFilter, criteria: MediaSearchCriteria? = nil) {
        ownerID = session.tagLibraryOwnerID; identity = session.feedIdentity
        self.scope = scope; snapshot = .init(filter: filter, criteria: criteria)
    }
}

/// Every entry shares the same account/session guard, storage and presentation.
struct FilterPresetSheet: View {
    let request: FilterPresetRequest
    let onApply: (FilterPresetSnapshot) -> Void
    @EnvironmentObject private var session: SiteSession
    @Environment(\.dismiss) private var dismiss
    private var current: Bool { session.feedIdentity == request.identity && session.tagLibraryOwnerID == request.ownerID }
    var body: some View {
        FilterPresetLibraryView(ownerID: request.ownerID, scope: request.scope, current: request.snapshot,
            onApply: { snapshot in
                guard current else { return }
                onApply(snapshot)
            }, isCurrent: { current })
            .disabled(!current)
            .onChange(of: session.feedIdentity) { _, _ in dismiss() }
    }
}

struct FilterPresetLibraryView: View {
    let ownerID: Int?
    let scope: FilterPresetScope
    let current: FilterPresetSnapshot
    let onApply: (FilterPresetSnapshot) -> Void
    var isCurrent: () -> Bool = { true }

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = FilterPresetStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var presets: [FilterPreset] = []
    @State private var loadError: String?
    @State private var showNameEditor = false
    @State private var editorPreset: FilterPreset?
    @State private var editorName = ""
    @State private var deleteTarget: FilterPreset?
    @State private var operationError: String?
    @State private var sheetDetent: PresentationDetent = .height(360)
    @State private var libraryDetent: PresentationDetent = .height(360)
    private var canSave: Bool { (try? current.validated(for: scope)) != nil }

    var body: some View {
        NavigationStack {
            List {
                VStack(alignment: .leading, spacing: 5) {
                    Text("当前条件").font(.caption).foregroundStyle(.secondary)
                    Text(current.filter.summary).font(.subheadline.weight(.medium))
                    if let criteria = current.criteria, !criteria.summary.isEmpty {
                        Text(criteria.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .padding(.vertical, 6).listRowSeparator(.hidden)
                if let loadError {
                    Text(loadError).foregroundStyle(.red).accessibilityIdentifier("preset.library.error")
                } else if presets.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "bookmark").font(.title2).foregroundStyle(.secondary)
                        Text("还没有保存的方案").font(.headline)
                        Text(canSave ? "点右上角 ＋ 保存当前筛选。" : "填写搜索条件后即可保存。")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 20)
                    .listRowSeparator(.hidden).accessibilityIdentifier("preset.library.empty")
                } else {
                    ForEach(presets) { preset in
                        Button {
                            guard isCurrent() else { return }
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) { onApply(preset.snapshot) }
                            dismiss()
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(preset.name).font(.body.weight(.semibold)).foregroundStyle(.primary)
                                    Text(preset.summary).font(.footnote).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                if preset.snapshot.matches(current) { Image(systemName: "checkmark").foregroundStyle(.blue).accessibilityLabel("当前筛选") }
                            }.contentShape(Rectangle()).padding(.vertical, 5)
                        }
                        .buttonStyle(.plain).frame(minHeight: 44)
                        .accessibilityValue(preset.snapshot.matches(current) ? "当前筛选" : "应用方案")
                        .accessibilityIdentifier("preset.library.apply.\(preset.id.uuidString.lowercased())")
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("删除", role: .destructive) { guard isCurrent() else { return }; deleteTarget = preset }.accessibilityIdentifier("preset.library.delete.\(preset.id.uuidString.lowercased())")
                            Button("重命名") { beginRename(preset) }.tint(.blue).accessibilityIdentifier("preset.library.rename.\(preset.id.uuidString.lowercased())")
                        }
                        .contextMenu {
                            Button("重命名") { beginRename(preset) }
                            Button("删除", role: .destructive) { guard isCurrent() else { return }; deleteTarget = preset }
                        }
                    }
                }
                if let operationError { Text(operationError).font(.footnote).foregroundStyle(.red) }
            }
            .listStyle(.plain)
            .navigationTitle("筛选方案 · \(scope.title)").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("关闭筛选方案").accessibilityIdentifier("preset.library.done")
                }
                AppToolbarItem(placement: .topBarTrailing) {
                    Button { beginSave() } label: { Image(systemName: "plus") }
                        .disabled(!canSave || !isCurrent())
                        .accessibilityLabel("保存为方案").accessibilityIdentifier("preset.library.save")
                }
            }
            .navigationDestination(isPresented: $showNameEditor) {
                FilterPresetNameView(ownerID: ownerID, scope: scope,
                    snapshot: editorPreset?.snapshot ?? current,
                    mode: editorPreset.map { .rename($0.id) } ?? .save,
                    initialName: editorName, isCurrent: isCurrent) { refresh() }
            }
            .task { refresh() }
            .onChange(of: store.revision) { _, _ in refresh() }
            .onChange(of: showNameEditor) { _, editing in
                if editing { libraryDetent = sheetDetent; sheetDetent = .large }
                else { sheetDetent = libraryDetent }
            }
            .confirmationDialog("删除“\(deleteTarget?.name ?? "")”？", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }), titleVisibility: .visible) {
                Button("删除方案", role: .destructive) { guard isCurrent() else { deleteTarget = nil; return }; if let target = deleteTarget { remove(target) }; deleteTarget = nil }
                Button("取消", role: .cancel) { deleteTarget = nil }
            } message: { Text("只删除这个筛选方案。") }
        }
        .ordinaryAppearance()
        .presentationDetents([.height(360), .large], selection: $sheetDetent)
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("preset.library")
    }

    private func refresh() {
        do { presets = try store.list(ownerID: ownerID, scope: scope).sorted { $0.updatedAt > $1.updatedAt }; loadError = nil }
        catch { loadError = (error as? LocalizedError)?.errorDescription ?? "无法读取筛选方案。" }
    }
    private func beginSave() {
        guard isCurrent() else { return }
        editorPreset = nil
        let summary = ([current.filter.summary] + (current.criteria.map { [$0.summary] } ?? [])).joined(separator: " · ")
        let base = String(summary.prefix(40))
        let used = Set(presets.map { $0.name.lowercased() })
        var proposed = base
        for suffix in 2...51 where used.contains(proposed.lowercased()) {
            let ending = " (\(suffix))"
            proposed = String(base.prefix(40 - ending.count)) + ending
        }
        editorName = proposed
        showNameEditor = true
    }
    private func beginRename(_ preset: FilterPreset) {
        guard isCurrent() else { return }
        editorPreset = preset
        editorName = preset.name
        showNameEditor = true
    }
    private func remove(_ preset: FilterPreset) {
        guard isCurrent() else { return }
        do { try store.delete(ownerID: ownerID, scope: scope, id: preset.id); operationError = nil; refresh() }
        catch { operationError = (error as? LocalizedError)?.errorDescription }
    }
}

private struct FilterPresetNameView: View {
    enum Mode { case save, rename(UUID) }
    let ownerID: Int?
    let scope: FilterPresetScope
    let snapshot: FilterPresetSnapshot
    let mode: Mode
    let initialName: String
    let onSaved: () -> Void
    let isCurrent: () -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var error: String?

    init(ownerID: Int?, scope: FilterPresetScope, snapshot: FilterPresetSnapshot, mode: Mode, initialName: String = "", isCurrent: @escaping () -> Bool = { true }, onSaved: @escaping () -> Void) {
        self.ownerID = ownerID; self.scope = scope; self.snapshot = snapshot; self.mode = mode; self.initialName = initialName; self.isCurrent = isCurrent; self.onSaved = onSaved
        _name = State(initialValue: initialName)
    }

    private var isRename: Bool { if case .rename = mode { true } else { false } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("方案名称").font(.subheadline.weight(.semibold))
                    TextField("输入名称", text: $name)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.body).padding(.horizontal, 12).frame(minHeight: 48)
                        .background(AppTheme.secondarySurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(alignment: .bottom) { RoundedRectangle(cornerRadius: 1).fill(Color.blue.opacity(0.72)).frame(height: 1).padding(.horizontal, 12) }
                        .accessibilityIdentifier("preset.name.input")
                    Text("\(name.trimmingCharacters(in: .whitespacesAndNewlines).count) / 40")
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
                    if let error { Text(error).font(.footnote).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("preset.name.error") }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("筛选条件").font(.subheadline.weight(.semibold))
                    conditionRow("媒体", snapshot.filter.effectiveKind.title)
                    conditionRow("排序", FeedSort(rawValue: snapshot.filter.sort)?.title ?? snapshot.filter.sortTitle)
                    conditionRow("时间", snapshot.filter.periodTitle)
                    if !snapshot.filter.baseModel.isEmpty { conditionRow("模型", snapshot.filter.baseModel) }
                    conditionRow("内容范围", snapshot.filter.onlyPG ? "仅看 PG" : "遵循账号与站点设置")
                    if let duration = snapshot.filter.videoDurationRange { conditionRow("视频时长", duration.summary) }
                }

                if let criteria = snapshot.criteria {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("搜索条件").font(.subheadline.weight(.semibold))
                        if !criteria.normalizedText.isEmpty { conditionRow("标题开头", criteria.normalizedText) }
                        if let author = criteria.author { conditionRow("作者", "@\(author.username)") }
                        if !criteria.tags.isEmpty {
                            Text("标签").font(.caption).foregroundStyle(.secondary)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), alignment: .leading)], alignment: .leading, spacing: 8) {
                                ForEach(criteria.tags, id: \.id) { tag in
                                    Text("#\(tag.name)").font(.caption.weight(.medium)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                        .padding(.horizontal, 10).padding(.vertical, 7)
                                        .background(AppTheme.secondarySurface, in: Capsule())
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, AppTheme.spacing).padding(.top, 20).padding(.bottom, 18)
            .frame(maxWidth: 600, alignment: .leading).frame(maxWidth: .infinity, alignment: .top)
        }
        .navigationTitle(isRename ? "重命名方案" : "保存方案").navigationBarTitleDisplayMode(.inline)
        .appNavigationBack()
        .toolbar {
            AppToolbarItem(placement: .confirmationAction) {
                Button("保存") { save() }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !isCurrent())
                    .accessibilityIdentifier("preset.name.save")
            }
        }
        .ordinaryAppearance().accessibilityIdentifier("preset.name")
    }

    private func conditionRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            Text(value).font(.subheadline).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(minHeight: 32, alignment: .leading)
    }

    private func save() {
        guard isCurrent() else { error = "账号已切换，请关闭此面板后重试。"; return }
        do {
            switch mode {
            case .save: _ = try FilterPresetStore.shared.save(ownerID: ownerID, scope: scope, name: name, snapshot: snapshot)
            case .rename(let id): _ = try FilterPresetStore.shared.updateName(ownerID: ownerID, scope: scope, id: id, name: name)
            }
            error = nil; onSaved(); dismiss()
        } catch { self.error = (error as? LocalizedError)?.errorDescription ?? "无法保存筛选方案。" }
    }
}
