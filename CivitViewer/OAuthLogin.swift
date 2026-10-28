import Foundation
import Combine
import CryptoKit
import Security
import Network
import SafariServices
import SwiftUI

/// Public client registration contains no secret. Google sign-in stays inside
/// Apple's browser controller; this app receives only Civitai's PKCE result.
@MainActor
final class OAuthLogin: ObservableObject {
    static let clientID = "ab4e6b12-ab1d-4e14-a6b5-189f87150920"
    static let scopes = 524323 // UserRead | UserWrite | MediaRead | SocialWrite
    static let collectionScopes = 131072 | 262144 // CollectionsRead | CollectionsWrite
    @Published var browserPage: AuthBrowserPage?
    @Published private(set) var busy = false
    @Published var error: String?
    var onAuthenticated: (() async -> Void)?
    private var tokens = TokenVault.read()
    private var listener: LoopbackCallback?
    private var verifier: String?
    private var expectedState: String?
    private var redirectURI: String?
    private var refreshTask: Task<OAuthTokens, Error>?
    private var credentialGeneration = 0
    private var timeoutTask: Task<Void, Never>?
    private var requestedScopes = OAuthLogin.scopes
    private var attemptID = UUID()
    private let transport = URLSession(configuration: {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil; c.httpShouldSetCookies = false
        c.timeoutIntervalForRequest = 30; c.timeoutIntervalForResource = 40
        return c
    }(), delegate: SameHostRedirects(), delegateQueue: nil)

    var hasCredentials: Bool { tokens?.clientID == Self.clientID }
    var hasCollectionAccess: Bool { hasCredentials && ((tokens?.scope ?? 0) & Self.collectionScopes == Self.collectionScopes) }
    var storedAccountID: Int? { hasCredentials ? tokens?.accountID : nil }

    func bindAccountIdentity(_ id: Int) throws {
        guard var record = tokens, hasCredentials, id > 0, record.accountID != id else { return }
        record.accountID = id
        try TokenVault.save(record); tokens = record
    }

