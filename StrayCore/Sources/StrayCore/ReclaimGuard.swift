import Foundation

/// Tracks which reclaims are currently in flight, so a path can't be reclaimed twice.
///
/// `FindingRow`'s confirm button stays rendered until the row is removed, and removal
/// only happens after the blocking Reclaimer call returns, so a second tap before that
/// would otherwise fire a second `Reclaimer.trash` on an already-trashed path.
///
/// Extracted from `ScanEngine` because this is pure set bookkeeping with a subtle
/// identity rule (below) and no dependency on scanning, publishing, or the filesystem.
/// Keeping it separate means the rule can be stated and tested once, rather than being
/// re-derived from `ScanEngine`'s async reclaim paths.
///
/// Findings are keyed on the *set* of their identity paths, not on `Finding.id` or on the
/// single display `path`:
/// - Not `id`: a rescan replaces `diskFindings` wholesale with fresh `Finding` values
///   carrying new UUIDs, so an id-keyed guard misses a reappeared row entirely.
/// - Not the display `path` alone: `ScanEngine.cacheFinding` picks whichever of
///   `reclaimPaths` exists first as the display `path`, so a reclaim that trashes the
///   first of two paths (e.g. the Yarn entry, backed by two possible locations) and then
///   races a rescan can see the row reappear with the *second* path as its new display
///   `path`. A guard keyed only on that would miss that it is the same in-flight reclaim.
///
/// Keying on the union of `reclaimPaths` and `path` closes both: the original and the
/// reappeared row's identity sets share at least the paths still being (or already)
/// trashed.
struct ReclaimGuard {
    private var inFlight: Set<String> = []

    /// A finding's identity for guarding purposes: the union of every path a reclaim of
    /// it will actually touch (`reclaimPaths`) and its display `path`. For a single-path
    /// finding (project junk, or a single-path cache entry) this is one element and
    /// behaves exactly like matching on `path` alone.
    static func keys(for finding: Finding) -> Set<String> {
        Set(finding.reclaimPaths.map(\.path)).union([finding.path])
    }

    /// Marks `finding`'s reclaim as in flight, or refuses if any of its identity keys
    /// already are — the double-confirm guard. Returns `false` (having done nothing) if
    /// blocked; the caller must eventually call `end(_:)` on both the success and failure
    /// paths of whatever it does after a `true` return.
    mutating func begin(_ finding: Finding) -> Bool {
        let keys = Self.keys(for: finding)
        guard inFlight.isDisjoint(with: keys) else { return false }
        inFlight.formUnion(keys)
        return true
    }

    mutating func end(_ finding: Finding) {
        inFlight.subtract(Self.keys(for: finding))
    }
}
