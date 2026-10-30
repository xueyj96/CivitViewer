import Foundation
import Combine

/// Shared preference contract for the settings UI and the prefetch scheduler.
enum MediaPrefetchConcurrency {
    static let defaultsKey = "mediaPrefetchConcurrency"
    static let defaultValue = 4
    static let steps = [2, 4, 6, 8]
    static func validated(_ value: Int) -> Int { steps.contains(value) ? value : defaultValue }
}

/// Bounded, view-independent preloading for a moving timeline window.
@MainActor
final class MediaPreloader: ObservableObject {
    struct Snapshot: Equatable {
        let active: Int
        let configuredConcurrency: Int
        let desired: Int
        let ready: Int
        let failed: Int
        let networkPaused: Int
    }

    private struct Key: Hashable {
        let url: URL
        let video: Bool
    }
    private struct Candidate {
        let key: Key
        let priority: Int
    }
    private struct Job {
        let id: UUID
        let task: Task<Void, Never>
        let networkRevision: Int
        let completionRevision: Int
    }

    private let cache: MediaCache
    private let owner = UUID()
    private var networkValue = false
    private var networkRevision = 0
    private var completionRevision = 0
    private var networkCancellable: AnyCancellable?
    private var invalidationCancellable: AnyCancellable?
    private var playbackCancellable: AnyCancellable?
    private var playbackDemand = MediaCache.ForegroundVideoDemand()
    private var jobs: [Key: Job] = [:]
    private var desired: [Key] = []
    private var windowTarget = 6
    private var candidates: [Key: Candidate] = [:]
    private var attempted = Set<Key>()
    private var ready = Set<Key>()
    private var failed = Set<Key>()
    private var failureCodes: [Key: DiagnosticCode] = [:]
    private var spaceDeferred: [Key: Int] = [:]
    private var context: String?
    private var currentKey: Key?
    private var wifiOnly = true
    private var invalidationSeen = false
    private var invalidated = false
    private var stopped = false
    private var networkPaused = Set<Key>()
    private var concurrencyLimit = MediaPrefetchConcurrency.defaultValue

    init(cache: MediaCache = .shared, network: AnyPublisher<Bool, Never>? = nil) {
        self.cache = cache
        networkCancellable = (network ?? cache.prefetchNetwork)
            .sink { [weak self] allowed in
                guard let self else { return }
                self.networkValue = allowed
                self.networkRevision += 1
                // A path can change from offline to cellular while remaining
                // false for unmetered Wi-Fi. Retry failed remote media on each
                // path snapshot, while keeping successful and running work.
                let retryable = self.failed.filter { !$0.url.isFileURL }
                self.attempted.subtract(retryable); self.failed.subtract(retryable)
                for key in retryable { self.failureCodes[key] = nil; self.spaceDeferred[key] = nil }
                self.reconcile()
            }

        invalidationCancellable = cache.prefetchInvalidations
            .sink { [weak self] _ in
                guard let self else { return }
                if !self.invalidationSeen {
                    self.invalidationSeen = true
                    return
                }
                self.invalidated = true
                self.cancelAll()
                self.desired = []
                self.candidates = [:]
                self.attempted = []
                self.ready = []
                self.failed = []
                self.failureCodes = [:]; self.spaceDeferred = [:]
                self.cache.removePrefetchTargets(owner: self.owner)
            }
        playbackCancellable = cache.foregroundVideoDemands.sink { [weak self] value in
            guard let self else { return }
            self.playbackDemand = value
            self.reconcile()
        }
    }

    var snapshot: Snapshot {
        Snapshot(active: jobs.count, configuredConcurrency: concurrencyLimit, desired: desired.count, ready: ready.count,
                 failed: failed.count,
                 networkPaused: networkPaused.count)
    }

