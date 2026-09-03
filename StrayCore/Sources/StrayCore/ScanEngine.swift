import Foundation
import Combine

@MainActor
public final class ScanEngine: ObservableObject {
    @Published public var findings: [Finding] = []
    @Published public var lastScan: Date?
    @Published public var isScanning = false

    // Disk scanning is manual-only and never touches the process-scan timer: disk walks
    // and sizing are I/O heavy, so they live in their own published lane.
    @Published public var diskFindings: [Finding] = []
    @Published public var isDiskScanning = false
    @Published public var lastDiskScan: Date?
    /// Surfaces a failed reclaim (trash/simctl/docker/emptyTrash) to the UI. A failure
    /// must never look like a silent success, so this is set whenever a Reclaimer call
    /// throws instead of the error being swallowed.
    @Published public var lastError: String?

    public var reclaimableBytes: Int64 {
        diskFindings.compactMap(\.bytes).reduce(0, +)
    }

    /// Guards against a double-confirm while a reclaim is in flight. See `ReclaimGuard`
    /// for why findings are keyed on their identity path set rather than on `id`.
    private var reclaimGuard = ReclaimGuard()
    /// Tracked separately from `reclaimGuard` because emptying the Trash has no
    /// corresponding `Finding` row to key off.
    private var emptyingTrash = false

    /// Running totals while `scanDisk()`'s sizing pass is in flight. See `SizeTally` for
    /// the partial-sum and stale-generation rules it enforces.
    private var sizeTally = SizeTally()

    /// Exposed for tests, which stamp callbacks with the pass they belong to.
    var sizingGeneration: Int { sizeTally.generation }

    private var timer: Timer?
    private let interval: TimeInterval = 300 // 5 min

    /// `startTimer` exists for tests: constructing a real `ScanEngine()` normally starts
    /// a live process scan and a 5-minute repeating `Timer` as a side effect, neither of
    /// which a unit test exercising the disk lane wants or should leave running past the
    /// test's lifetime.
    public init(startTimer: Bool = true) {
        guard startTimer else { return }
        scan()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
    }

    public func scan() {
        guard !isScanning else { return }
        isScanning = true
        Task.detached(priority: .utility) {
            let procs = ProcessScanner.scan()
            let procFindings = Rules.evaluate(procs)
            let launchdFindings = LaunchdScanner.scanUserAgents()
            await MainActor.run {
                self.findings = procFindings + launchdFindings
                self.lastScan = Date()
                self.isScanning = false
            }
        }
    }

