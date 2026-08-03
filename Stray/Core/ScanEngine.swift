import Foundation
import Combine

@MainActor
final class ScanEngine: ObservableObject {
    @Published var findings: [Finding] = []
    @Published var lastScan: Date?
    @Published var isScanning = false

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
        default:
            if let pid = finding.pid {
                ProcessScanner.terminate(pid: pid)
                finding.extraPIDs.forEach { ProcessScanner.terminate(pid: $0) }
            }
        }
        // quick re-scan to reflect the change
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.scan() }
    }
}
