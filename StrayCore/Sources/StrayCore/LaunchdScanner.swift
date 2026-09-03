import Foundation

enum LaunchdScanner {

    /// v1: user LaunchAgents only (no privileges required).
    /// /Library/LaunchDaemons is left for v2 with a privileged helper.
    static func scanUserAgents() -> [Finding] {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return [] }

        return files
            .filter { $0.pathExtension == "plist" }
            .compactMap { checkAgent(at: $0) }
    }

    private static func checkAgent(at url: URL) -> Finding? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, format: nil) as? [String: Any]
        else { return nil }

        let program = (plist["Program"] as? String)
            ?? (plist["ProgramArguments"] as? [String])?.first
        guard let program, program.hasPrefix("/"),
              !FileManager.default.fileExists(atPath: program)
        else { return nil }

        return Finding(
            kind: .orphanLaunchd,
            severity: .strong,
            title: url.deletingPathExtension().lastPathComponent,
            detail: "Points to a binary that no longer exists: \(program)",
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
