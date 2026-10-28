import Foundation

private actor Receipts {
    var count = 0
    func receive() { count += 1 }
}

@main
struct LoopbackChecks {
    static func main() async throws {
        let receipts = Receipts()
        let callback = LoopbackCallback(state: "synthetic-test-state") { _ in Task { await receipts.receive() } }
        let port = try await callback.start()
        defer { callback.stop() }
        let base = "http://127.0.0.1:\(port)"
        func status(_ path: String) async throws -> Int {
            let (_, response) = try await URLSession.shared.data(from: URL(string: base + path)!)
            return (response as! HTTPURLResponse).statusCode
        }
        func check(_ condition: Bool, _ name: String) throws {
            if !condition { throw NSError(domain: "LoopbackCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
        }
        try check(try await status("/civitai/callback?state=wrong&code=synthetic") == 400, "reject wrong state")
        try check(await receipts.count == 0, "wrong state must not consume authorization")
        try check(try await status("/civitai/callback?state=synthetic-test-state&code=synthetic") == 200, "accept matching callback")
        for _ in 0..<50 {
            if await receipts.count == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try check(await receipts.count == 1, "deliver one callback")
        try check(try await status("/civitai/callback?state=synthetic-test-state&code=synthetic") == 400, "reject replay")
        try check(await receipts.count == 1, "replay must not deliver twice")
        print("LoopbackChecks: 6 callback checks passed; no external authentication request was made")
    }
}