    func update(_ items: [MediaItem], after index: Int, count: Int = 6,
                context newContext: String, wifiOnly newWifiOnly: Bool,
                concurrency newConcurrency: Int = MediaPrefetchConcurrency.defaultValue) {
        guard !Task.isCancelled else { return }
        stopped = false
        if context != newContext {
            cancelAll()
            context = newContext
            attempted = []
            ready = []
            failed = []
            failureCodes = [:]; spaceDeferred = [:]
            invalidated = false
        }
        let wasWifiOnly = wifiOnly
        wifiOnly = newWifiOnly
        if wasWifiOnly != newWifiOnly {
            attempted = attempted.filter { !$0.video }
            failed = failed.filter { !$0.video }
            failureCodes = failureCodes.filter { !$0.key.video }; spaceDeferred = spaceDeferred.filter { !$0.key.video }
        }

        let windowSize = [3, 6, 10].contains(count) ? count : 6
        windowTarget = windowSize
        concurrencyLimit = MediaPrefetchConcurrency.validated(newConcurrency)
        let normalizedIndex = items.indices.contains(index) ? index : -1
        let priorFocus = currentKey
        currentKey = normalizedIndex >= 0 ? makeMediaKey(items[normalizedIndex]) : nil
        if priorFocus != currentKey {
            // An explicit page advance is fresh demand. Give failed remote
            // targets one new attempt, including a previously full disk budget.
            let retryable = failed.filter { !$0.url.isFileURL }
            attempted.subtract(retryable); failed.subtract(retryable)
            for key in retryable { failureCodes[key] = nil; spaceDeferred[key] = nil }
        }
        let start = normalizedIndex >= 0 ? normalizedIndex + 1 : 0
        let window = Array(items.dropFirst(start).prefix(windowSize))
        var ordered: [Candidate] = []
        var newCandidates: [Key: Candidate] = [:]
        for (offset, item) in window.enumerated() {
            guard let media = makeMediaKey(item) else { continue }
            let main = Candidate(key: media, priority: offset)
            if newCandidates[media] == nil { ordered.append(main); newCandidates[media] = main }
            if item.isVideo, let posterURL = item.posterURL, !posterURL.isFileURL {
                let posterKey = Key(url: posterURL, video: false)
                if newCandidates[posterKey] == nil {
                    let poster = Candidate(key: posterKey, priority: 100 + offset)
                    ordered.append(poster)
                    newCandidates[posterKey] = poster
                }
            }
        }
        let newDesired = ordered.map(\.key)
        let newSet = Set(newDesired)
        // Newly exposed work may receive one attempt; unchanged targets keep their
        // result and in-flight task across page movement.
        attempted = attempted.intersection(newSet.union(currentKey.map { [$0] } ?? []))
        ready = ready.intersection(newSet)
        failed = failed.intersection(newSet)
        failureCodes = failureCodes.filter { newSet.contains($0.key) }
        spaceDeferred = spaceDeferred.filter { newSet.contains($0.key) }
        candidates = newCandidates
        desired = newDesired
        invalidated = false

        // A newly current remote video streams through AVPlayer; retaining its
        // unfinished full-file prefetch would create a second transfer.
        // Foreground images join the cache's existing file transfer, so retain
        // their writer while the visible image view attaches to it.
        let expiredJobs = jobs.keys.filter { !newSet.contains($0) && ($0 != currentKey || $0.video) }
        for key in expiredJobs { cancelJob(key) }
        var protectedKeys = newSet
        if let currentKey, jobs[currentKey] != nil { protectedKeys.insert(currentKey) }
        let protected = protectedKeys.compactMap { key -> (URL, Bool)? in
            guard !key.url.isFileURL else { return nil }
            return (key.url, key.video)
        }
        cache.setPrefetchTargets(protected, owner: owner)
        reconcile()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        cancelAll()
        desired = []
        candidates = [:]
        attempted = []
        ready = []
        failed = []
        failureCodes = [:]; spaceDeferred = [:]
        networkPaused = []
        currentKey = nil
        cache.removePrefetchTargets(owner: owner)
    }

    deinit {
        for job in jobs.values { job.task.cancel() }
        let cache = cache
        let owner = owner
        Task { @MainActor in cache.removePrefetchTargets(owner: owner) }
    }

    private func makeMediaKey(_ item: MediaItem) -> Key? {
        guard let url = item.mediaURL else { return nil }
        return Key(url: url, video: item.isVideo)
    }

    private func cancelAll() {
        for key in Array(jobs.keys) { cancelJob(key) }
    }

    private func cancelJob(_ key: Key) {
        guard let job = jobs.removeValue(forKey: key) else { return }
        job.task.cancel(); attempted.remove(key)
        // Cancellation releases a shared cache reservation asynchronously. Wake
        // the current window after that release, including across filter swaps.
        Task { @MainActor [weak self] in
            await job.task.value
            guard let self, !self.stopped, !self.invalidated else { return }
            self.completionRevision += 1
            self.reconcile()
        }
    }

