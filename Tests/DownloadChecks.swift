import Foundation

private actor FirstBytes {
    private var received = false
    private var continuation: CheckedContinuation<Void, Never>?
    func notify() { received = true; continuation?.resume(); continuation = nil }
    func wait() async { if !received { await withCheckedContinuation { continuation = $0 } } }
}

@main struct DownloadChecks {
    static func main() async throws {
        let base = CommandLine.arguments[1]
        func url(_ path: String) -> URL { URL(string: base + path)! }
        let file = try await BoundedDownload.fetch(url("/valid"), maxBytes: 4096)
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize
        precondition(size == 4096, "Exact-limit payload must be accepted")
        try FileManager.default.removeItem(at: file)
        for path in ["/too-large", "/unknown-length"] {
            do { let unexpected = try await BoundedDownload.fetch(url(path), maxBytes: 1024); try? FileManager.default.removeItem(at: unexpected); preconditionFailure("Oversized response was accepted") }
            catch MediaDownloadError.limitExceeded {}
        }
        do { let unexpected = try await BoundedDownload.fetch(url("/html"), maxBytes: 4096); try? FileManager.default.removeItem(at: unexpected); preconditionFailure("HTML was accepted as media") }
        catch ClientError.invalidResponse {}
        let signal = FirstBytes()
        let task = Task { try await BoundedDownload.fetch(url("/slow"), maxBytes: 1024 * 1024) { bytes, _ in if bytes > 0 { Task { await signal.notify() } } } }
        await signal.wait()
        task.cancel()
        do { let unexpected = try await task.value; try? FileManager.default.removeItem(at: unexpected); preconditionFailure("Cancelled download returned a file") }
        catch is CancellationError {}
        print("DownloadChecks: 5 real local transfer checks passed; no external site or credentials used")
    }
}
