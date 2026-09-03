import Foundation

enum ReclaimError: Error, Equatable {
    case isHome
    case outsideHome
    case isScanRoot
    case commandFailed(Int32)
}

extension ReclaimError: LocalizedError {
    /// Human-readable text for `ScanEngine.lastError`, which renders this directly in
    /// the panel — without this, a failure would show the raw enum case (e.g.
    /// `commandFailed(-1)`) instead of an English sentence.
    var errorDescription: String? {
        switch self {
        case .isHome:
            return "Refused to remove the home directory itself."
        case .outsideHome:
            return "Refused to remove a path outside the home directory."
        case .isScanRoot:
            return "Refused to remove a directory that contains a protected scan root."
        case .commandFailed(let status):
            return "The command failed (exit code \(status))."
        }
    }
}

/// The only code in the app allowed to delete anything on disk.
/// Every public action that takes a path routes through `assertSafe` first; `emptyTrash`
/// takes no path and delegates to Finder.
enum Reclaimer {

    /// Rejects anything that is not a disposable path strictly inside the user's home:
    /// home itself, anything outside home (after resolving symlinks), and any directory
    /// that contains a configured scan root.
    static func assertSafe(_ url: URL, scanRoots: [URL]) throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
            .resolvingSymlinksInPath().standardizedFileURL
        let target = resolvedPath(for: url)

        guard target.path != home.path else { throw ReclaimError.isHome }
        guard target.path.hasPrefix(home.path + "/") else { throw ReclaimError.outsideHome }

