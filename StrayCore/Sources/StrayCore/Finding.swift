import Foundation

public enum FindingKind: String, CaseIterable {
    case orphanMCP = "Orphan MCP"
    case orphanProcess = "Orphan process"
    case duplicate = "Duplicate"
    case orphanLaunchd = "Orphan launchd"
    case staleDevServer = "Stale dev server"
    case projectJunk = "Project junk"
    case toolCache = "Tool cache"
}

public enum Severity: Int, Comparable {
    case info = 0, warning = 1, strong = 2
    public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct Finding: Identifiable, Hashable {
    public let id = UUID()
    public let kind: FindingKind
    public let severity: Severity
    public let title: String        // e.g. "context7-mcp"
    public let detail: String       // evidence: why we flagged it
    public let pid: pid_t?          // nil for launchd findings (files)
    public var extraPIDs: [pid_t] = [] // sibling instances killed in the same batch
    public let path: String         // binary or plist
    public let startedAt: Date?
    public var bytes: Int64?           // nil while sizing is in flight, or when the reclaim
                                 // method (e.g. simctl) can't promise a definite size
    public var isActiveProject = false // project files touched in the last 7 days
    /// The exact paths a reclaim of this finding will remove. `bytes`, once non-nil, is
    /// always the sum of sizing these paths and no others — the invariant that keeps a
    /// row from ever understating what its confirm button actually deletes. Empty for
    /// process/launchd findings and for disk findings whose reclaim method (simctl,
    /// docker) doesn't operate on fixed paths at all.
    public var reclaimPaths: [URL] = []
    /// Whether resolving this finding is reversible (moves to Trash) rather than
    /// permanent (e.g. `simctl delete unavailable`, `docker image prune`). Drives the
    /// action button's label in `MenuView` — a permanent action must never be labeled
    /// "Trash", which promises recoverability it doesn't have. Defaults to `true` (the
    /// common case: process/launchd findings and project junk are all trashed); disk
    /// cache findings set this explicitly from `entry.reclaim == .trash` in
    /// `ScanEngine.cacheFinding`. Kept as the trailing property so every existing call
    /// site — none of which pass it — keeps compiling unchanged.
    public var isReversible = true

    public var uptimeDescription: String {
        guard let startedAt else { return "—" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: startedAt, relativeTo: Date())
    }

    public var sizeDescription: String {
        guard let bytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// `path` doubles as a non-filesystem identifier for cache entries with no existing
    /// location on this machine (see `ScanEngine.cacheFinding`), so this only resolves
    /// when it actually looks like an absolute path. Not what gates a finding out of
    /// `SizeProbe` — `reclaimPaths` does that (empty `reclaimPaths` means nothing is ever
    /// sized, regardless of what `path`/`pathURL` hold). No production caller today; kept
    /// as a general-purpose accessor for future UI use (e.g. reveal-in-Finder).
    public var pathURL: URL? {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : nil
    }
}