    func start(includeCollections: Bool = false) async {
        guard !busy else { return }
        busy = true; error = nil
        let attempt = UUID(); attemptID = attempt
        requestedScopes = Self.scopes | (includeCollections ? Self.collectionScopes : 0)
        do {
            let verifier = try Self.random()
            let state = try Self.random()
            let callback = LoopbackCallback(state: state) { [weak self] url in
                Task { @MainActor in await self?.complete(url) }
            }
            listener = callback
            let port = try await callback.start()
            guard attemptID == attempt, busy else { callback.stop(); return }
            let redirect = "http://127.0.0.1:\(port)/civitai/callback"
            self.verifier = verifier; expectedState = state; redirectURI = redirect
            let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
            var components = URLComponents(string: "https://auth.civitai.com/api/auth/oauth/authorize")!
            components.queryItems = [
                .init(name: "response_type", value: "code"), .init(name: "client_id", value: Self.clientID),
                .init(name: "redirect_uri", value: redirect), .init(name: "scope", value: String(requestedScopes)),
                .init(name: "state", value: state), .init(name: "code_challenge", value: challenge),
                .init(name: "code_challenge_method", value: "S256")
            ]
            browserPage = AuthBrowserPage(url: components.url!)
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(600))
                guard !Task.isCancelled else { return }
                self?.cancel(); self?.error = "这次登录已超时，请重新开始。"
            }
        } catch {
            guard attemptID == attempt else { return }
            cancel(); self.error = "无法建立本机授权回调，请重新开始登录。"
        }
    }

    func cancel() {
        attemptID = UUID()
        timeoutTask?.cancel(); timeoutTask = nil
        listener?.stop(); listener = nil
        browserPage = nil; verifier = nil; expectedState = nil; redirectURI = nil; busy = false
    }

    private func complete(_ url: URL) async {
        guard let expectedState, let verifier, let redirectURI,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let query = Dictionary(components.queryItems?.map { ($0.name, $0.value ?? "") } ?? [], uniquingKeysWith: { first, _ in first })
        guard query["state"] == expectedState else { return }
        let attempt = attemptID
        listener?.stop(); listener = nil
        guard let code = query["code"], !code.isEmpty else {
            cancel(); error = "授权没有完成，可以重新登录。"; return
        }
        // Neither the authorization code nor its verifier is logged or persisted.
        do {
            let record = try await exchange(["grant_type": "authorization_code", "code": code,
                                             "code_verifier": verifier, "redirect_uri": redirectURI,
                                             "client_id": Self.clientID], requiredScopes: requestedScopes)
            // Cancelling an upgrade must leave the existing session intact;
            // a late token response cannot replace it or a newer login attempt.
            guard attemptID == attempt, busy else { return }
            credentialGeneration += 1
            refreshTask?.cancel(); refreshTask = nil
            try TokenVault.save(record); tokens = record
            cancel()
            await onAuthenticated?()
        } catch {
            guard attemptID == attempt else { return }
            cancel(); self.error = "未能完成 Civitai 授权或保存登录状态，请重新登录。"
        }
    }

    func authorizedData(for original: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard original.url?.scheme == "https", original.url?.host == "civitai.red" else { throw ClientError.invalidResponse }
        var request = original
        request.setValue("Bearer " + (try await accessToken()), forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        // In particular, a mutation is never automatically resent after a 401.
        return (data, response)
    }

    private func accessToken() async throws -> String {
        guard let record = tokens, record.clientID == Self.clientID else { throw ClientError.signedOut }
        let generation = credentialGeneration
        if record.expiresAt.timeIntervalSinceNow > 60 { return record.accessToken }
        if let refreshTask {
            let updated = try await refreshTask.value
            guard generation == credentialGeneration, tokens != nil else { throw ClientError.signedOut }
            return updated.accessToken
        }
        let task = Task { try await exchange(["grant_type": "refresh_token", "refresh_token": record.refreshToken,
                                              "client_id": Self.clientID], requiredScopes: record.scope) }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            var updated = try await task.value
            guard generation == credentialGeneration, tokens != nil else { throw ClientError.signedOut }
            updated.accountID = tokens?.accountID ?? record.accountID
            try TokenVault.save(updated); tokens = updated
            return updated.accessToken
        } catch {
            // Temporary offline/server failures must retain the confirmed local
            // identity, so already downloaded works remain available offline.
            if case ClientError.signedOut = error {
                if generation == credentialGeneration { tokens = nil; TokenVault.clear() }
            }
            throw error
        }
    }

    private func exchange(_ form: [String: String], requiredScopes: Int) async throws -> OAuthTokens {
        var request = URLRequest(url: URL(string: "https://auth.civitai.com/api/auth/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = form.sorted { $0.key < $1.key }.map { .init(name: $0.key, value: $0.value) }
        request.httpBody = body.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        let (data, response) = try await transport.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        if response.statusCode == 400 || response.statusCode == 401 { throw ClientError.signedOut }
        guard response.statusCode == 200 else { throw ClientError.http(response.statusCode) }
        let value = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard value.scope & requiredScopes == requiredScopes, value.expiresIn > 0,
              !value.accessToken.isEmpty, !value.refreshToken.isEmpty else { throw ClientError.signedOut }
        return OAuthTokens(clientID: Self.clientID, accessToken: value.accessToken, refreshToken: value.refreshToken,
                           expiresAt: Date().addingTimeInterval(TimeInterval(value.expiresIn)), scope: value.scope)
    }

    func clear() { credentialGeneration += 1; cancel(); refreshTask?.cancel(); refreshTask = nil; tokens = nil; TokenVault.clear() }
    private static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw ClientError.invalidResponse }
        return base64URL(Data(bytes))
    }
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

struct AuthBrowserPage: Identifiable { let id = UUID(); let url: URL }
struct SystemAuthBrowser: UIViewControllerRepresentable {
    let url: URL
    let onClose: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onClose) }
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url); controller.delegate = context.coordinator
        controller.dismissButtonStyle = .cancel; return controller
    }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        let onClose: () -> Void
        init(_ onClose: @escaping () -> Void) { self.onClose = onClose }
        func safariViewControllerDidFinish(_ controller: SFSafariViewController) { onClose() }
    }
}

private struct OAuthTokens: Codable {
    let clientID: String
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let scope: Int
    var accountID: Int? = nil
}

private struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
    let scope: Int
    enum CodingKeys: String, CodingKey { case accessToken = "access_token", refreshToken = "refresh_token", expiresIn = "expires_in", scope }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try c.decode(String.self, forKey: .accessToken)
        refreshToken = try c.decode(String.self, forKey: .refreshToken)
        expiresIn = try c.decode(Int.self, forKey: .expiresIn)
        if let n = try? c.decode(Int.self, forKey: .scope) { scope = n }
        else if let s = try? c.decode(String.self, forKey: .scope), let n = Int(s) { scope = n }
        else if let a = try? c.decode([String].self, forKey: .scope), a.count == 1, let n = Int(a[0]) { scope = n }
        else { throw ClientError.invalidResponse }
    }
}