    public func resolve(_ finding: Finding) {
        switch finding.kind {
        case .orphanLaunchd:
            try? LaunchdScanner.remove(finding: finding)
            // quick re-scan to reflect the change
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.scan() }

        case .projectJunk:
            guard beginReclaim(for: finding) else { return }
            lastError = nil

            let roots = DiskScanner.defaultRoots
            let reclaimPaths = finding.reclaimPaths
            Task.detached(priority: .utility) {
                do {
                    try Self.trashAll(reclaimPaths, scanRoots: roots)
                    await MainActor.run {
                        self.removeDiskFinding(finding)
                        self.lastError = nil
                        self.endReclaim(for: finding)
                    }
                } catch {
                    await MainActor.run {
                        self.lastError = "Could not remove \(finding.title): \(error.localizedDescription)"
                        self.endReclaim(for: finding)
                    }
                }
            }

        case .toolCache:
            resolveCache(finding)

        default:
            if let pid = finding.pid {
                ProcessScanner.terminate(pid: pid)
                finding.extraPIDs.forEach { ProcessScanner.terminate(pid: $0) }
            }
            // quick re-scan to reflect the change
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.scan() }
        }
    }

    /// Marks `finding`'s reclaim as in flight, or refuses if one already is. See
    /// `ReclaimGuard.begin(_:)`. The caller must call `endReclaim(for:)` on both the
    /// success and failure paths after a `true` return.
    ///
    /// Internal (not `private`) so tests can exercise the guard through the engine
    /// rather than only against `ReclaimGuard` in isolation.
    func beginReclaim(for finding: Finding) -> Bool {
        reclaimGuard.begin(finding)
    }

    /// Internal for the same reason as `beginReclaim(for:)`.
    func endReclaim(for finding: Finding) {
        reclaimGuard.end(finding)
    }

    /// Thrown by `trashAll` when handed no paths. This is genuinely reachable, not just a
    /// future-producer safeguard: `CacheCatalog.present()` and `cacheFinding` each run
    /// their own independent `fileExists` check, so a `.trash` entry's on-disk location
    /// can be deleted between the two (by the user, or another process) — `present()`
    /// still includes the entry, but `cacheFinding` then computes an empty
    /// `reclaimPaths` and a stale display `path`. Without this guard, `trashAll` would
    /// return cleanly on an empty list, and the caller would treat that as success and
    /// remove the row — a confirm button that silently does nothing because nothing was
    /// actually there to delete. `errorDescription` is user-facing copy (it flows
    /// straight into `ScanEngine.lastError`, which only exists to be rendered), not an
    /// internal diagnostic — it must read as something the user can act on.
    private struct EmptyReclaimPathsError: LocalizedError {
        var errorDescription: String? {
            "This item's location no longer exists. Rescan to refresh the list."
        }
    }

    /// Trashes every path in order, capturing (and re-throwing) only the first failure so
    /// a multi-path reclaim still attempts every path rather than aborting after one.
    /// Shared by project-junk removal and the `.trash` branch of `resolveCache` — both
    /// reduce to "trash this exact list of `reclaimPaths`".
    ///
    /// Internal (not `private`), matching the precedent already used elsewhere in this
    /// file (`applySize`, `beginSizing`, `removeDiskFinding`, `cacheFinding`,
    /// `beginReclaim`/`endReclaim`), so the empty-list guard is a one-line synchronous
    /// test with no `Task` and no filesystem access — it throws before ever calling
    /// `Reclaimer.trash`.
    nonisolated static func trashAll(_ paths: [URL], scanRoots: [URL]) throws {
        guard !paths.isEmpty else { throw EmptyReclaimPathsError() }
        var firstError: Error?
        for path in paths {
            do {
                try Reclaimer.trash(path, scanRoots: scanRoots)
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
    }

    /// A rescan replaces `diskFindings` wholesale with fresh `Finding` values carrying
    /// new UUIDs, so a reclaim started before a rescan and completing after one would
    /// find no `id` match and leave a phantom row for an already-trashed path. Matching
    /// on `path` too closes most of that gap, but not a multi-path cache entry whose
    /// display path shifted to a different one of its `reclaimPaths` after a rescan (see
    /// `ReclaimGuard`) — matching when `reclaimPaths` intersect closes the rest.
    /// Also drops any leftover sizing bookkeeping for the removed row(s), in case a
    /// reclaim completes mid-scan while sizing was still pending for that finding.
    ///
    /// Internal (not `private`) so tests can exercise the rescan-survival case directly.
    func removeDiskFinding(_ finding: Finding) {
        let targetPaths = Set(finding.reclaimPaths.map(\.path))
        func matches(_ row: Finding) -> Bool {
            row.id == finding.id
                || row.path == finding.path
                || !Set(row.reclaimPaths.map(\.path)).isDisjoint(with: targetPaths)
        }

        let removedIDs = diskFindings.filter(matches).map(\.id)
        diskFindings.removeAll(where: matches)
        sizeTally.forget(removedIDs)
    }

    /// Manual only — disk walks are I/O heavy and never run on the process timer.
    public func scanDisk() {
        guard !isDiskScanning else { return }
        isDiskScanning = true
        lastError = nil

        Task.detached(priority: .utility) {
            defer { Task { @MainActor in self.isDiskScanning = false } }

            let junk = DiskScanner.scan()
            let caches = CacheCatalog.present()
            let findings = junk.map(Self.junkFinding) + caches.map(Self.cacheFinding)

            let generation = await MainActor.run { () -> Int in
                self.beginSizing(for: findings)
                return self.sizingGeneration
            }

            let sizable = findings.flatMap(\.reclaimPaths)
            await SizeProbe.sizes(for: sizable) { url, bytes in
                Task { @MainActor in self.applySize(bytes, to: url, generation: generation) }
            }
        }
    }

    /// Internal (not `private`) so tests can seed `diskFindings` and the pending-size
    /// bookkeeping consistently, the same way `scanDisk()` does, without touching disk.
    func beginSizing(for findings: [Finding]) {
        diskFindings = findings
        lastDiskScan = Date()
        sizeTally.beginPass(for: findings)
    }

    /// Applies a size report to whichever row owns `url`, finalizing that row's `bytes`
    /// only once every path backing it has reported. The accumulation and ordering rules
    /// live in `SizeTally`; this method's remaining job is mapping a URL back to its rows
    /// and keeping the display sorted.
    ///
    /// A URL matching no live row (never present, or already removed by a completed
    /// reclaim) is a no-op, as is a report from a superseded sizing pass.
    func applySize(_ bytes: Int64, to url: URL, generation: Int) {
        guard sizeTally.accepts(generation: generation) else { return }

        for idx in diskFindings.indices
        where diskFindings[idx].reclaimPaths.contains(where: { $0.path == url.path }) {
            if let total = sizeTally.report(bytes, for: diskFindings[idx].id) {
                diskFindings[idx].bytes = total
            }
        }
        sortDiskFindings()
    }

    /// Descending by size; nil (still sizing, or a reclaim method that can't promise a
    /// size) sorts last. Ties break on title so equal or nil sizes don't reshuffle
    /// between scans — relying on `Task { @MainActor }` callbacks landing in submission
    /// order is not guaranteed.
    private func sortDiskFindings() {
        diskFindings.sort {
            let lhs = $0.bytes ?? -1
            let rhs = $1.bytes ?? -1
            if lhs != rhs { return lhs > rhs }
            return $0.title < $1.title
        }
    }

    private nonisolated static func junkFinding(_ url: URL) -> Finding {
        let project = url.deletingLastPathComponent()
        let modified = (try? project.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        let active = modified.map { Date().timeIntervalSince($0) < 7 * 86_400 } ?? false
        return Finding(
            kind: .projectJunk,
            severity: .info,
            title: "\(project.lastPathComponent)/\(url.lastPathComponent)",
            detail: project.path,
            pid: nil,
            path: url.path,
            startedAt: modified,
            isActiveProject: active,
            reclaimPaths: [url]
        )
    }

    nonisolated static func cacheFinding(_ entry: CacheEntry) -> Finding {
        // `entry.paths` can hold several alternate locations for the same logical cache
        // (e.g. the Yarn entry). Identify the first one that actually exists on this
        // machine, not just the first in the list — otherwise a present cache whose
        // first-listed path is absent on this machine would show a path nothing lives at.
        let existingPaths = entry.paths.filter { FileManager.default.fileExists(atPath: $0.path) }
        let displayPath = existingPaths.first ?? entry.paths.first

        // Only a `.trash` reclaim operates on fixed paths — simctl/docker prune by
        // command, not by path, and can free anywhere from zero bytes up. Leaving
        // `reclaimPaths` empty for those keeps `bytes` nil (shown as "—") rather than
        // promising the size of, say, the whole (mostly still-active) simulator tree.
        let reclaimPaths = entry.reclaim == .trash ? existingPaths : []

        return Finding(
            kind: .toolCache,
            severity: .info,
            title: entry.name,
            detail: entry.regeneratedBy,
            pid: nil,
            path: displayPath?.path ?? entry.id,
            startedAt: nil,
            reclaimPaths: reclaimPaths,
            isReversible: entry.reclaim == .trash
        )
    }

    private func resolveCache(_ finding: Finding) {
        // Cache entries are matched by name rather than a dedicated join key: `Finding`
        // deliberately isn't extended with a new field for this, and every name in
        // `CacheCatalog.all` is already unique (enforced by
        // `catalogNamesAreUnique` in CacheCatalogTests), so this is reliable in practice.
        guard let entry = CacheCatalog.all.first(where: { $0.name == finding.title }) else {
            lastError = "Could not clear \(finding.title): no matching catalog entry."
            return
        }
        guard beginReclaim(for: finding) else { return }
        lastError = nil

        // Trash exactly the paths that were sized for this row (`finding.reclaimPaths`),
        // not a freshly re-derived existence check — that is what keeps the displayed
        // size equal to what actually gets removed.
        let reclaimPaths = finding.reclaimPaths

        Task.detached(priority: .utility) {
            do {
                switch entry.reclaim {
                case .trash:
                    try Self.trashAll(reclaimPaths, scanRoots: [])
                case .simctlDeleteUnavailable:
                    try Reclaimer.simctlDeleteUnavailable()
                case .dockerImagePrune:
                    try Reclaimer.dockerImagePrune()
                }
                await MainActor.run {
                    self.removeDiskFinding(finding)
                    self.lastError = nil
                    self.endReclaim(for: finding)
                }
            } catch {
                await MainActor.run {
                    self.lastError = "Could not clear \(finding.title): \(error.localizedDescription)"
                    self.endReclaim(for: finding)
                }
            }
        }
    }

    /// Delegates to Finder; see `Reclaimer.emptyTrash` for why. Runs off the main actor
    /// since `osascript` blocks for as long as Finder takes to empty the Trash.
    public func emptyTrash() {
        guard !emptyingTrash else { return }
        emptyingTrash = true
        lastError = nil

        Task.detached(priority: .utility) {
            do {
                try Reclaimer.emptyTrash()
                await MainActor.run {
                    self.lastError = nil
                    self.emptyingTrash = false
                }
            } catch {
                await MainActor.run {
                    self.lastError = "Could not empty Trash: \(error.localizedDescription)"
                    self.emptyingTrash = false
                }
            }
        }
    }
}
