import Foundation

enum FindingKind: String, CaseIterable {
    case orphanMCP = "Orphan MCP"
    case orphanProcess = "Orphan process"
    case duplicate = "Duplicate"
    case orphanLaunchd = "Orphan launchd"
    case staleDevServer = "Stale dev server"
}

enum Severity: Int, Comparable {
    case info = 0, warning = 1, strong = 2
    static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct Finding: Identifiable, Hashable {
    let id = UUID()
    let kind: FindingKind
    let severity: Severity
    let title: String        // e.g. "context7-mcp"
    let detail: String       // evidence: why we flagged it
    let pid: pid_t?          // nil for launchd findings (files)
    var extraPIDs: [pid_t] = [] // sibling instances killed in the same batch
    let path: String         // binary or plist
    let startedAt: Date?

    var uptimeDescription: String {
        guard let startedAt else { return "—" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: startedAt, relativeTo: Date())
    }
}
