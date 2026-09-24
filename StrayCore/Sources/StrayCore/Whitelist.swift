import Foundation

/// What the user has told Stray never to flag, plus the MCP patterns they added.
///
/// Three ways to silence something, from broad to narrow:
/// - `ignoredKinds` turns a whole rule off.
/// - `ignoredCommands` drops a process before the rules ever see it, when its command
///   line contains the substring. This is what "never flag this server" writes, keyed on
///   `Finding.ignoreKey` — not on the binary path, which for a node-hosted MCP server is
///   just `node` and would silence every JS process on the machine.
/// - `ignoredPaths` drops a launchd plist or disk finding at that path or anywhere
///   under it.
///
/// Pure value type: `ScanEngine` owns one, `WhitelistStore` persists it, and neither the
/// matching nor the persistence touches the process table or the disk.
public struct Whitelist: Codable, Equatable {
    /// Stored by `FindingKind.rawValue`, so renaming a kind's display string drops any
    /// ignore saved under the old name. Kinds are few and rarely renamed; a separate
    /// stable key for each would be more code than the risk is worth.
    public var ignoredKinds: Set<FindingKind> = []
    public var ignoredCommands: [String] = []
    public var ignoredPaths: [String] = []
    /// Added to the built-in list in `Rules.mcpPatterns`, never replacing it.
    public var extraMCPPatterns: [String] = []

    public init() {}

    /// Whether `process` may be handed to `Rules` at all.
    func allows(_ process: ScannedProcess) -> Bool {
        !ignoredCommands.contains { !$0.isEmpty && process.arguments.contains($0) }
    }

    /// Whether `finding` may be shown. Command ignores are not checked here — they were
    /// applied to the processes before the rules ran — so this covers kinds and paths.
    public func allows(_ finding: Finding) -> Bool {
        guard !ignoredKinds.contains(finding.kind) else { return false }
        // Process findings carry a binary path (`/usr/local/bin/node`), and ignoring that
        // would silence far more than the row the user clicked. Paths only ever apply to
        // findings that are files: launchd plists and disk findings.
        guard finding.pid == nil else { return true }
        return !ignoredPaths.contains { Self.path(finding.path, isUnder: $0) }
    }

    /// Trims every entry, drops empty ones and removes duplicates, keeping first-seen
    /// order. An empty string would match everything: `"abc".contains("")` is true.
    public func normalized() -> Whitelist {
        var copy = self
        copy.ignoredCommands = Self.clean(ignoredCommands)
        // Slash trimmed before cleaning, so "/a/b/" and "/a/b" dedupe to one entry.
        copy.ignoredPaths = Self.clean(ignoredPaths.map {
            Self.trimTrailingSlash($0.trimmingCharacters(in: .whitespacesAndNewlines))
        })
        copy.extraMCPPatterns = Self.clean(extraMCPPatterns)
        return copy
    }

    static func path(_ path: String, isUnder root: String) -> Bool {
        let root = trimTrailingSlash(root)
        guard !root.isEmpty else { return false }
        return path == root || path.hasPrefix(root + "/")
    }

    private static func clean(_ entries: [String]) -> [String] {
        var seen = Set<String>()
        return entries
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func trimTrailingSlash(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}

/// Persists a `Whitelist` as JSON in `UserDefaults`. Tests pass their own suite so they
/// never read or write the user's real list.
public struct WhitelistStore {
    private let defaults: UserDefaults
    private let key = "whitelist"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// An unreadable saved value falls back to an empty list rather than failing: the
    /// worst case is Stray flagging something the user had silenced, which it shows
    /// with evidence and never acts on without a confirm.
    public func load() -> Whitelist {
        guard let data = defaults.data(forKey: key),
              let list = try? JSONDecoder().decode(Whitelist.self, from: data)
        else { return Whitelist() }
        return list.normalized()
    }

    public func save(_ list: Whitelist) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        defaults.set(data, forKey: key)
    }
}
