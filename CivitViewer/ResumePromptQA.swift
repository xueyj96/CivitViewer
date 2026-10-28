#if DEBUG && targetEnvironment(simulator)
import Foundation
import Combine
import SwiftUI
import UIKit
import AVFoundation

@MainActor enum ResumePromptQA {
    static let enabled = ProcessInfo.processInfo.arguments.contains("--qa-resume-prompt")
    static let manualUI = ProcessInfo.processInfo.arguments.contains("--qa-resume-prompt-ui")
    static let reset = ProcessInfo.processInfo.arguments.contains("--qa-resume-prompt-reset")
    static let scenario: String = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--qa-scenario=") })?.components(separatedBy: "=").last ?? "dismiss"
    static let runID: String = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--qa-run-id=") })?.components(separatedBy: "=").last ?? "unspecified"
    static let ownerID = 28_029_001
    static let itemIDs = [28_029_101, 28_029_102, 28_029_103, 28_029_104, 28_029_105]
    static var filter: FeedFilter {
        scenario.contains("following")
            ? FeedFilter(kind: .video, sort: "Most Comments", period: "Month", onlyPG: true)
            : FeedFilter(kind: .all, sort: "Most Reactions", period: "Week", onlyPG: true)
    }
    static var defaultsSuite: String { "com.xueyj.civitviewer.native-resume-qa.\(runID)" }
    static let defaultsKey = "resumePromptDismissals.v2"
    static var defaults: UserDefaults { UserDefaults(suiteName: defaultsSuite)! }
    static var rootURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(manualUI ? "CivitResumePromptQA-UI-\(runID)" : "CivitResumePromptQA-native-fixed", isDirectory: true)
    }
    static var fixtureURL: URL { rootURL.appendingPathComponent("pattern.png") }
    static func imageURL(for id: Int) -> URL { rootURL.appendingPathComponent("pattern-\(id).png") }
    static var mediaFixtureRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CivitResumePromptMediaQA", isDirectory: true)
    }
    static var videoFixtureURL: URL { mediaFixtureRoot.appendingPathComponent("short.mp4") }
    static func videoURL(for id: Int) -> URL { mediaFixtureRoot.appendingPathComponent("short-\(id).mp4") }
    static var checkpointURL: URL {
        rootURL.appendingPathComponent(BrowsingHistory.key(ownerID), isDirectory: true).appendingPathComponent("history.json")
    }
    static func dismissals() -> TimelineCheckpointDismissals {
        TimelineCheckpointDismissals(defaults: defaults, key: defaultsKey)
    }
    static var items: [MediaItem] {
        let video = scenario.contains("video") || scenario.contains("following")
        let count = scenario == "restart-presentation" ? 3 : scenario.hasPrefix("restart-short-") ? (Int(scenario.split(separator: "-").last ?? "") ?? 3)
            : (scenario.hasPrefix("restart-") ? itemIDs.count : 2)
        return itemIDs.prefix(count).enumerated().map { index, id in
            var item = MediaItem(id: id, url: "https://example.invalid/native-resume-\(index).\(video ? "mp4" : "png")", width: video ? 320 : 192, height: video ? 180 : 256,
                                 type: video ? "video" : "image", username: "NativeResumePattern", browsingLevel: 1,
                                 thumbnail: nil, creatorID: ownerID, tags: [])
            item.offlineMediaURL = video ? videoURL(for: id) : imageURL(for: id)
            return item
        }
    }
    static func fixtureItems(for ids: [Int]) -> [MediaItem] { items.filter { ids.contains($0.id) } }

    static func prepareHistory() async throws {
        if reset {
            try? FileManager.default.removeItem(at: rootURL)
            defaults.removePersistentDomain(forName: defaultsSuite)
        }
        if scenario == "restart-presentation" { defaults.set(TimelinePresentation.grid.rawValue, forKey: "timeline.presentation") }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try writeFixture()
        let imageData = try Data(contentsOf: fixtureURL)
        for id in itemIDs { try imageData.write(to: imageURL(for: id), options: .atomic) }
        if FileManager.default.fileExists(atPath: videoFixtureURL.path) {
            let videoData = try Data(contentsOf: videoFixtureURL)
            for id in itemIDs { try videoData.write(to: videoURL(for: id), options: .atomic) }
        }
        guard !FileManager.default.fileExists(atPath: checkpointURL.path) else { return }
        if scenario.hasPrefix("restart-") { return }
        let focused = scenario == "restore-failure" ? itemIDs[2] : (scenario == "readback-new" ? itemIDs[1] : itemIDs[0])
        let lane: HistoryLane = scenario.contains("following") ? .following : .recommendation
        let continuation = scenario.contains("legacy-nil") ? nil : TimelineContinuation(cursor: "qa-next", reachedEnd: false)
        let seeder = BrowsingHistory(rootURL: rootURL)
        await seeder.bind(ownerID: ownerID, identity: "native-resume-seeder")
        guard let context = seeder.context(ownerID: ownerID) else { throw CocoaError(.fileWriteUnknown) }
        let checkpoint = TimelineCheckpoint(lane: lane, filter: filter,
            ids: scenario == "restore-failure" ? itemIDs : Array(itemIDs.prefix(2)), focusedID: focused, updatedAt: Date(),
            continuation: continuation)
        seeder.checkpoint(checkpoint, context: context)
        await seeder.waitForWrites()
        if scenario == "readback-consumed" {
            dismissals().dismiss(owner: context.ownerKey, lane: .recommendation, checkpoint: checkpoint)
        }
    }
    private static func writeFixture() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 192, height: 256))
        let image = renderer.image { context in
            let cg = context.cgContext
            cg.setFillColor(UIColor(red: 0.04, green: 0.12, blue: 0.24, alpha: 1).cgColor)
            cg.fill(CGRect(x: 0, y: 0, width: 192, height: 256))
            cg.setFillColor(UIColor(red: 0.12, green: 0.72, blue: 0.96, alpha: 1).cgColor)
            cg.fill(CGRect(x: 24, y: 24, width: 144, height: 56))
            cg.setFillColor(UIColor(red: 0.98, green: 0.48, blue: 0.18, alpha: 1).cgColor)
            cg.fillEllipse(in: CGRect(x: 48, y: 112, width: 96, height: 96))
        }
        guard let data = image.pngData() else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: fixtureURL, options: .atomic)
    }

    static func recordPageRequest(filter: FeedFilter, cursor: String?, creator: Creator?, followed: Bool) {
        guard manualUI else { return }
        let value: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: Date()),
            "source": followed ? "following" : (creator == nil ? "recommendation" : "creator"),
            "cursor": cursor as Any? ?? NSNull(),
            "sort": filter.sort,
            "period": filter.period,
            "kind": filter.kind.rawValue,
            "creatorID": creator?.id as Any? ?? NSNull()
        ]
        let url = rootURL.appendingPathComponent("page-requests.jsonl")
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let line = data + Data([0x0A])
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
            try? handle.close()
        } else {
            try? line.write(to: url, options: .atomic)
        }
    }
}

