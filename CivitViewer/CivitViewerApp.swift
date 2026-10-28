import SwiftUI
import WebKit
import UIKit

// Visual thesis: full-bleed media, quiet native controls, one blue accent.
// Content: mixed timeline, two mature creator boards, creator media, follows, settings.
// Interaction: vertical paging, small filter sheet, native navigation into creators.
@main
struct CivitViewerApp: App {
    @UIApplicationDelegateAdaptor(ViewingAppDelegate.self) private var appDelegate
    @StateObject private var session = SiteSession()
    var body: some Scene {
        WindowGroup {
            Group {
            #if DEBUG
            if AppReadback.tagMediaRequested { TagMetadataReadbackView().environmentObject(session) }
            else {
            #if targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--qa-grid-retry55") { GridRetryQAView() }
            else if ProcessInfo.processInfo.arguments.contains("--qa-preparation48") { VideoPreparationOverlayQAView() }
            else if CollectionPagingQA.enabled { CollectionPagingQAView().environmentObject(session).environmentObject(session.oauth) }
            else if ResumePromptQA.enabled { ResumePromptQAView().environmentObject(session).environmentObject(session.oauth) }
            else if MediaFormatQA.enabled { MediaFormatQAView().environmentObject(session).environmentObject(session.oauth) }
            else if PlaybackLayoutQA.enabled { PlaybackLayoutQAView().environmentObject(session).environmentObject(session.oauth) }
            else { RootView().environmentObject(session).environmentObject(session.oauth) }
            #else
            RootView().environmentObject(session).environmentObject(session.oauth)
            #endif
            }
            #else
            RootView().environmentObject(session).environmentObject(session.oauth)
            #endif
            }.appRootAppearance()
        }
    }
}

final class ViewingAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        ViewingOrientationController.shared.supportedOrientations
    }
}

struct RootView: View {
    private struct AuthorRefreshKey: Equatable { let identity: String; let ids: [Int] }
    @EnvironmentObject private var session: SiteSession
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var offline = OfflineLibrary.shared
    @ObservedObject private var tagLibrary = LocalTagLibrary.shared
    @ObservedObject private var history = BrowsingHistory.shared
    @ObservedObject private var authorBlocklist = AuthorBlocklist.shared
    @ObservedObject private var orientation = ViewingOrientationController.shared
    @State private var timelineRestartRequest = 0
    @State private var timelineTopRequest = 0
    #if DEBUG
    @State private var selectedTab = ProcessInfo.processInfo.arguments.contains("--qa-history-screen") ? 3 : (ProcessInfo.processInfo.arguments.contains { $0 == "--qa-search-screen" || $0.hasPrefix("--probe-") || $0.hasPrefix("--readback-") } ? 4 : 0)
    #if targetEnvironment(simulator)
    @State private var qaOfflineScreen = ProcessInfo.processInfo.arguments.contains("--qa-offline-screen")
    @State private var qaHistoryScreen = ProcessInfo.processInfo.arguments.contains("--qa-history-screen")
    #endif
    #else
    @State private var selectedTab = 0
    #endif
    private var authorRefreshKey: AuthorRefreshKey {
        .init(identity: session.feedIdentity, ids: authorBlocklist.blockedIDs.sorted())
    }
    private var offlineAccount: Int? { session.account?.id ?? session.oauth.storedAccountID }
    private var diagnostics: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("--probe-") || $0.hasPrefix("--readback-") || $0 == "--qa-history-screen" }
        #else
        return false
        #endif
    }
    private var tagSyncContext: String { "\(session.tagLibraryIdentity):\(scenePhase == .active)" }
    private func refreshBlockedAuthorNames() async {
        guard session.account != nil else { return }
        let identity = session.feedIdentity
        let ids = authorBlocklist.blockedIDs.sorted()
        guard !ids.isEmpty else { return }
        for start in stride(from: 0, to: ids.count, by: 30) {
            do {
                try Task.checkCancellation()
                let batch = Array(ids[start..<min(start + 30, ids.count)])
                let creators = try await session.creators(ids: batch)
                guard !Task.isCancelled, identity == session.feedIdentity, session.account != nil else { return }
                let requested = Set(batch)
                authorBlocklist.refreshKnownCreators(creators.filter { requested.contains($0.id) })
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }
    var body: some View {
        MainTabs(selectedTab: $selectedTab,
                 onTimelineTap: { selectedTab = 0; timelineTopRequest &+= 1 },
                 onTimelineDoubleTap: { selectedTab = 0; timelineRestartRequest &+= 1 },
                 timeline: TimelineView(isVisible: selectedTab == 0, restartRequest: timelineRestartRequest, topRequest: timelineTopRequest),
                 authors: LeaderboardView(), search: SearchView(), settings: SettingsView())
        #if DEBUG && targetEnvironment(simulator)
        .fullScreenCover(isPresented: $qaOfflineScreen) {
            NavigationStack { OfflineStorageView() }.ordinaryAppearance()
        }
        .fullScreenCover(isPresented: $qaHistoryScreen) {
            NavigationStack { BrowsingHistoryView() }.ordinaryAppearance()
        }
        #endif
        .task {
            await LocalDiagnosticsStore.shared.record(area: .lifecycle, code: .appStarted)
            await session.refreshAccount()
            #if DEBUG
            await AppReadback.runIfRequested(session: session)
            #endif
        }
        .task(id: session.tagLibraryIdentity) {
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--qa-history-screen") { await HistoryQA.seed(session: session) }
            #endif
            await history.bind(ownerID: session.tagLibraryOwnerID, identity: session.tagLibraryIdentity)
        }
        .task(id: authorRefreshKey) { await refreshBlockedAuthorNames() }
        .task(id: tagSyncContext) {
            await tagLibrary.bind(ownerID: session.tagLibraryOwnerID)
            tagLibrary.setActive(scenePhase == .active)
            guard scenePhase == .active else { return }
            #if DEBUG
            let diagnostics = ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("--probe-") || $0.hasPrefix("--readback-") }
            if diagnostics || self.diagnostics { return }
            #endif
            while !Task.isCancelled {
                tagLibrary.requestSync(source: session)
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
        .task(id: offlineAccount) {
            offline.setActive(scenePhase == .active && !diagnostics)
            offline.bind(accountID: offlineAccount, session: session)
            offline.setActive(scenePhase == .active && !diagnostics)
        }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
                if scenePhase == .active && !diagnostics { offline.requestSync(session: session) }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            offline.setActive(phase == .active && !diagnostics); tagLibrary.setActive(phase == .active)
            if phase == .active { orientation.refreshSupportedOrientations() }
            if phase == .active || phase == .background {
                Task { await LocalDiagnosticsStore.shared.record(area: .lifecycle, code: phase == .active ? .foreground : .background) }
            }
        }
        .onChange(of: orientation.message) { _, message in
            if let message { session.message = message; Task { await LocalDiagnosticsStore.shared.record(area: .restore, code: .contextChanged) } }
        }
        .onChange(of: session.collectionRevision) { _, _ in offline.requestSync(session: session) }
        .onChange(of: session.savedMembershipUpdate) { _, update in
            if let update { offline.accept(update); offline.requestSync(session: session) }
        }
        .sheet(isPresented: $session.showLogin, onDismiss: { session.oauth.cancel() }) {
            LoginView().environmentObject(session)
        }
        .alert("Civit Viewer", isPresented: Binding(get: { session.message != nil }, set: { if !$0 { session.message = nil } })) {
            Button("好") { session.message = nil }
        } message: { Text(session.message ?? "") }
    }
}

struct SiteBrowser: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct LoginView: View {
    var forCollections = false
    var onClose: (() -> Void)? = nil
    @EnvironmentObject private var session: SiteSession
    @EnvironmentObject private var oauth: OAuthLogin
    private var collectionLogin: Bool { forCollections || session.loginForCollections }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(collectionLogin ? "启用账号收藏" : "登录 Civitai", systemImage: collectionLogin ? "bookmark" : "person.crop.circle").font(.title2.bold())
                    Text("在系统浏览器窗口选择 Google，完成 Civitai 官方授权后会自动返回。").font(.subheadline)
                    if collectionLogin { Text("新增读取收藏夹与管理收藏权限，用于保存、移除和查看作品。原有浏览与关注权限保留。").font(.subheadline) }
                    Button { Task { await oauth.start(includeCollections: collectionLogin) } } label: {
                        HStack { if oauth.busy { ProgressView() }; Text(oauth.busy ? "正在等待授权…" : (collectionLogin ? "继续前往 Civitai 授权" : "使用 Google 登录 Civitai")) }
                    }.disabled(oauth.busy)
                    if let error = oauth.error { Text(error).font(.caption).foregroundStyle(.red) }
                }
                Section {
                    Text("Google 密码和验证码只在官方页面输入。客户端接收 Civitai 授权，登录凭据保存在本机 Keychain。").font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle("账号登录").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { if let onClose { onClose() } else { session.showLogin = false } } } }
                .fullScreenCover(item: $oauth.browserPage) { page in
                    SystemAuthBrowser(url: page.url) { oauth.cancel() }.ignoresSafeArea()
                }
        }.ordinaryAppearance()
    }
}

