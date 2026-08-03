import Foundation

enum ReclaimError: Error, Equatable {
    case isHome
    case outsideHome
    case isScanRoot
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
        let target = url.resolvingSymlinksInPath().standardizedFileURL

        guard target.path != home.path else { throw ReclaimError.isHome }
        guard target.path.hasPrefix(home.path + "/") else { throw ReclaimError.outsideHome }

        for root in scanRoots {
            let root = root.resolvingSymlinksInPath().standardizedFileURL
            if root.path == target.path || root.path.hasPrefix(target.path + "/") {
                throw ReclaimError.isScanRoot
            }
        }
    }
}