@MainActor final class ResumePromptQAController: ObservableObject {
    struct RectValue: Codable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
        init(_ rect: CGRect?) {
            let value = rect ?? .zero
            x = value.origin.x; y = value.origin.y; width = value.size.width; height = value.size.height
        }
    }
    struct Snapshot: Codable {
        let phase: String
        let runID: String
        let capturedAt: Date
        let scenePhase: String
        let showsPrompt: Bool
        let baselineOfferFocusedID: Int?
        let baselineOfferUpdatedAt: Date?
        let baselineOfferSignature: String?
        let visibleCandidateFocusedID: Int?
        let focusedID: Int?
        let feedIDs: [Int]
        let historyReady: Bool
        let historyRecordIDs: [Int]
        let archiveCheckpointFocusedID: Int?
        let archiveCheckpointUpdatedAt: Date?
        let archiveCheckpointSignature: String?
        let restoreState: String
        let message: String?
        let viewportFrame: RectValue
        let focusedPageFrame: RectValue
        let actionsFrame: RectValue
    }
    private weak var model: TimelineModel?
    private weak var session: SiteSession?
    private weak var history: BrowsingHistory?
    var setTab: ((Int) -> Void)?
    var setMediaActive: ((Bool) -> Void)?
    private var currentScenePhase = "active"
    @Published private(set) var playerMuteStatus = "no-player"
    private var frames: [String: CGRect] = [:]
    private var initialGeometryCaptured = false
    private var didStart = false
    private let laneFollowed: Bool?
    private var laneControllers: [Bool: ResumePromptQAController] = [:]
    private var laneObservers: [Bool: AnyCancellable] = [:]
    private var observedLaneValues: [Bool: String] = [:]
    private var modelObserver: AnyCancellable?
    @Published private(set) var statusRevision = 0

    init(laneFollowed: Bool? = nil) { self.laneFollowed = laneFollowed }

    func controller(for followed: Bool) -> ResumePromptQAController {
        if laneFollowed == followed { return self }
        if let existing = laneControllers[followed] { return existing }
        let child = ResumePromptQAController(laneFollowed: followed)
        laneControllers[followed] = child
        laneObservers[followed] = child.objectWillChange.sink { [weak self, weak child] _ in
            Task { @MainActor in
                guard let self, let child else { return }
                self.observedLaneValues[followed] = child.statusValue
                self.statusRevision &+= 1
            }
        }
        return child
    }

    var statusValue: String {
        let url = ResumePromptQA.rootURL.appendingPathComponent("page-requests.jsonl")
        let log = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let lines = log.split(whereSeparator: \.isNewline)
        let requests = lines.compactMap { line -> [String: Any]? in
            guard let data = String(line).data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        let count = requests.count
        let request = requests.last
        let requestCursor: String = request?["cursor"] is NSNull ? "nil" : (request?["cursor"] as? String ?? "none")
        let requestSource = request?["source"] as? String ?? "none"
        let requestKind = request?["kind"] as? String ?? "none"
        let requestSort = request?["sort"] as? String ?? "none"
        let requestPeriod = request?["period"] as? String ?? "none"
        func laneModel(_ followed: Bool) -> TimelineModel? {
            laneControllers[followed]?.model ?? (laneFollowed == followed ? model : nil)
        }
        func laneCursor(_ value: TimelineModel?) -> String {
            value.flatMap { $0.feed.continuationSnapshot(windowIDs: $0.feed.items.map(\.id))?.cursor } ?? "nil"
        }
        func laneFirstPageCount(_ followed: Bool) -> Int {
            requests.filter { ($0["source"] as? String) == (followed ? "following" : "recommendation") && $0["cursor"] is NSNull }.count
        }
        let recommendation = laneModel(false)
        let followed = laneModel(true)
        let preferredLane = ResumePromptQA.scenario.contains("following")
        let current = laneControllers[preferredLane]?.model ?? laneControllers[false]?.model ?? model
        let filter = current?.filter
        let source = current.map { $0.followed ? "following" : "recommendation" } ?? "unknown"
        let cursor = current.flatMap { $0.feed.continuationSnapshot(windowIDs: $0.feed.items.map(\.id))?.cursor } ?? "nil"
        let focus = current?.focused.map(String.init) ?? "nil"
        let queueCount = current?.feed.items.count ?? 0
        let state: String = switch current?.restoreState {
        case .browsing?: "browsing"
        case .restoring?: "restoring"
        case .refreshing?: "refreshing"
        case .resumed(_, let continuation)?: "resumed-\(continuation)"
        case .none: "missing"
        }
        let totalFirstPageCount = requests.filter { $0["cursor"] is NSNull }.count
        let recFocus = recommendation?.focused.map(String.init) ?? "nil"
        let followFocus = followed?.focused.map(String.init) ?? "nil"
        let recQueueCount = recommendation?.feed.items.count ?? 0
        let followQueueCount = followed?.feed.items.count ?? 0
        let recLane = observedLaneValues[false] ?? "pending"
        let followLane = observedLaneValues[true] ?? "pending"
        return "pageRequests=\(count);firstPageRequests=\(totalFirstPageCount);source=\(source);kind=\(filter?.kind.rawValue ?? "unknown");sort=\(filter?.sort ?? "unknown");period=\(filter?.period ?? "unknown");cursor=\(cursor);focus=\(focus);queueCount=\(queueCount);state=\(state);lastSource=\(requestSource);lastKind=\(requestKind);lastSort=\(requestSort);lastPeriod=\(requestPeriod);lastCursor=\(requestCursor);recFirstPageRequests=\(laneFirstPageCount(false));recFocus=\(recFocus);recCursor=\(laneCursor(recommendation));recQueueCount=\(recQueueCount);followFirstPageRequests=\(laneFirstPageCount(true));followFocus=\(followFocus);followCursor=\(laneCursor(followed));followQueueCount=\(followQueueCount);recLane=\(recLane);followLane=\(followLane)"
    }

    func attach(model: TimelineModel, session: SiteSession, history: BrowsingHistory) {
        self.model = model; self.session = session; self.history = history
        guard !didStart else { return }
        didStart = true
        model.bindHistory(ownerID: ResumePromptQA.ownerID)
        if !ResumePromptQA.manualUI { model.setVisible(true) }
        if ResumePromptQA.manualUI, model.filter != ResumePromptQA.filter { model.selectFilter(ResumePromptQA.filter) }
        model.feed.restoreTimeline(items: ResumePromptQA.items, identity: session.feedIdentity,
            filter: ResumePromptQA.filter, followed: model.followed,
            continuation: TimelineContinuation(cursor: "qa-next", reachedEnd: false), blockedTags: [])
        model.focused = ResumePromptQA.scenario.hasPrefix("readback-")
            ? (model.resumeCandidate?.focusedID ?? ResumePromptQA.itemIDs[0]) : ResumePromptQA.itemIDs[0]
        setMediaActive?(ResumePromptQA.manualUI)
        modelObserver = model.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.observedModelChange() }
        }
        Task { @MainActor [weak self] in self?.statusRevision &+= 1 }
        capture("initial")
        if ResumePromptQA.scenario.hasPrefix("readback-") {
            capture("process-readback-\(ResumePromptQA.scenario)")
            return
        }
        if ResumePromptQA.manualUI { return }
        Task { await run() }
    }

    private func observedModelChange() {
        statusRevision &+= 1
        if ResumePromptQA.manualUI { capture("ui-observed") }
    }

    func visibilityChanged(_ visible: Bool) { model?.setVisible(visible) }
    func updateFrames(_ value: [String: CGRect]) {
        frames = value
        guard !initialGeometryCaptured,
              let viewport = value["viewport"], viewport.width > 0, viewport.height > 0,
              let page = value["page-\(ResumePromptQA.itemIDs[0])"], page.width > 0, page.height > 0,
              let actions = value["actions-\(ResumePromptQA.itemIDs[0])"], actions.width > 0, actions.height > 0 else { return }
        initialGeometryCaptured = true
        capture("initial-layout-ready")
    }
    func scenePhaseChanged(_ phase: String) {
        currentScenePhase = phase
        capture("scene-\(phase)")
    }
    func observePlayerMute(_ value: String) {
        guard playerMuteStatus != value else { return }
        playerMuteStatus = value
        statusRevision &+= 1
    }

    private func run() async {
        guard let model, let session else { return }
        let scenario = ResumePromptQA.scenario
        guard await ack("dismiss-\(scenario)") else { return }
        if scenario == "dismiss" {
            model.dismissPrompt()
            capture("after-dismiss")
        } else {
            guard let checkpoint = model.resumeCandidate else {
                capture("missing-initial-offer"); return
            }
            await model.restore(checkpoint, session: session)
            capture("after-restore")
        }
        guard await ack("next-\(scenario)") else { return }
        await model.next(session: session)
        setMediaActive?(true)
        model.focused = ResumePromptQA.itemIDs[1]
        capture("focus-next")
        guard await waitForRecord(ResumePromptQA.itemIDs[1], seconds: 15) else {
            capture("exposure-timeout"); return
        }
        capture("after-exposure")
        guard await ack("refresh-\(scenario)") else { return }
        await model.activate(session: session, visible: true, blockedTags: [], force: true)
        capture("after-refresh")
        setTab?(2)
        try? await Task.sleep(for: .milliseconds(600))
        setTab?(0)
        await Task.yield()
        guard await ack("capture-tab-return-1s") else { return }
        capture("tab-return-1s")
        guard await ack("capture-tab-return-3s") else { return }
        capture("tab-return-3s")
    }

    private func waitForRecord(_ id: Int, seconds: Int) async -> Bool {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < .seconds(seconds) {
            if history?.records.contains(where: { $0.id == id }) == true,
               history?.checkpoint(for: .recommendation)?.focusedID == id { return true }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return false }
        }
        return false
    }
    private func ack(_ name: String, timeout: Int = 90) async -> Bool {
        let path = ResumePromptQA.rootURL.appendingPathComponent("ack-" + name)
        try? Data("waiting".utf8).write(to: ResumePromptQA.rootURL.appendingPathComponent("waiting-\(name).json"), options: .atomic)
        let start = ContinuousClock.now
        while ContinuousClock.now - start < .seconds(timeout) {
            if FileManager.default.fileExists(atPath: path.path) { return true }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return false }
        }
        capture("ack-timeout-\(name)"); return false
    }
    func capture(_ phase: String) {
        guard let model, let history else { return }
        let context = model.context
        let baseline = context.flatMap { history.resumeOffer(for: model.lane, context: $0) }
        let cp = history.checkpoint(for: model.lane)
        func signature(_ checkpoint: TimelineCheckpoint?) -> String? {
            guard let checkpoint, let context else { return nil }
            return TimelineStatePolicy.dismissalSignature(owner: context.ownerKey, lane: model.lane, checkpoint: checkpoint)
        }
        let state: String
        switch model.restoreState {
        case .browsing: state = "browsing"
        case .restoring: state = "restoring"
        case .refreshing: state = "refreshing"
        case .resumed(_, let continuation): state = "resumed-\(continuation)"
        }
        let value = Snapshot(phase: phase, runID: ResumePromptQA.runID, capturedAt: Date(), scenePhase: currentScenePhase,
            showsPrompt: model.resumeCandidate != nil,
            baselineOfferFocusedID: baseline?.focusedID, baselineOfferUpdatedAt: baseline?.updatedAt,
            baselineOfferSignature: signature(baseline), visibleCandidateFocusedID: model.resumeCandidate?.focusedID,
            focusedID: model.focused, feedIDs: model.feed.items.map(\.id), historyReady: history.ready,
            historyRecordIDs: history.records.map(\.id), archiveCheckpointFocusedID: cp?.focusedID,
            archiveCheckpointUpdatedAt: cp?.updatedAt, archiveCheckpointSignature: signature(cp),
            restoreState: state, message: model.message,
            viewportFrame: RectValue(frames["viewport"]),
            focusedPageFrame: RectValue(model.focused.flatMap { frames["page-\($0)"] }),
            actionsFrame: RectValue(model.focused.flatMap { frames["actions-\($0)"] }))
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? FileManager.default.createDirectory(at: ResumePromptQA.rootURL, withIntermediateDirectories: true)
        try? data.write(to: ResumePromptQA.rootURL.appendingPathComponent(phase + ".json"), options: .atomic)
        try? data.write(to: ResumePromptQA.rootURL.appendingPathComponent("readback.json"), options: .atomic)
    }
}