        for root in scanRoots {
            let root = resolvedPath(for: root)
            if root.path == target.path || root.path.hasPrefix(target.path + "/") {
                throw ReclaimError.isScanRoot
            }
        }
    }

    /// Resolves symlinks in `url`, including when the final path component (or several
    /// trailing components) do not exist on disk.
    ///
    /// `URL.resolvingSymlinksInPath()` alone only resolves as far as the last *existing*
    /// ancestor: if the leaf does not exist, resolution stops short and a symlinked
    /// ancestor further up the chain is never followed. That would let a path like
    /// `~/link-to-etc/does-not-exist-yet` slip past the guard even though it really
    /// resolves to `/etc/does-not-exist-yet`. To avoid that, walk up to the longest
    /// existing prefix, resolve symlinks only on that prefix, then re-append the
    /// non-existent trailing components unresolved (there is nothing to resolve on a
    /// path segment that doesn't exist).
    private static func resolvedPath(for url: URL) -> URL {
        let fm = FileManager.default
        var existing = url.standardizedFileURL
        var trailing: [String] = []

        while existing.path != "/" && !fm.fileExists(atPath: existing.path) {
            trailing.append(existing.lastPathComponent)
            existing = existing.deletingLastPathComponent()
        }

        var resolved = existing.resolvingSymlinksInPath().standardizedFileURL
        for component in trailing.reversed() {
            resolved.appendPathComponent(component)
        }
        return resolved.standardizedFileURL
    }

    /// Move to Trash. Reversible until the Trash is emptied.
    ///
    /// Blocks on Foundation's file-coordination machinery; call this off the main actor.
    static func trash(_ url: URL, scanRoots: [URL]) throws {
        try assertSafe(url, scanRoots: scanRoots)
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// Removes simulator runtimes with no matching Xcode. Configured devices are user
    /// data and are left alone, so this never goes through `trash`.
    ///
    /// Blocks for as long as `simctl` runs, routinely tens of seconds; call this off the
    /// main actor. Given a 300s timeout (rather than `run`'s 30s default) precisely
    /// because "routinely tens of seconds" leaves little margin under 30s — a timeout
    /// here SIGTERMs a command that may have been working and may have partially
    /// completed, surfacing a false error.
    static func simctlDeleteUnavailable() throws {
        try run("/usr/bin/xcrun", ["simctl", "delete", "unavailable"], timeout: 300)
    }

    /// Dangling (untagged) images only. Never `system prune -a`, which also removes
    /// named volumes.
    ///
    /// Blocks for as long as `docker` runs; call this off the main actor.
    static func dockerImagePrune() throws {
        let docker = ["/opt/homebrew/bin/docker", "/usr/local/bin/docker"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let docker else { throw ReclaimError.commandFailed(-1) }
        try run(docker, ["image", "prune", "-f"])
    }

    /// Empties the Trash by asking Finder to do it.
    ///
    /// `~/.Trash` is TCC-protected: reading or enumerating it requires Full Disk Access,
    /// which this app deliberately does not request. Finder already holds that access, so
    /// delegating costs only a one-time Automation prompt instead of blanket disk access.
    /// Verified on this machine: `contentsOfDirectory` on `~/.Trash` fails with EPERM
    /// (NSCocoaErrorDomain 257) for a process without FDA. Sending this Apple event requires
    /// the `com.apple.security.automation.apple-events` entitlement plus
    /// `NSAppleEventsUsageDescription` under the hardened runtime this app builds with —
    /// without both, the send is refused with `errAEEventNotPermitted` and no prompt is ever
    /// shown.
    ///
    /// There is deliberately no `trashSize()` — reporting the Trash's size would require
    /// the FDA grant this design avoids.
    ///
    /// Goes through `osascript` rather than `NSAppleScript` directly: `NSAppleScript` is
    /// main-thread-affine, which conflicts with this method's off-main-actor contract (and
    /// its caller, `ScanEngine`, is itself `@MainActor`, so an in-process call would block
    /// the UI instead). `osascript` also inherits `run`'s bounded wait and status
    /// propagation, whereas `executeAndReturnError` has no timeout of its own and defaults
    /// to the ~2 minute Apple Event timeout.
    ///
    /// Blocks for as long as `osascript` runs, bounded to 300s (rather than `run`'s 30s
    /// default) because this call can legitimately sit blocked for a long time with no
    /// error: `osascript` blocks while Finder's confirmation dialog is up (a default
    /// macOS setting) or while a large Trash empties, and a timeout here SIGTERMs the
    /// command and surfaces a false error for an operation that may have been working and
    /// may have partially completed. Call this off the main actor.
    static func emptyTrash() throws {
        try run("/usr/bin/osascript", ["-e", "tell application \"Finder\" to empty trash"], timeout: 300)
    }

    /// `timeout` defaults to 30s for short-lived commands; callers whose underlying
    /// command can legitimately run much longer (`simctlDeleteUnavailable`, `emptyTrash`)
    /// pass a longer bound explicitly rather than eating a false timeout error.
    /// How long a timed-out command gets to honour SIGTERM before it is
    /// SIGKILLed. Short: by this point the command has already overrun its
    /// full timeout, so it is not about to exit politely.
    private static let terminationGrace: TimeInterval = 2

    /// Internal rather than private so the timeout-escalation path can be
    /// tested against a command that deliberately ignores SIGTERM. Reaching it
    /// through `simctlDeleteUnavailable` or `emptyTrash` would mean actually
    /// hanging one of those for 300s.
    static func run(_ launchPath: String, _ arguments: [String], timeout: TimeInterval = 30) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            throw ReclaimError.commandFailed(-1)
        }

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            // Escalate rather than assuming SIGTERM was honoured. Both callers
            // run Apple tools that do honour it, so in practice the terminate
            // above is enough - but this path is only reached when a command
            // has already misbehaved by overrunning a 300s bound, which is
            // exactly when that assumption is least safe. Without this, such a
            // command keeps running after the error is surfaced and the row is
            // gone from the UI: invisible, and still mutating the disk it was
            // told to stop touching.
            //
            // Bounded so this can never become the hang it is guarding against;
            // SIGKILL cannot be caught, so the wait after it always returns.
            let deadline = Date().addingTimeInterval(terminationGrace)
            while process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            throw ReclaimError.commandFailed(-1)
        }

        guard process.terminationStatus == 0 else {
            throw ReclaimError.commandFailed(process.terminationStatus)
        }
    }
}
