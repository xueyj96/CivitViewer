import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@MainActor final class BoundaryGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var opened = false
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}

struct BoundaryPayload: Decodable, Equatable { let value: Int }
struct BoundaryContentWorld { static let page = BoundaryContentWorld() }

@MainActor final class BoundaryOAuth {
    var hasCredentials = true
    var calls = 0
    var authorized: (URLRequest) async throws -> (Data, HTTPURLResponse) = { _ in
        (Data(#"{"value":1}"#.utf8), HTTPURLResponse(url: URL(string: "https://example.invalid")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func authorizedData(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        calls += 1
        return try await authorized(request)
    }
}

@MainActor final class BoundaryWebView {
    var url: URL? = URL(string: "https://civitai.red/")
    var isLoading = false
    var loads = 0
    var javascriptCalls = 0
    var onLoad: (URLRequest) -> Void = { _ in }
    var javascript: (String, [String: Any]) async throws -> Any = { _, _ in
        #"{"ok":true,"payload":{"value":1}}"#
    }
    let javascriptStarted = BoundaryGate()

    func load(_ request: URLRequest) { loads += 1; onLoad(request) }
    func callAsyncJavaScript(_ script: String, arguments: [String: Any], in frame: Any?,
                             contentWorld: BoundaryContentWorld) async throws -> Any {
        javascriptCalls += 1
        javascriptStarted.open()
        return try await javascript(script, arguments)
    }
}

@MainActor final class SessionBoundaryHarness {
    static let origin = "https://example.invalid"
    var account: Account? = Account(id: 42, username: "fixture", browsingLevel: 1, blurNsfw: true)
    var authGeneration = 7
    var showLogin = false
    var loadingDocument = false
    let oauth = BoundaryOAuth()
    let webView = BoundaryWebView()

    // verify-session-boundary.py inserts the production members at these markers.
    // INSERT_EXTRACTED_FEED_IDENTITY
    // INSERT_EXTRACTED_ENSURE_ORIGIN
    // INSERT_EXTRACTED_REQUEST
    // INSERT_EXTRACTED_DECODE
}

@main struct SessionBoundaryChecks {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, message); checks += 1
        }
        func response(_ status: Int = 200) -> HTTPURLResponse {
            HTTPURLResponse(url: URL(string: "https://example.invalid/api/fixture")!, statusCode: status,
                            httpVersion: nil, headerFields: nil)!
        }
        func payload(_ value: Int = 1) -> Data { Data(#"{"value":\#(value)}"#.utf8) }

        // Old OAuth success cannot cross an epoch change when account and mask are unchanged.
        let oauthSuccess = SessionBoundaryHarness(), oauthSuccessGate = BoundaryGate()
        let originalAccount = oauthSuccess.account, originalIdentity = oauthSuccess.feedIdentity
        oauthSuccess.oauth.authorized = { _ in await oauthSuccessGate.wait(); return (payload(), response()) }
        let oldSuccess = Task { try await oauthSuccess.request(path: "/api/fixture") as BoundaryPayload }
        while oauthSuccess.oauth.calls == 0 { await Task.yield() }
        oauthSuccess.authGeneration += 1
        check(oauthSuccess.account == originalAccount && oauthSuccess.feedIdentity != originalIdentity,
              "Epoch change changes identity while preserving account and browsing mask")
        oauthSuccessGate.open()
        do { _ = try await oldSuccess.value; check(false, "Old OAuth success must be cancelled") }
        catch is CancellationError { check(true, "Old OAuth success is cancelled after epoch change") }

        // The same boundary also takes precedence over an old transport error.
        let oauthFailure = SessionBoundaryHarness(), oauthFailureGate = BoundaryGate()
        oauthFailure.oauth.authorized = { _ in await oauthFailureGate.wait(); throw URLError(.timedOut) }
        let oldFailure = Task { try await oauthFailure.request(path: "/api/fixture") as BoundaryPayload }
        while oauthFailure.oauth.calls == 0 { await Task.yield() }
        oauthFailure.authGeneration += 1; oauthFailureGate.open()
        do { _ = try await oldFailure.value; check(false, "Old OAuth failure must be cancelled") }
        catch is CancellationError { check(true, "Epoch invalidation takes precedence over old OAuth transport error") }

        // A same-account request in a new epoch may complete, and ordinary token rotation leaves epoch intact.
        let newEpoch = SessionBoundaryHarness(), identityBefore = newEpoch.feedIdentity
        newEpoch.authGeneration += 1
        let newIdentity = newEpoch.feedIdentity
        let newEpochResult: BoundaryPayload = try await newEpoch.request(path: "/api/fixture")
        check(identityBefore != newIdentity && newEpochResult == BoundaryPayload(value: 1),
              "Same-account new-epoch identity can make a fresh request")
        let tokenRefresh = SessionBoundaryHarness(), tokenIdentity = tokenRefresh.feedIdentity
        tokenRefresh.oauth.authorized = { _ in (payload(2), response()) }
        let tokenResult: BoundaryPayload = try await tokenRefresh.request(path: "/api/fixture")
        check(tokenRefresh.feedIdentity == tokenIdentity && tokenResult == BoundaryPayload(value: 2),
              "Token refresh without epoch change remains a normal successful request")

        // A cancelled entry is rejected before either transport can begin.
        let cancelledEntry = SessionBoundaryHarness()
        let cancelledTask = Task {
            await Task.yield()
            return try await cancelledEntry.request(path: "/api/fixture") as BoundaryPayload
        }
        cancelledTask.cancel()
        do { _ = try await cancelledTask.value; check(false, "Cancelled request entry must throw") }
        catch is CancellationError { check(cancelledEntry.oauth.calls == 0 && cancelledEntry.webView.javascriptCalls == 0,
                                            "Cancelled entry starts no OAuth or WebKit transport") }

        // WebKit success and failure after a suspended JavaScript call are both fenced.
        for shouldThrow in [false, true] {
            let web = SessionBoundaryHarness(), javascriptGate = BoundaryGate()
            web.oauth.hasCredentials = false
            web.webView.javascript = { _, _ in
                await javascriptGate.wait()
                if shouldThrow { throw URLError(.timedOut) }
                return #"{"ok":true,"payload":{"value":3}}"#
            }
            let call = Task { try await web.request(path: "/api/fixture") as BoundaryPayload }
            await web.webView.javascriptStarted.wait()
            web.authGeneration += 1; javascriptGate.open()
            do { _ = try await call.value; check(false, "WebKit result after epoch change must be cancelled") }
            catch is CancellationError { check(web.webView.javascriptCalls == 1,
                                                "WebKit success/error after epoch change is cancelled") }
        }

        // ensureOrigin success after navigation is fenced before JavaScript starts.
        let originSuccess = SessionBoundaryHarness(), originLoad = BoundaryGate()
        originSuccess.oauth.hasCredentials = false
        originSuccess.webView.url = URL(string: "https://example.invalid/")
        originSuccess.webView.onLoad = { _ in
            originLoad.open()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(5))
                originSuccess.webView.url = URL(string: "https://civitai.red/")
            }
        }
        let originSuccessTask = Task { try await originSuccess.request(path: "/api/fixture") as BoundaryPayload }
        await originLoad.wait(); originSuccess.authGeneration += 1
        do { _ = try await originSuccessTask.value; check(false, "ensureOrigin success after epoch change must be cancelled") }
        catch is CancellationError { check(originSuccess.webView.loads == 1 && originSuccess.webView.javascriptCalls == 0,
                                            "ensureOrigin success is followed by an epoch check before WebKit request") }