private enum TokenVault {
    static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                      kSecAttrService as String: "com.xueyj.civitviewer.oauth",
                                      kSecAttrAccount as String: "tokens"]
    static func read() -> OAuthTokens? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &value) == errSecSuccess, let data = value as? Data else { return nil }
        return try? JSONDecoder().decode(OAuthTokens.self, from: data)
    }
    static func save(_ record: OAuthTokens) throws {
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(record),
                                       kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var q = query; attributes.forEach { q[$0.key] = $0.value }
            guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw ClientError.invalidResponse }
        } else if status != errSecSuccess { throw ClientError.invalidResponse }
    }
    static func clear() { SecItemDelete(query as CFDictionary) }
}

/// Refuse cross-host redirects, including token-endpoint POST redirects.
private final class SameHostRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" && request.url?.host == task.originalRequest?.url?.host ? request : nil)
    }
}

/// An ephemeral callback receiver inside this app, bound ONLY to IPv4 loopback.
/// Civitai's documented loopback redirect matching permits an OS-selected port.
private final class LoopbackCallback: @unchecked Sendable {
    private let state: String
    private let onCallback: @Sendable (URL) -> Void
    private let queue = DispatchQueue(label: "CivitViewer.oauth.callback")
    private var listener: NWListener?
    private var ready: CheckedContinuation<UInt16, Error>?
    private var consumed = false
    private var activeConnections = 0
    private var connections: [NWConnection] = []
    init(state: String, onCallback: @escaping @Sendable (URL) -> Void) { self.state = state; self.onCallback = onCallback }
    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                self.ready = continuation
                listener.stateUpdateHandler = { [weak self] status in
                    guard let self else { return }
                    if case .ready = status, let port = listener.port { self.ready?.resume(returning: port.rawValue); self.ready = nil }
                    if case .failed = status { self.ready?.resume(throwing: ClientError.siteUnavailable); self.ready = nil }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self, self.activeConnections < 4 else { connection.cancel(); return }
                    self.activeConnections += 1; self.connections.append(connection); connection.start(queue: self.queue)
                    self.receive(connection, data: Data())
                }
                listener.start(queue: self.queue)
                self.queue.asyncAfter(deadline: .now() + 15) {
                    if self.ready != nil { self.ready?.resume(throwing: ClientError.siteUnavailable); self.ready = nil; listener.cancel() }
                }
            }
        }
    }
    func stop() {
        queue.async {
            self.ready?.resume(throwing: CancellationError()); self.ready = nil
            self.listener?.newConnectionHandler = nil; self.listener?.stateUpdateHandler = nil
            self.listener?.cancel(); self.listener = nil
            self.connections.forEach { $0.cancel() }; self.connections = []; self.activeConnections = 0
        }
    }
    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] chunk, _, ended, error in
            guard let self else { connection.cancel(); return }
            var buffer = data; if let chunk { buffer.append(chunk) }
            if buffer.count > 16384 || error != nil { self.close(connection); return }
            guard buffer.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if ended { self.close(connection) } else { self.receive(connection, data: buffer) }; return
            }
            let header = String(decoding: buffer, as: UTF8.self)
            let first = header.components(separatedBy: "\r\n").first?.components(separatedBy: " ") ?? []
            guard first.count == 3, first[0] == "GET", first[1].hasPrefix("/civitai/callback?"),
                  let port = self.listener?.port,
                  header.lowercased().contains("\r\nhost: 127.0.0.1:\(port.rawValue)\r\n"),
                  let url = URL(string: "http://127.0.0.1:\(port.rawValue)" + first[1]),
                  let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  parts.queryItems?.filter({ $0.name == "state" }).count == 1,
                  parts.queryItems?.first(where: { $0.name == "state" })?.value == self.state, !self.consumed else {
                self.respond(connection, status: "400 Bad Request", text: "This callback is not valid."); return
            }
            self.consumed = true
            self.respond(connection, status: "200 OK", text: "授权已收到，可以返回 Civit Viewer。") {
                self.onCallback(url)
            }
        }
    }
    private func respond(_ connection: NWConnection, status: String, text: String, finished: (() -> Void)? = nil) {
        let html = Data(("<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width'><title>Civit Viewer</title><p>" + text + "</p>").utf8)
        let headers = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(headers.utf8) + html, completion: .contentProcessed { [weak self] _ in
            self?.close(connection); finished?()
        })
    }
    private func close(_ connection: NWConnection) {
        connection.cancel(); connections.removeAll { $0 === connection }; activeConnections = connections.count
    }
}
