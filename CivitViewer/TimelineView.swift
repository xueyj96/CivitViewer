import SwiftUI

enum TimelinePresentation: String { case stream, grid }

struct TimelineView: View {
    var isVisible = true
    var restartRequest = 0
    var topRequest = 0
    @State private var following = false
    @ObservedObject private var chrome = ViewingChromeController.shared
    @State private var recommendationRestart = 0
    @State private var followingRestart = 0
    @State private var recommendationTop = 0
    @State private var followingTop = 0
    @AppStorage("timeline.presentation") private var presentation = TimelinePresentation.stream.rawValue
    private var layout: TimelinePresentation { TimelinePresentation(rawValue: presentation) ?? .stream }
    private var floatingHeader: Bool { isVisible && layout == .stream && chrome.hasViewer }
    #if DEBUG && targetEnvironment(simulator)
    private var qaController: ResumePromptQAController?
    init(isVisible: Bool = true, restartRequest: Int = 0, topRequest: Int = 0, qaController: ResumePromptQAController? = nil) {
        self.isVisible = isVisible; self.restartRequest = restartRequest; self.topRequest = topRequest; self.qaController = qaController
    }
    #else
    init(isVisible: Bool = true, restartRequest: Int = 0, topRequest: Int = 0) { self.isVisible = isVisible; self.restartRequest = restartRequest; self.topRequest = topRequest }
    #endif
    var body: some View {
        ZStack(alignment: .top) {
            lane(followed: false, request: recommendationRestart)
                .opacity(following ? 0 : 1).allowsHitTesting(!following).accessibilityHidden(following)
            lane(followed: true, request: followingRestart)
                .opacity(following ? 1 : 0).allowsHitTesting(following).accessibilityHidden(!following)
            HStack(spacing: 0) {
                HStack(spacing: 0) {
                    NavigationLink { BrowsingHistoryView() } label: { Image(systemName: "clock.arrow.circlepath").frame(width: 44, height: 44) }
                        .accessibilityLabel("最近浏览")
                    headerSpacer
                }.frame(width: 88)
                HStack(spacing: 12) {
                    sourceButton("关注", selected: following) { following = true }.accessibilityIdentifier("timeline.source.following")
                    sourceButton("推荐", selected: !following) { following = false }.accessibilityIdentifier("timeline.source.recommendation")
                }.frame(maxWidth: .infinity)
                HStack(spacing: 0) {
                    if following {
                        NavigationLink { FollowingView() } label: { Image(systemName: "person.2").frame(width: 44, height: 44) }
                            .accessibilityLabel("关注的作者")
                    } else { headerSpacer }
                    Button {
                        presentation = (layout == .stream ? TimelinePresentation.grid : .stream).rawValue
                    } label: {
                        Image(systemName: layout == .stream ? "square.grid.2x2" : "rectangle.portrait.on.rectangle.portrait")
                            .frame(width: 44, height: 44)
                    }.accessibilityLabel(layout == .stream ? "切换双列网格" : "切换信息流")
                        .accessibilityIdentifier("timeline.presentation")
                        .accessibilityValue(layout == .stream ? "信息流" : "双列网格")
                }.frame(width: 88)
            }.font(.body).padding(.horizontal, 8).foregroundStyle(floatingHeader ? Color.white : Color.primary).frame(height: 44)
                .shadow(color: .black.opacity(floatingHeader ? 0.55 : 0), radius: 2, y: 1)
                .background(floatingHeader ? Color.clear : Color(uiColor: .systemBackground))
                .viewingChromeHidden(chrome.hidden)
        }.background(Color(uiColor: .systemBackground).ignoresSafeArea()).toolbar(.hidden, for: .navigationBar)
            .onChange(of: restartRequest) { _, _ in
                if following { followingRestart += 1 } else { recommendationRestart += 1 }
            }
            .onChange(of: topRequest) { _, _ in
                if following { followingTop += 1 } else { recommendationTop += 1 }
            }
    }
    private var headerSpacer: some View {
        Color.clear.frame(width: 44, height: 44).allowsHitTesting(false).accessibilityHidden(true)
    }
    @ViewBuilder private func lane(followed: Bool, request: Int) -> some View {
        #if DEBUG && targetEnvironment(simulator)
        TimelineLane(isVisible: isVisible && following == followed, followed: followed, presentation: layout, restartRequest: request, topRequest: followed ? followingTop : recommendationTop,
                     qaController: qaController?.controller(for: followed))
        #else
        TimelineLane(isVisible: isVisible && following == followed, followed: followed, presentation: layout, restartRequest: request, topRequest: followed ? followingTop : recommendationTop)
        #endif
    }
    private func sourceButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Text(title).font(.headline).lineLimit(1).minimumScaleFactor(0.8)
                    .foregroundStyle(floatingHeader ? Color.white.opacity(selected ? 1 : 0.65) : (selected ? Color.primary : Color.secondary))
                Capsule().fill(selected ? Color.accentColor : .clear).frame(width: 18, height: 3)
            }.padding(.top, 6).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }
    }
}

