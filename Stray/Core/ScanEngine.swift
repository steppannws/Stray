import Foundation
import Combine

@MainActor
final class ScanEngine: ObservableObject {
    @Published var findings: [Finding] = []
    @Published var lastScan: Date?
    @Published var isScanning = false

    // Disk scanning is manual-only and never touches the process-scan timer: disk walks
    // and sizing are I/O heavy, so they live in their own published lane.
    @Published var diskFindings: [Finding] = []
    @Published var isDiskScanning = false
    @Published var lastDiskScan: Date?
    /// Surfaces a failed reclaim (trash/simctl/docker/emptyTrash) to the UI. A failure
    /// must never look like a silent success, so this is set whenever a Reclaimer call
    /// throws instead of the error being swallowed.
    @Published var lastError: String?

    var reclaimableBytes: Int64 {
        diskFindings.compactMap(\.bytes).reduce(0, +)
    }

    /// Paths with a reclaim currently in flight, guarding against a double-confirm.
    /// `FindingRow`'s confirm button stays rendered until the row is removed, and removal
    /// only happens after the blocking Reclaimer call returns, so a second tap before
    /// that would otherwise fire a second `Reclaimer.trash` on an already-trashed path.
    ///
    /// Keyed on `path`, not `Finding.id`: a rescan replaces `diskFindings` wholesale with
    /// fresh `Finding` values carrying new UUIDs (see `removeDiskFinding`), so an id-keyed
    /// guard would miss a reappeared row for the same still-in-flight path and let a
    /// second confirm through. `path` is stable across a rescan; `id` is not.
    private var inFlight: Set<String> = []
    /// Same guard as `inFlight`, kept separate because emptying the Trash has no
    /// corresponding `Finding` row to key off.
    private var emptyingTrash = false

    /// Running totals while `scanDisk()`'s sizing pass is in flight, keyed by finding id.
    /// A finding is only as "sized" (non-nil `bytes`) once every one of its
    /// `reclaimPaths` has reported — summing partial results into `bytes` directly would
    /// let a still-growing number look final and be confirmed before all of it is known,
    /// understating what the reclaim is about to remove.
    private var pendingSizeCounts: [Finding.ID: Int] = [:]
    private var pendingSizeSums: [Finding.ID: Int64] = [:]
    /// Bumped by every `beginSizing(for:)` call. Each `scanDisk()` pass captures the
    /// generation current at its start and stamps it on every `applySize` callback it
    /// schedules; `applySize` drops any callback whose generation doesn't match the
    /// current one. Without this, a sizing pass from a *previous* scan that is still
    /// draining its unstructured `Task { @MainActor }` callbacks when a new scan starts
    /// could deliver a stale report against the new pass's rows — today's ordering is not
    /// structurally guaranteed FIFO, so this closes that gap outright rather than relying
    /// on task-scheduling behavior.
    private(set) var sizingGeneration = 0

    private var timer: Timer?
    private let interval: TimeInterval = 300 // 5 min

    /// `startTimer` exists for tests: constructing a real `ScanEngine()` normally starts
    /// a live process scan and a 5-minute repeating `Timer` as a side effect, neither of
    /// which a unit test exercising the disk lane wants or should leave running past the
    /// test's lifetime.
    init(startTimer: Bool = true) {
        guard startTimer else { return }
        scan()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
    }