struct FollowButton: View {
    let creator: Creator
    var mediaItemID: Int? = nil
    @EnvironmentObject private var session: SiteSession
    private var following: Bool { session.following.contains(creator.id) }
    @ViewBuilder var body: some View {
        if let mediaItemID {
            button.buttonStyle(MediaActionButtonStyle(prominent: true, following: following, qaKey: "control.\(mediaItemID).follow"))
                .accessibilityLabel(session.unknownUsers.contains(creator.id) ? "关注结果待确认" : (following ? "已关注" : "关注"))
        } else {
            button.font(.caption.weight(.semibold)).buttonStyle(AppActionButtonStyle(tone: following ? .neutral : .accent))
        }
    }
    private var button: some View {
        Button {
            if session.account == nil { session.openLogin() }
            else { Task { await session.setFollowing(!following, creator: creator) } }
        } label: {
            if let mediaItemID {
                MediaActionLabel(title: session.unknownUsers.contains(creator.id) ? "待确认" : (following ? "已关注" : "关注"),
                                 symbol: session.unknownUsers.contains(creator.id) ? "arrow.clockwise" : (following ? "checkmark" : "plus"),
                                 busy: session.pendingUsers.contains(creator.id), qaKey: "control.\(mediaItemID).follow")
            }
            else if session.pendingUsers.contains(creator.id) { ProgressView().controlSize(.small) }
            else if session.unknownUsers.contains(creator.id) { Label("待确认", systemImage: "arrow.clockwise") }
            else { Text(following ? "已关注" : "＋ 关注") }
        }
        .disabled(!session.pendingUsers.isEmpty || session.account?.id == creator.id)
        .accessibilityIdentifier("follow-\(creator.id)")
    }
}

struct FailureView: View {
    let message: String
    let retry: () -> Void
    var body: some View {
        ContentUnavailableView {
            Label("暂时无法加载", systemImage: "wifi.exclamationmark")
        } description: { Text(message) } actions: { Button("重试", action: retry).buttonStyle(AppActionButtonStyle()) }
    }
}
