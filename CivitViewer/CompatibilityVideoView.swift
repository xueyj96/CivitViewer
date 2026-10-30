import SwiftUI
import WebKit
import UIKit

struct CompatibilityVideoView: View {
    let url: URL
    var initialPosition: Double? = nil
    let onProgress: (Double, Double, Bool) -> Void
    let onPlaying: () -> Void
    let onFailure: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var controller: CompatibilityVideoController

    init(
        url: URL,
        initialPosition: Double? = nil,
        onProgress: @escaping (Double, Double, Bool) -> Void,
        onPlaying: @escaping () -> Void,
        onFailure: @escaping (Int) -> Void
    ) {
        self.url = url
        self.initialPosition = initialPosition
        self.onProgress = onProgress
        self.onPlaying = onPlaying
        self.onFailure = onFailure
        _controller = StateObject(wrappedValue: CompatibilityVideoController(
            url: url,
            initialPosition: initialPosition,
            onProgress: onProgress,
            onPlaying: onPlaying,
            onFailure: onFailure
        ))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CompatibilityWebView(controller: controller)
                .ignoresSafeArea(edges: .bottom)
            VideoWaitingIndicator(visible: controller.isLoading && controller.errorCode == nil && scenePhase == .active)
            VStack(spacing: 0) {
                HStack {
                    Text("兼容播放")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Spacer()
                    Button("关闭") {
                        controller.close()
                        dismiss()
                    }
                    .accessibilityIdentifier("compatibility.close")
                    .foregroundStyle(.white)
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 12)
                .background(.black.opacity(0.78))
                Spacer()
                if let error = controller.errorCode {
                    Text("兼容播放暂不可用（错误\(error)）")
                        .font(.callout)
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(.black.opacity(0.78), in: Capsule())
                        .padding(.bottom, 24)
                }
            }
            #if DEBUG && targetEnvironment(simulator)
            CompatibilityQAValue(controller: controller)
            #endif
        }
        .preferredColorScheme(.dark)
        .onChange(of: scenePhase) { _, phase in if phase != .active { controller.pauseAndFlush() } }
        .onDisappear { controller.destroy() }
    }
}