struct ResumePromptQAFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

struct ResumePromptQAView: View {
    @EnvironmentObject private var session: SiteSession
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var history = BrowsingHistory.shared
    @StateObject private var controller = ResumePromptQAController()
    @State private var ready = false
    @State private var selectedTab = 0
    @State private var restartRequest = 0
    @State private var topRequest = 0
    var body: some View {
        qaTabs
        .defaultAppStorage(ResumePromptQA.defaults)
        .overlay(alignment: .topLeading) {
            if ResumePromptQA.manualUI {
                VStack(spacing: 0) {
                    Text(controller.statusValue)
                        .accessibilityElement(children: .ignore).accessibilityIdentifier("qa-state")
                        .accessibilityValue(controller.statusValue)
                    Text(controller.playerMuteStatus)
                        .accessibilityElement(children: .ignore).accessibilityIdentifier("qa.player.muted")
                        .accessibilityLabel("qa.player.muted").accessibilityValue(controller.playerMuteStatus)
                }
                .font(.system(size: 1)).frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false)
            }
        }
        .background(ResumePromptQAPlayerProbe { controller.observePlayerMute($0) }.frame(width: 0, height: 0))
        .onAppear {
            controller.setTab = { selectedTab = $0 }
            if ResumePromptQA.manualUI {
                ResumePromptQA.defaults.set(true, forKey: "muted")
                ResumePromptQA.defaults.set(true, forKey: "autoplay")
            }
        }
        .onChange(of: scenePhase) { _, value in
            let state: String = switch value { case .active: "active"; case .inactive: "inactive"; case .background: "background"; @unknown default: "unknown" }
            controller.scenePhaseChanged(state)
        }
        .onPreferenceChange(ResumePromptQAFrameKey.self) { controller.updateFrames($0) }
        .task {
            session.configureForResumePromptQA()
            do {
                try await ResumePromptQA.prepareHistory()
                await history.bind(ownerID: ResumePromptQA.ownerID, identity: "native-resume-qa-\(ResumePromptQA.scenario)")
                ready = history.ready
            } catch {
                try? Data("setup-failed: \(error)".utf8).write(to: ResumePromptQA.rootURL.appendingPathComponent("setup-failed.txt"), options: .atomic)
            }
        }
    }

    @ViewBuilder private var qaTabs: some View {
        if ResumePromptQA.manualUI {
            MainTabs(selectedTab: $selectedTab,
                     onTimelineTap: { selectedTab = 0; topRequest &+= 1 },
                     onTimelineDoubleTap: { selectedTab = 0; restartRequest &+= 1 },
                     timeline: Group {
                         if ready {
                             TimelineView(isVisible: selectedTab == 0, restartRequest: restartRequest, topRequest: topRequest, qaController: controller)
                         } else {
                             ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
                         }
                     }, authors: Color.black, search: Color.black, settings: Color.black)
        } else {
            TabView(selection: $selectedTab) {
                NavigationStack {
                    if ready {
                        TimelineLane(isVisible: selectedTab == 0, followed: false, qaController: controller)
                            .overlay(alignment: .bottom) {
                                Text("SIMULATOR ONLY · FIXED RESUME QA")
                                    .font(.caption2.monospaced()).padding(7)
                                    .background(.black.opacity(0.6), in: Capsule()).padding(.bottom, 8)
                                    .allowsHitTesting(false)
                            }
                    } else {
                        ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
                    }
                }.tabItem { Label("时间线", systemImage: "rectangle.portrait.on.rectangle.portrait") }.tag(0)
                Color.black.tabItem { Label("QA 隐藏页", systemImage: "eye.slash") }.tag(1)
            }
        }
    }
}

