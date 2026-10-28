import Foundation

@main struct SiteCooldownChecks {
    @MainActor static func main() async throws {
        var checks = 0, clock = Date(timeIntervalSince1970: 1_800_000_000)
        func check(_ value: @autoclosure () -> Bool, _ why: String) { precondition(value(), why); checks += 1 }
        func denied(_ gate: SiteRequestCooldown) -> Bool {
            do { try gate.check(); return false } catch ClientError.http(429) { return true } catch { return false }
        }
        let gate = SiteRequestCooldown(now: { clock })
        check(!denied(gate), "A fresh client admits reads")
        gate.record429(retryAfter: nil)
        check(gate.retryAvailableAt == clock.addingTimeInterval(300) && denied(gate), "Missing Retry-After starts a five-minute shared cooldown")
        var networkCalls = 0
        for _ in 0..<20 { if !denied(gate) { networkCalls += 1 } }
        check(networkCalls == 0, "Repeated user or automatic retries cannot send reads while blocked")
        gate.recordSuccess()
        check(denied(gate), "An older concurrent success cannot clear the newer cooldown")
        gate.record429(retryAfter: " 600 ")
        check(gate.retryAvailableAt == clock.addingTimeInterval(600), "Numeric Retry-After is honored")
        gate.record429(retryAfter: "5")
        check(gate.retryAvailableAt == clock.addingTimeInterval(600), "A later shorter header cannot shorten a current block")
        clock.addTimeInterval(601)
        check(!denied(gate), "Reads become eligible after the deadline without an automatic retry loop")
        gate.recordSuccess()
        check(gate.retryAvailableAt == nil, "A success after expiry clears the old backoff")
        let dated = SiteRequestCooldown(now: { clock })
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        dated.record429(retryAfter: formatter.string(from: clock.addingTimeInterval(900)))
        check(dated.retryAvailableAt == clock.addingTimeInterval(900), "HTTP-date Retry-After is honored")
        let invalid = SiteRequestCooldown(now: { clock })
        invalid.record429(retryAfter: "bad header")
        check(invalid.retryAvailableAt == clock.addingTimeInterval(300), "Malformed headers fall back to bounded backoff")
        invalid.record429(retryAfter: nil)
        check(invalid.retryAvailableAt == clock.addingTimeInterval(600), "Repeated 429 increases the fallback")
        for _ in 0..<10 { invalid.record429(retryAfter: nil) }
        check(invalid.retryAvailableAt == clock.addingTimeInterval(3600), "Fallback backoff saturates at one hour")
        let immediate = SiteRequestCooldown(now: { clock }); immediate.record429(retryAfter: "0")
        check(immediate.retryAvailableAt == clock.addingTimeInterval(30), "A zero header cannot immediately restart a burst")
        let suite = "CivitViewer.CooldownChecks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!; defer { defaults.removePersistentDomain(forName: suite) }
        let persisted = SiteRequestCooldown(defaults: defaults, now: { clock }); persisted.record429(retryAfter: "750")
        let restarted = SiteRequestCooldown(defaults: defaults, now: { clock })
        check(restarted.retryAvailableAt == clock.addingTimeInterval(750) && denied(restarted), "Relaunch cannot bypass the saved deadline")
        clock.addTimeInterval(751); restarted.recordSuccess()
        check(defaults.object(forKey: "siteReadCooldownUntil57") == nil, "An expired successful retry clears persisted state")
        let anonymous = SiteRequestCooldown(now: { clock })
        var anonymousCalls = 0
        do {
            try await anonymous.performRead {
                anonymousCalls += 1
                try anonymous.validateResponse(status: 429, retryAfter: "1000")
            }
            preconditionFailure("Expected anonymous transport 429")
        } catch ClientError.http(429) { }
        check(anonymousCalls == 1 && anonymous.retryAvailableAt == clock.addingTimeInterval(1000),
              "The anonymous entry records the first HTTP429 and its header")
        for _ in 0..<10 {
            do { try await anonymous.performRead { anonymousCalls += 1 } } catch ClientError.http(429) { }
        }
        check(anonymousCalls == 1, "The actual anonymous admission wrapper sends zero extra calls during cooldown")
        let native = SiteRequestCooldown(now: { clock }), bridge = SiteRequestCooldown(now: { clock })
        let rpcError: [String: Any] = ["json": ["data": ["httpStatus": 429]]]
        do { try native.validateResponse(status: 200, retryAfter: "700", rpcError: rpcError); preconditionFailure("Expected RPC429") }
        catch ClientError.http(429) { }
        do { try bridge.validateResponse(status: 429, retryAfter: "700"); preconditionFailure("Expected bridge429") }
        catch ClientError.http(429) { }
        check(native.retryAvailableAt == bridge.retryAvailableAt && denied(native),
              "Native HTTP200 RPC429 and the Web bridge enter the same cooldown")
        do { try native.validateResponse(status: 403); preconditionFailure("Expected explicit403") }
        catch ClientError.http(403) { }
        check(native.retryAvailableAt == clock.addingTimeInterval(700), "An unrelated response does not shorten the 429 deadline")
        let success = SiteRequestCooldown(now: { clock })
        try success.validateResponse(status: 200)
        check(success.retryAvailableAt == nil, "Ordinary successful response remains admitted")
        print("SiteCooldownChecks: \(checks) assertions passed; zero real requests")
    }
}
