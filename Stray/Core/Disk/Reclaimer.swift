import Foundation

enum ReclaimError: Error, Equatable {
    case isHome
    case outsideHome
    case isScanRoot
    case commandFailed(Int32)
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
    /// main actor.
    static func simctlDeleteUnavailable() throws {
        try run("/usr/bin/xcrun", ["simctl", "delete", "unavailable"])
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
    /// the UI instead). `osascript` also inherits `run`'s bounded 30-second wait and status
    /// propagation, whereas `executeAndReturnError` has no timeout of its own and defaults
    /// to the ~2 minute Apple Event timeout.
    ///
    /// Blocks for as long as `osascript` runs (bounded to 30s by `run`); call this off the
    /// main actor.
    static func emptyTrash() throws {
        try run("/usr/bin/osascript", ["-e", "tell application \"Finder\" to empty trash"])
    }

    private static func run(_ launchPath: String, _ arguments: [String]) throws {
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

        if exited.wait(timeout: .now() + 30) == .timedOut {
            process.terminate()
            throw ReclaimError.commandFailed(-1)
        }

        guard process.terminationStatus == 0 else {
            throw ReclaimError.commandFailed(process.terminationStatus)
        }
    }
}
