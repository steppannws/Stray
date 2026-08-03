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
            let url = URL(fileURLWithPath: finding.path)
            let roots = DiskScanner.defaultRoots
            Task.detached(priority: .utility) {
                do {
                    try Reclaimer.trash(url, scanRoots: roots)
                    await MainActor.run {
                        self.diskFindings.removeAll { $0.id == finding.id }
                    }
                } catch {
                    await MainActor.run {
                        self.lastError = "Could not remove \(finding.title): \(error)"
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

    /// Manual only — disk walks are I/O heavy and never run on the process timer.
    func scanDisk() {
        guard !isDiskScanning else { return }
        isDiskScanning = true

        Task.detached(priority: .utility) {
            let junk = DiskScanner.scan()
            let caches = CacheCatalog.present()
            let findings = junk.map(Self.junkFinding) + caches.map(Self.cacheFinding)

            await MainActor.run {
                self.diskFindings = findings
                self.lastDiskScan = Date()
            }

            let sizable = findings.compactMap(\.pathURL)
            await SizeProbe.sizes(for: sizable) { url, bytes in
                Task { @MainActor in self.applySize(bytes, to: url) }
            }

            await MainActor.run {
                self.diskFindings.sort { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
                self.isDiskScanning = false
            }
        }
    }

    private func applySize(_ bytes: Int64, to url: URL) {
        guard let idx = diskFindings.firstIndex(where: { $0.path == url.path }) else { return }
        diskFindings[idx].bytes = bytes
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
            isActiveProject: active
        )
    }

    private nonisolated static func cacheFinding(_ entry: CacheEntry) -> Finding {
        // `entry.paths` can hold several alternate locations for the same logical cache
        // (e.g. the Yarn entry). Size and identify the first one that actually exists on
        // this machine, not just the first in the list — otherwise a present cache whose
        // first-listed path is absent on this machine would be sized as a non-existent 0.
        let existingPath = entry.paths.first { FileManager.default.fileExists(atPath: $0.path) }
        let path = existingPath ?? entry.paths.first
        return Finding(
            kind: .toolCache,
            severity: .info,
            title: entry.name,
            detail: entry.regeneratedBy,
            pid: nil,
            path: path?.path ?? entry.id,
            startedAt: nil
        )
    }

    private func resolveCache(_ finding: Finding) {
        // Cache entries are matched by name rather than a dedicated join key: `Finding`
        // deliberately isn't extended with a new field for this, and every name in
        // `CacheCatalog.all` is already unique, so this is reliable in practice even
        // though it would break silently if two entries ever shared a display name.
        guard let entry = CacheCatalog.all.first(where: { $0.name == finding.title }) else { return }

        Task.detached(priority: .utility) {
            do {
                switch entry.reclaim {
                case .trash:
                    var firstError: Error?
                    for path in entry.paths where FileManager.default.fileExists(atPath: path.path) {
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
                    self.diskFindings.removeAll { $0.id == finding.id }
                }
            } catch {
                await MainActor.run {
                    self.lastError = "Could not clear \(finding.title): \(error)"
                }
            }
        }
    }

    /// Delegates to Finder; see `Reclaimer.emptyTrash` for why. Runs off the main actor
    /// since `osascript` blocks for as long as Finder takes to empty the Trash.
    func emptyTrash() {
        Task.detached(priority: .utility) {
            do {
                try Reclaimer.emptyTrash()
            } catch {
                await MainActor.run {
                    self.lastError = "Could not empty Trash: \(error)"
                }
            }
        }
    }
}
