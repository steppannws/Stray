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

    /// Findings with a reclaim currently in flight, guarding against a double-confirm:
    /// `FindingRow`'s confirm button stays rendered until the row is removed, and removal
    /// only happens after the blocking Reclaimer call returns, so a second tap before
    /// that would otherwise fire a second `Reclaimer.trash` on an already-trashed path.
    private var inFlight: Set<Finding.ID> = []
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

    private var timer: Timer?
    private let interval: TimeInterval = 300 // 5 min

    init() {
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
            guard !inFlight.contains(finding.id) else { return }
            inFlight.insert(finding.id)
            lastError = nil

            let url = URL(fileURLWithPath: finding.path)
            let roots = DiskScanner.defaultRoots
            Task.detached(priority: .utility) {
                do {
                    try Reclaimer.trash(url, scanRoots: roots)
                    await MainActor.run {
                        self.removeDiskFinding(finding)
                        self.lastError = nil
                        self.inFlight.remove(finding.id)
                    }
                } catch {
                    await MainActor.run {
                        self.lastError = "Could not remove \(finding.title): \(error.localizedDescription)"
                        self.inFlight.remove(finding.id)
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

    /// A rescan replaces `diskFindings` wholesale with fresh `Finding` values carrying
    /// new UUIDs, so a reclaim started before a rescan and completing after one would
    /// find no `id` match and leave a phantom row for an already-trashed path. Matching
    /// on `path` too closes that gap.
    private func removeDiskFinding(_ finding: Finding) {
        diskFindings.removeAll { $0.id == finding.id || $0.path == finding.path }
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

            await MainActor.run {
                self.beginSizing(for: findings)
            }

            let sizable = findings.flatMap(\.reclaimPaths)
            await SizeProbe.sizes(for: sizable) { url, bytes in
                Task { @MainActor in self.applySize(bytes, to: url) }
            }
        }
    }

    /// Internal (not `private`) so tests can seed `diskFindings` and the pending-size
    /// bookkeeping consistently, the same way `scanDisk()` does, without touching disk.
    func beginSizing(for findings: [Finding]) {
        diskFindings = findings
        lastDiskScan = Date()
        pendingSizeCounts = Dictionary(uniqueKeysWithValues: findings.map { ($0.id, $0.reclaimPaths.count) })
        pendingSizeSums = [:]
    }

    /// Sums bytes across every path a finding will actually reclaim (`Finding.reclaimPaths`)
    /// so the displayed size always equals what the reclaim button will remove — a cache
    /// entry backed by two on-disk locations (e.g. Yarn) is not "done" sizing until both
    /// have reported, and only their sum is ever shown. A URL matching no live row (either
    /// never present or already removed by a completed reclaim) is a no-op.
    func applySize(_ bytes: Int64, to url: URL) {
        for idx in diskFindings.indices
        where diskFindings[idx].reclaimPaths.contains(where: { $0.path == url.path }) {
            let id = diskFindings[idx].id
            let sum = (pendingSizeSums[id] ?? 0) + bytes
            let remaining = (pendingSizeCounts[id] ?? 1) - 1
            pendingSizeSums[id] = sum
            pendingSizeCounts[id] = remaining
            if remaining <= 0 {
                diskFindings[idx].bytes = sum
                pendingSizeSums[id] = nil
                pendingSizeCounts[id] = nil
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
        guard !inFlight.contains(finding.id) else { return }
        inFlight.insert(finding.id)
        lastError = nil

        // Trash exactly the paths that were sized for this row (`finding.reclaimPaths`),
        // not a freshly re-derived existence check — that is what keeps the displayed
        // size equal to what actually gets removed.
        let reclaimPaths = finding.reclaimPaths

        Task.detached(priority: .utility) {
            do {
                switch entry.reclaim {
                case .trash:
                    var firstError: Error?
                    for path in reclaimPaths {
                        do {
                            try Reclaimer.trash(path, scanRoots: [])
                        } catch {
                            firstError = firstError ?? error
                        }
                    }
                    if let firstError { throw firstError }
                case .simctlDeleteUnavailable:
                    try Reclaimer.simctlDeleteUnavailable()
                case .dockerImagePrune:
                    try Reclaimer.dockerImagePrune()
                }
                await MainActor.run {
                    self.removeDiskFinding(finding)
                    self.lastError = nil
                    self.inFlight.remove(finding.id)
                }
            } catch {
                await MainActor.run {
                    self.lastError = "Could not clear \(finding.title): \(error.localizedDescription)"
                    self.inFlight.remove(finding.id)
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