    private func reconcile() {
        guard !stopped, !invalidated else { return }
        defer { publishStatus() }
        for (key, revision) in Array(spaceDeferred) where revision < completionRevision && cache.hasPrefetchSpace(video: key.video) {
            attempted.remove(key); failed.remove(key); failureCodes[key] = nil; spaceDeferred[key] = nil
        }
        // Network policy limits new transfers, not reuse of bytes already local.
        for key in desired where jobs[key] == nil {
            let local = key.url.isFileURL ? FileManager.default.fileExists(atPath: key.url.path) : cache.cached(key.url, video: key.video) != nil
            if local { attempted.insert(key); ready.insert(key); failed.remove(key); failureCodes[key] = nil; spaceDeferred[key] = nil }
        }
        networkPaused = []
        for key in desired where key.video && wifiOnly && !networkValue && !ready.contains(key) {
            networkPaused.insert(key)
        }
        let pausedJobs = jobs.keys.filter { ($0.video && wifiOnly && !networkValue) || playbackBlocks($0) }
        for key in pausedJobs {
            cancelJob(key)
            failed.remove(key)
            failureCodes[key] = nil; spaceDeferred[key] = nil
        }
        // Recompute ranks from the current window, including running jobs. A
        // retained far download must yield to a newly nearest missing work.
        let ranked = desired.compactMap { candidates[$0] }
            .filter { !ready.contains($0.key) && (!attempted.contains($0.key) || jobs[$0.key] != nil) }
            .filter { !($0.key.video && wifiOnly && !networkValue) && !playbackBlocks($0.key) }
            .sorted { $0.priority < $1.priority }
        let currentImages = Set(jobs.keys.filter { $0 == currentKey && !$0.video })
        let futureSlots = max(0, concurrencyLimit - currentImages.count)
        let preferred = currentImages.union(ranked.prefix(futureSlots).map(\.key))
        for key in jobs.keys.filter({ !preferred.contains($0) }) {
            cancelJob(key)
        }
        // Existing far reservations may be the very reason capacity is full;
        // yield them before testing admission of the newly nearest target.
        guard cache.hasPrefetchSpace(video: false) else { return }
        while jobs.count < concurrencyLimit {
            guard let candidate = desired.compactMap({ candidates[$0] })
                .filter({ !attempted.contains($0.key) && jobs[$0.key] == nil })
                .filter({ !($0.key.video && wifiOnly && !networkValue) })
                .filter({ !playbackBlocks($0.key) })
                .sorted(by: { $0.priority < $1.priority }).first else { break }
            let key = candidate.key
            if key.url.isFileURL {
                attempted.insert(key)
                if FileManager.default.fileExists(atPath: key.url.path) { ready.insert(key) }
                else { failed.insert(key) }
                continue
            }
            if cache.cached(key.url, video: key.video) != nil {
                attempted.insert(key); ready.insert(key)
                continue
            }
            launch(key)
        }
    }

    private func playbackBlocks(_ key: Key) -> Bool {
        key.video && (playbackDemand.waiting || playbackDemand.urls.contains(key.url))
    }

    private func launch(_ key: Key) {
        let id = UUID()
        let cache = self.cache
        attempted.insert(key)
        let task = Task { @MainActor [weak self, cache] in
            do {
                _ = try await cache.preloadFile(key.url, video: key.video)
                try Task.checkCancellation()
                self?.finish(key, id: id, success: true)
            } catch is CancellationError {} catch {
                guard !Task.isCancelled, let self, self.jobs[key]?.id == id else { return }
                let code = cache.recordPreloadFailure(error)
                let space: Bool = if case ImageLoadError.lowSpace = error { true } else { false }
                self.finish(key, id: id, success: false, code: code, space: space)
            }
        }
        jobs[key] = Job(id: id, task: task, networkRevision: networkRevision, completionRevision: completionRevision)
    }

    private func finish(_ key: Key, id: UUID, success: Bool, code: DiagnosticCode? = nil, space: Bool = false) {
        guard let job = jobs[key], job.id == id else { return }
        jobs[key] = nil
        if success { completionRevision += 1 }
        if desired.contains(key) {
            if success { ready.insert(key); failureCodes[key] = nil; spaceDeferred[key] = nil }
            else if !key.url.isFileURL && job.networkRevision != networkRevision { attempted.remove(key) }
            else {
                failed.insert(key); failureCodes[key] = code
                if space { spaceDeferred[key] = job.completionRevision }
            }
        }
        reconcile()
    }

    private func publishStatus() {
        guard context != nil, !stopped, !invalidated else { return }
        let primary = Set(candidates.values.filter { $0.priority < 100 }.map(\.key))
        let failures = primary.intersection(failed)
        let value = MediaPreloadStatus(ready: primary.intersection(ready).count, total: primary.count, target: windowTarget,
            running: primary.intersection(Set(jobs.keys)).count, failed: failures.count,
            networkPaused: primary.intersection(networkPaused).count,
            oversized: failures.filter { failureCodes[$0] == .limit }.count,
            spaceLimited: failures.filter { failureCodes[$0] == .storage }.count,
            networkFailed: failures.filter { failureCodes[$0] == .network || failureCodes[$0] == .http }.count)
        var status = value
        status.playbackDeferred = primary.filter { !ready.contains($0) && playbackBlocks($0) }.count
        cache.setPreloadStatus(status, owner: owner)
    }
}