        // ensureOrigin exhaustion is also followed by the request epoch check.
        let originFailure = SessionBoundaryHarness(), failedLoad = BoundaryGate()
        originFailure.oauth.hasCredentials = false
        originFailure.webView.url = URL(string: "https://example.invalid/")
        originFailure.webView.onLoad = { _ in failedLoad.open() }
        let originFailureTask = Task { try await originFailure.request(path: "/api/fixture") as BoundaryPayload }
        await failedLoad.wait(); originFailure.authGeneration += 1
        do { _ = try await originFailureTask.value; check(false, "ensureOrigin failure after epoch change must be cancelled") }
        catch is CancellationError { check(originFailure.webView.loads == 1 && originFailure.webView.javascriptCalls == 0,
                                            "ensureOrigin failure is replaced by cancellation for a stale epoch") }

        // Current-epoch HTTP/JSON failures keep their existing error scope.
        let http = SessionBoundaryHarness()
        http.oauth.authorized = { _ in (payload(), response(429)) }
        do { let _: BoundaryPayload = try await http.request(path: "/api/fixture"); check(false, "HTTP failure expected") }
        catch ClientError.http(let status) { check(status == 429, "Current-epoch HTTP status remains ClientError.http") }
        let json = SessionBoundaryHarness()
        json.oauth.authorized = { _ in (Data("not-json".utf8), response()) }
        do { let _: BoundaryPayload = try await json.request(path: "/api/fixture"); check(false, "JSON failure expected") }
        catch is ClientError { check(false, "Raw JSON parser error is not rewritten as ClientError") }
        catch { check(true, "Current-epoch malformed JSON preserves the parser error") }
        let webHTTP = SessionBoundaryHarness()
        webHTTP.oauth.hasCredentials = false
        webHTTP.webView.javascript = { _, _ in #"{"ok":false,"status":429}"# }
        do { let _: BoundaryPayload = try await webHTTP.request(path: "/api/fixture"); check(false, "WebKit HTTP failure expected") }
        catch ClientError.http(let status) { check(status == 429, "WebKit HTTP status retains ClientError.http mapping") }

        print("SessionBoundaryChecks: \(checks) regression checks passed")
    }
}