@MainActor
private final class CompatibilityVideoController: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    @Published private(set) var isLoading = true
    @Published private(set) var errorCode: Int?
    #if DEBUG && targetEnvironment(simulator)
    @Published private(set) var qaState = "{}"
    #endif

    private let url: URL
    private let initialPosition: Double?
    private let onProgress: (Double, Double, Bool) -> Void
    private let onPlaying: () -> Void
    private let onFailure: (Int) -> Void
    private weak var webView: WKWebView?
    private var temporaryDirectory: URL?
    private var latestProgress: (Double, Double)?
    private var lastProgressCallback = 0.0
    private var didReportPlaying = false
    private var didReportFailure = false
    private var didClose = false
    private var didDestroy = false
    private var hasLoadedDocument = false
    private var permittedDocumentURL: URL?
    private static var cleanedOrphans = false
    private static let ownershipMarker = "com.xueyj.civitviewer.compatibility.v1"

    init(url: URL, initialPosition: Double?, onProgress: @escaping (Double, Double, Bool) -> Void,
         onPlaying: @escaping () -> Void, onFailure: @escaping (Int) -> Void) {
        self.url = url
        self.initialPosition = initialPosition
        self.onProgress = onProgress
        self.onPlaying = onPlaying
        self.onFailure = onFailure
        super.init()
    }

    func attach(_ webView: WKWebView) {
        guard !didDestroy else { return }
        self.webView = webView
        webView.navigationDelegate = self
        webView.uiDelegate = self
        do {
            let source = try prepareDocument()
            switch source {
            case .remote(let sourceURL):
                permittedDocumentURL = URL(string: "about:blank")
                webView.loadHTMLString(Self.html, baseURL: nil)
                pendingRemoteURL = sourceURL
            case .local:
                guard let temporaryDirectory else { throw SetupError.localFileUnavailable }
                let documentURL = temporaryDirectory.appendingPathComponent("index.html")
                permittedDocumentURL = documentURL
                webView.loadFileURL(documentURL, allowingReadAccessTo: temporaryDirectory)
            }
        } catch {
            fail(LocalFailureCode.setup.rawValue)
        }
    }

    private enum Source {
        case remote(String)
        case local
    }

    private enum LocalFailureCode: Int {
        case setup = -1
        case navigation = -2
    }

    private enum SetupError: Error {
        case unsupportedScheme
        case localFileUnavailable
        case temporaryDirectoryUnavailable
        case hardLinkFailed
        case htmlWriteFailed
    }

    private var pendingRemoteURL: String?

    private func prepareDocument() throws -> Source {
        switch url.scheme?.lowercased() {
        case "https":
            guard url.host != nil, url.user == nil, url.password == nil else { throw SetupError.unsupportedScheme }
            return .remote(url.absoluteString)
        case "file":
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                throw SetupError.localFileUnavailable
            }
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("CivitCompatibility-\(UUID().uuidString)", isDirectory: true)
            do {
                Self.cleanupOwnedOrphans()
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
                temporaryDirectory = dir
                try Data(Self.ownershipMarker.utf8).write(to: dir.appendingPathComponent("owner"), options: .atomic)
                try Self.html.data(using: .utf8)!.write(to: dir.appendingPathComponent("index.html"), options: .atomic)
                try FileManager.default.linkItem(at: url, to: dir.appendingPathComponent("media"))
            } catch {
                removeTemporaryDirectory()
                throw SetupError.hardLinkFailed
            }
            return .local
        default:
            throw SetupError.unsupportedScheme
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !didDestroy, !didClose, message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any],
              let kind = body["kind"] as? String,
              ["progress", "playing", "failure"].contains(kind) else { return }

        switch kind {
        case "progress":
            guard Set(body.keys) == Set(["kind", "position", "duration", "readyState", "muted", "paused", "controls"]),
                  let position = Self.finiteNumber(body["position"]), position >= 0,
                  let duration = Self.finiteNumber(body["duration"]), duration >= 0,
                  let readyState = Self.integer(body["readyState"]), (0...4).contains(readyState),
                  let muted = body["muted"] as? Bool,
                  let paused = body["paused"] as? Bool,
                  let controls = body["controls"] as? Bool else { return }
            latestProgress = (position, duration)
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastProgressCallback >= 0.25 {
                lastProgressCallback = now
                onProgress(position, duration, false)
            }
            isLoading = readyState < 2 && errorCode == nil
            updateQA(position: position, duration: duration, muted: muted, ready: readyState >= 2,
                     playing: !paused, error: errorCode ?? 0, controls: controls)
        case "playing":
            guard Set(body.keys) == Set(["kind", "position", "duration", "readyState", "hasFrame"]),
                  let position = Self.finiteNumber(body["position"]), position > 0,
                  let duration = Self.finiteNumber(body["duration"]), duration >= 0,
                  let readyState = Self.integer(body["readyState"]), (2...4).contains(readyState),
                  let hasFrame = body["hasFrame"] as? Bool, hasFrame,
                  !didReportPlaying else { return }
            didReportPlaying = true
            onPlaying()
        case "failure":
            guard Set(body.keys) == Set(["kind", "code"]), let code = Self.integer(body["code"]), (1...4).contains(code) else { return }
            fail(code)
        default:
            return
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !didDestroy else { return }
        hasLoadedDocument = true
        if let source = pendingRemoteURL {
            pendingRemoteURL = nil
            let position = initialPosition.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? 0
            webView.callAsyncJavaScript("startPlayback(source, startAt)", arguments: ["source": source, "startAt": position], in: nil, in: .page) { [weak self] result in
                if case .failure = result { self?.fail(LocalFailureCode.navigation.rawValue) }
            }
        } else {
            let position = initialPosition.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? 0
            webView.callAsyncJavaScript("startPlayback('media', startAt)", arguments: ["startAt": position], in: nil, in: .page) { [weak self] result in
                if case .failure = result { self?.fail(LocalFailureCode.navigation.rawValue) }
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { if hasLoadedDocument == false { fail(LocalFailureCode.navigation.rawValue) } }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(LocalFailureCode.navigation.rawValue) }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Permit only the one local/blank HTML document. Page links and other destinations are denied.
        if let target = navigationAction.request.url, target == permittedDocumentURL, !hasLoadedDocument {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }

    func close() {
        guard !didClose else { return }
        didClose = true
        if let (position, duration) = latestProgress { onProgress(position, duration, true) }
        teardownWebView()
    }

    func pauseAndFlush() {
        guard !didClose, !didDestroy else { return }
        webView?.evaluateJavaScript("document.querySelector('video')?.pause()")
        if let (position, duration) = latestProgress { onProgress(position, duration, true) }
    }

    func destroy() {
        guard !didDestroy else { return }
        close()
        didDestroy = true
        teardownWebView()
        removeTemporaryDirectory()
    }

    private func fail(_ code: Int) {
        guard !didReportFailure, !didClose, !didDestroy else { return }
        didReportFailure = true
        errorCode = code
        isLoading = false
        #if DEBUG && targetEnvironment(simulator)
        updateQA(position: latestProgress?.0 ?? 0, duration: latestProgress?.1 ?? 0,
                 muted: true, ready: false, playing: false, error: code, controls: true)
        #endif
        onFailure(code)
    }

    private func teardownWebView() {
        guard let webView else { return }
        webView.evaluateJavaScript("document.querySelectorAll('video').forEach(v => { v.pause(); v.removeAttribute('src'); v.load(); });")
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "compatibility")
        self.webView = nil
    }

    private func removeTemporaryDirectory() {
        guard let dir = temporaryDirectory else { return }
        temporaryDirectory = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private static func cleanupOwnedOrphans() {
        guard !cleanedOrphans else { return }
        cleanedOrphans = true
        let root = FileManager.default.temporaryDirectory
        guard let children = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return }
        for dir in children {
            let name = dir.lastPathComponent
            let markerURL = dir.appendingPathComponent("owner")
            guard name.hasPrefix("CivitCompatibility-"), UUID(uuidString: String(name.dropFirst("CivitCompatibility-".count))) != nil,
                  let values = try? dir.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: markerURL.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.size] as? NSNumber)?.intValue == ownershipMarker.utf8.count,
                  let marker = try? Data(contentsOf: markerURL), marker == Data(ownershipMarker.utf8) else { continue }
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private static func finiteNumber(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = finiteNumber(value), number.rounded(.towardZero) == number,
              number >= Double(Int.min), number < Double(Int.max) else { return nil }
        return Int(number)
    }

    private func updateQA(position: Double, duration: Double, muted: Bool, ready: Bool, playing: Bool, error: Int, controls: Bool) {
        #if DEBUG && targetEnvironment(simulator)
        let value: [String: Any] = ["position": position, "duration": duration, "muted": muted,
                                    "ready": ready, "playing": playing, "error": error, "controls": controls]
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let string = String(data: data, encoding: .utf8) { qaState = string }
        #endif
    }

    private static let html = #"""
    <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no"><style>html,body{margin:0;width:100%;height:100%;background:#000;overflow:hidden}video{width:100%;height:100%;object-fit:contain;background:#000}</style></head><body><video id="player" controls playsinline muted autoplay></video><script>
    (()=>{const v=document.getElementById('player');let sentPlaying=false,hadFrame=false,baseTime=0;v.muted=true;v.playsInline=true;v.controls=true;v.autoplay=true;
    const send=(x)=>{try{window.webkit.messageHandlers.compatibility.postMessage(x)}catch(_){}};
    const sample=()=>{const t=Number(v.currentTime),d=Number(v.duration);if(!Number.isFinite(t)||t<0||!Number.isFinite(d)||d<0)return;
      send({kind:'progress',position:t,duration:d,readyState:v.readyState,muted:v.muted,paused:v.paused,controls:v.controls});
      if(!sentPlaying&&t>baseTime+0.05&&v.videoWidth>0&&v.videoHeight>0&&v.readyState>=2&&(hadFrame||v.readyState>=3)){sentPlaying=true;send({kind:'playing',position:t,duration:d,readyState:v.readyState,hasFrame:true})}}
    window.startPlayback=(source,startAt)=>{if(typeof source!=='string'||typeof startAt!=='number'||!Number.isFinite(startAt)||startAt<0)return;
      baseTime=0;v.muted=true;v.addEventListener('loadedmetadata',()=>{if(startAt>0&&Number.isFinite(v.duration)&&v.duration>0){try{baseTime=Math.min(startAt,Math.max(0,v.duration-0.25));v.currentTime=baseTime}catch(_){}}},{once:true});v.src=source;v.load();
      v.play().catch(()=>{});setInterval(sample,250);if(v.requestVideoFrameCallback){const frame=()=>{hadFrame=true;sample();if(!v.paused)v.requestVideoFrameCallback(frame)};v.requestVideoFrameCallback(frame)}};
    v.addEventListener('error',()=>{const c=v.error&&v.error.code;if(Number.isInteger(c)&&c>=1&&c<=4)send({kind:'failure',code:c})});})();
    </script></body></html>
    """#
}

private struct CompatibilityWebView: UIViewRepresentable {
    let controller: CompatibilityVideoController
    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(controller, contentWorld: .page, name: "compatibility")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        controller.attach(webView)
        return webView
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.controller.destroy()
    }
    final class Coordinator {
        let controller: CompatibilityVideoController
        init(controller: CompatibilityVideoController) { self.controller = controller }
    }
}

#if DEBUG && targetEnvironment(simulator)
private struct CompatibilityQAValue: View {
    @ObservedObject var controller: CompatibilityVideoController
    var body: some View {
        Text("").frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false)
            .accessibilityElement().accessibilityLabel("Compatibility playback state")
            .accessibilityIdentifier("compatibility.qa.state").accessibilityValue(controller.qaState)
    }
}
#endif
