import Foundation

enum ReclaimError: Error, Equatable {
    case isHome
    case outsideHome
    case isScanRoot
    case commandFailed(Int32)
}

/// The only code in the app allowed to delete anything on disk.
/// Every public action routes through `assertSafe` first.
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
    static func trash(_ url: URL, scanRoots: [URL]) throws {
        try assertSafe(url, scanRoots: scanRoots)
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// Removes simulator runtimes with no matching Xcode. Configured devices are user
    /// data and are left alone, so this never goes through `trash`.
    static func simctlDeleteUnavailable() throws {
        try run("/usr/bin/xcrun", ["simctl", "delete", "unavailable"])
    }

    /// Dangling (untagged) images only. Never `system prune -a`, which also removes
    /// named volumes.
    static func dockerImagePrune() throws {
        let docker = ["/opt/homebrew/bin/docker", "/usr/local/bin/docker"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let docker else { throw ReclaimError.commandFailed(-1) }
        try run(docker, ["image", "prune", "-f"])
    }

    static func trashSize() -> Int64 {
        let trash = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash")
        guard FileManager.default.fileExists(atPath: trash.path) else { return 0 }
        return SizeProbe.size(of: trash)
    }

    static func emptyTrash() throws {
        let fm = FileManager.default
        let trash = fm.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        for entry in (try? fm.contentsOfDirectory(atPath: trash.path)) ?? [] {
            try? fm.removeItem(at: trash.appendingPathComponent(entry))
        }
    }

    private static func run(_ launchPath: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ReclaimError.commandFailed(process.terminationStatus)
        }
    }
}
