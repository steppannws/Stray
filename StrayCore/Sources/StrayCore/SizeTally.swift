import Foundation

/// Accumulates per-path size reports until every path backing a finding has reported.
///
/// A finding is only as "sized" (non-nil `bytes`) once every one of its `reclaimPaths`
/// has reported: summing partial results into `bytes` directly would let a still-growing
/// number look final and be confirmed before all of it is known, understating what the
/// reclaim is about to remove. A cache entry backed by two on-disk locations (e.g. Yarn)
/// is not done sizing until both have reported, and only their sum is ever shown.
///
/// Extracted from `ScanEngine` because it is pure bookkeeping over values, with no
/// reference to the published arrays, the main actor, or the filesystem. That makes the
/// two ordering hazards it defends against (below) directly testable, which matters
/// because both are races that are hard to provoke through `scanDisk()` itself.
struct SizeTally {
    /// Outstanding path count per finding: how many more reports before its total is final.
    private var remaining: [Finding.ID: Int] = [:]
    /// Bytes accumulated so far for findings that have not yet finished reporting.
    private var sums: [Finding.ID: Int64] = [:]

    /// Bumped by every `beginPass(for:)`. Each `scanDisk()` pass captures the generation
    /// current at its start and stamps it on every callback it schedules; a report whose
    /// generation doesn't match the current one is dropped.
    ///
    /// Without this, a sizing pass from a *previous* scan that is still draining its
    /// unstructured `Task { @MainActor }` callbacks when a new scan starts could deliver a
    /// stale report against the new pass's rows. Task ordering is not structurally
    /// guaranteed FIFO, so this closes the gap outright rather than relying on scheduling
    /// behaviour.
    private(set) var generation = 0

    /// Starts a new sizing pass, invalidating any still-draining reports from the previous
    /// one, and arms the expected report count for each finding.
    mutating func beginPass(for findings: [Finding]) {
        generation += 1
        // `uniquingKeysWith` rather than `uniqueKeysWithValues`: the latter traps at
        // runtime on a duplicate `Finding.ID`, which is a crash bug waiting to happen
        // rather than a compile-time guarantee — `Finding.id` is caller-generated
        // (`UUID()`), not validated unique by this initializer.
        remaining = Dictionary(
            findings.map { ($0.id, $0.reclaimPaths.count) },
            uniquingKeysWith: { _, latest in latest }
        )
        sums = [:]
    }

    /// Drops bookkeeping for findings that no longer exist, so a reclaim completing
    /// mid-scan doesn't leave a pending entry behind for a row that has been removed.
    mutating func forget(_ ids: [Finding.ID]) {
        for id in ids {
            remaining[id] = nil
            sums[id] = nil
        }
    }

    /// Records `bytes` against `id`, returning the finding's final total once every one of
    /// its paths has reported, or `nil` while it is still incomplete.
    ///
    /// Returns `nil` for a finding with no entry left in `remaining` — already finalized,
    /// or never eligible — rather than "re-finalizing" it. This is what stops a
    /// late-arriving duplicate report for an already-summed path from overwriting a
    /// correct total with a single path's bytes.
    mutating func report(_ bytes: Int64, for id: Finding.ID) -> Int64? {
        guard let outstanding = remaining[id] else { return nil }

        let sum = (sums[id] ?? 0) + bytes
        guard outstanding - 1 <= 0 else {
            sums[id] = sum
            remaining[id] = outstanding - 1
            return nil
        }

        sums[id] = nil
        remaining[id] = nil
        return sum
    }

    /// Whether `generation` is the pass currently accepting reports.
    func accepts(generation candidate: Int) -> Bool {
        candidate == generation
    }
}