    func scan() {
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

    func resolve(_ finding: Finding) {
        switch finding.kind {
        case .orphanLaunchd:
            try? LaunchdScanner.remove(finding: finding)
            // quick re-scan to reflect the change
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.scan() }

        case .projectJunk:
            guard !inFlight.contains(finding.path) else { return }
            inFlight.insert(finding.path)
            lastError = nil

            let roots = DiskScanner.defaultRoots
            let reclaimPaths = finding.reclaimPaths
            Task.detached(priority: .utility) {
                do {
                    try Self.trashAll(reclaimPaths, scanRoots: roots)
                    await MainActor.run {
                        self.removeDiskFinding(finding)
                        self.lastError = nil
                        self.inFlight.remove(finding.path)
                    }
                } catch {
                    await MainActor.run {
                        self.lastError = "Could not remove \(finding.title): \(error.localizedDescription)"
                        self.inFlight.remove(finding.path)
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

    /// Trashes every path in order, capturing (and re-throwing) only the first failure so
    /// a multi-path reclaim still attempts every path rather than aborting after one.
    /// Shared by project-junk removal and the `.trash` branch of `resolveCache` — both
    /// reduce to "trash this exact list of `reclaimPaths`".
    private nonisolated static func trashAll(_ paths: [URL], scanRoots: [URL]) throws {
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
    /// on `path` too closes that gap. Also drops any leftover sizing bookkeeping for the
    /// removed row(s), in case a reclaim completes mid-scan while sizing was still
    /// pending for that finding.
    ///
    /// Internal (not `private`) so tests can exercise the rescan-survival case directly.
    func removeDiskFinding(_ finding: Finding) {
        let removedIDs = diskFindings
            .filter { $0.id == finding.id || $0.path == finding.path }
            .map(\.id)
        diskFindings.removeAll { $0.id == finding.id || $0.path == finding.path }
        for id in removedIDs {
            pendingSizeCounts[id] = nil
            pendingSizeSums[id] = nil
        }
    }

    /// Manual only — disk walks are I/O heavy and never run on the process timer.
    func scanDisk() {
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
        sizingGeneration += 1
        diskFindings = findings
        lastDiskScan = Date()
        // `uniquingKeysWith` rather than `uniqueKeysWithValues`: the latter traps at
        // runtime on a duplicate `Finding.ID`, which is a crash bug waiting to happen
        // rather than a compile-time guarantee — `Finding.id` is caller-generated
        // (`UUID()`), not validated unique by this initializer.
        pendingSizeCounts = Dictionary(
            findings.map { ($0.id, $0.reclaimPaths.count) },
            uniquingKeysWith: { _, latest in latest }
        )
        pendingSizeSums = [:]
    }

    /// Sums bytes across every path a finding will actually reclaim (`Finding.reclaimPaths`)
    /// so the displayed size always equals what the reclaim button will remove — a cache
    /// entry backed by two on-disk locations (e.g. Yarn) is not "done" sizing until both
    /// have reported, and only their sum is ever shown.
    ///
    /// Two things make this safe against reports arriving out of the order a naive
    /// implementation would assume:
    /// - `generation` must match the pass current when this callback fires, or it is
    ///   dropped outright — closes a stale report from a *previous* scan's still-draining
    ///   callbacks landing against the new pass's (possibly reused) finding ids.
    /// - A report for a finding with no entry left in `pendingSizeCounts` (already
    ///   finalized, or never eligible) is ignored rather than "re-finalized" — a
    ///   late-arriving duplicate of an already-summed path can no longer overwrite the
    ///   correct total with a single path's bytes.
    /// A URL matching no live row (never present, or already removed by a completed
    /// reclaim) is likewise a no-op.
    func applySize(_ bytes: Int64, to url: URL, generation: Int) {
        guard generation == sizingGeneration else { return }

        for idx in diskFindings.indices
        where diskFindings[idx].reclaimPaths.contains(where: { $0.path == url.path }) {
            let id = diskFindings[idx].id
            guard let remaining = pendingSizeCounts[id] else { continue }

            let sum = (pendingSizeSums[id] ?? 0) + bytes
            if remaining - 1 <= 0 {
                diskFindings[idx].bytes = sum
                pendingSizeSums[id] = nil
                pendingSizeCounts[id] = nil
            } else {
                pendingSizeSums[id] = sum
                pendingSizeCounts[id] = remaining - 1
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
            reclaimPaths: reclaimPaths
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
        guard !inFlight.contains(finding.path) else { return }
        inFlight.insert(finding.path)
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
                    self.inFlight.remove(finding.path)
                }
            } catch {
                await MainActor.run {
                    self.lastError = "Could not clear \(finding.title): \(error.localizedDescription)"
                    self.inFlight.remove(finding.path)
                }
            }
        }
    }

    /// Delegates to Finder; see `Reclaimer.emptyTrash` for why. Runs off the main actor
    /// since `osascript` blocks for as long as Finder takes to empty the Trash.
    func emptyTrash() {
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
