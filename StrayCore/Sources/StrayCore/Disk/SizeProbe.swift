import Foundation

/// Computes allocated size for directory trees.
///
/// Symlinks are never resolved: `~/Library/pnpm` and the yarn store are symlink
/// farms, so following them would both double-count and let a later delete escape
/// the intended tree.
enum SizeProbe {

    /// Max simultaneous probes. Disk sizing is I/O bound; more than this thrashes the SSD
    /// without finishing sooner.
    private static let concurrency = 4

    static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        // No `.skipsPackageDescendants`: this probe totals bytes for something about to
        // be deleted, so bundles (`.app`, `.framework`, `.xcarchive`) must be walked in
        // full — skipping their contents would undercount `xcode.archives` and
        // `xcode.derived-data` catalog entries to near zero. `DiskScanner` uses that
        // option deliberately (to avoid false-positive matches inside bundles), but the
        // same option is wrong here.
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else { return 0 }

        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: keys) else { continue }

            // Never follow symlinks when sizing: a symlink farm (pnpm store, yarn cache)
            // would otherwise be double-counted, and this size feeds decisions about
            // deleting the tree, where the same rule applies. This check makes that
            // invariant explicit, matching `DiskScanner`'s handling of symlinks.
            if values.isSymbolicLink == true { continue }

            guard values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Sizes every URL, at most `concurrency` at a time, calling `onResult` as each finishes.
    static func sizes(for urls: [URL], onResult: @Sendable @escaping (URL, Int64) -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            var pending = urls.makeIterator()
            var running = 0

            func addNext() {
                guard let url = pending.next() else { return }
                running += 1
                group.addTask(priority: .utility) {
                    onResult(url, size(of: url))
                }
            }

            for _ in 0..<concurrency { addNext() }
            while running > 0 {
                await group.next()
                running -= 1
                addNext()
            }
        }
    }
}
