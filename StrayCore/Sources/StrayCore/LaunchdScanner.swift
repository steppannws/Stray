import Foundation

enum LaunchdScanner {

    /// The user's own LaunchAgents; removable without privileges.
    static func scanUserAgents() -> [Finding] {
        scan(FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents"))
    }

    /// `/Library/LaunchDaemons`. The plists are world-readable, so finding orphans needs
    /// no privileges; removing one goes through `StrayHelper` (see `OrphanDaemonPolicy`).
    static func scanSystemDaemons() -> [Finding] {
        scan(URL(fileURLWithPath: OrphanDaemonPolicy.daemonsDirectory), system: true)
    }

    private static func scan(_ dir: URL, system: Bool = false) -> [Finding] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return [] }

        return files
            .filter { $0.pathExtension == "plist" }
            .compactMap { checkAgent(at: $0, system: system) }
    }

    /// The executable a launchd plist starts. Shared with `OrphanDaemonPolicy`, so the
    /// helper's "is it still orphaned?" check is the same rule that flagged it.
    static func program(in plist: [String: Any]) -> String? {
        (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [String])?.first
    }

    private static func checkAgent(at url: URL, system: Bool) -> Finding? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, format: nil) as? [String: Any]
        else { return nil }

        guard let program = program(in: plist), program.hasPrefix("/"),
              !FileManager.default.fileExists(atPath: program)
        else { return nil }

        return Finding(
            kind: .orphanLaunchd,
            severity: .strong,
            title: url.deletingPathExtension().lastPathComponent,
            detail: (system ? "System daemon · " : "")
                + "Points to a binary that no longer exists: \(program)",
            pid: nil,
            path: url.path,
            startedAt: nil
        )
    }

    /// Move the plist to Trash (reversible) and unload it from launchd.
    static func remove(finding: Finding) throws {
        let url = URL(fileURLWithPath: finding.path)
        let label = url.deletingPathExtension().lastPathComponent
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["bootout", "gui/\(getuid())/\(label)"]
        try? p.run(); p.waitUntilExit() // may fail if it was never loaded; fine
        // Routed through `Reclaimer`, not `FileManager.trashItem` directly: `Reclaimer` is
        // documented as "the only code in the app allowed to delete anything on disk" —
        // this URL is always a .plist enumerated from ~/Library/LaunchAgents so `assertSafe`
        // is not a live safety gate here, but bypassing it would falsify that claim.
        try Reclaimer.trash(url, scanRoots: [])
    }
}