private struct ResumePromptQAPlayerProbe: UIViewRepresentable {
    let onState: (String) -> Void
    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.onState = onState
        return view
    }
    func updateUIView(_ view: ProbeView, context: Context) {
        view.onState = onState
        DispatchQueue.main.async { [weak view] in view?.refresh() }
    }

    final class ProbeView: UIView {
        var onState: ((String) -> Void)?
        private var timer: Timer?
        private var lastState: String?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil, timer == nil else { return }
            DispatchQueue.main.async { [weak self] in self?.refresh() }
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.refresh() }
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            DispatchQueue.main.async { [weak self] in self?.refresh() }
        }
        private func publish(_ value: String) {
            guard lastState != value else { return }
            lastState = value
            DispatchQueue.main.async { [weak self] in self?.onState?(value) }
        }
        func refresh() {
            guard let root = window?.layer else { publish("no-window"); return }
            func findPlayerLayer(_ layer: CALayer) -> AVPlayerLayer? {
                if let playerLayer = layer as? AVPlayerLayer, playerLayer.player != nil { return playerLayer }
                for child in layer.sublayers ?? [] {
                    if let found = findPlayerLayer(child) { return found }
                }
                return nil
            }
            guard let player = findPlayerLayer(root)?.player else { publish("no-player"); return }
            publish(player.isMuted ? "muted" : "unmuted")
        }
        deinit { timer?.invalidate() }
    }
}
#endif
