import Testing
import Foundation
@testable import StrayCore

// Direct tests for the two pieces of bookkeeping extracted from `ScanEngine`. The
// ScanEngine-level tests still cover the same rules through the engine, but these pin the
// rules to the type that owns them and can reach cases that are awkward to provoke via
// `scanDisk()` — notably stale-generation reports, which in production depend on task
// scheduling.

private func finding(path: String, reclaimPaths: [String]) -> Finding {
    Finding(
        kind: .toolCache,
        severity: .info,
        title: "t",
        detail: "d",
        pid: nil,
        path: path,
        startedAt: nil,
        reclaimPaths: reclaimPaths.map { URL(fileURLWithPath: $0) }
    )
}

// MARK: - ReclaimGuard

@Test func guardBlocksASecondBeginForTheSameFinding() {
    var g = ReclaimGuard()
    let f = finding(path: "/a", reclaimPaths: ["/a"])

    let first = g.begin(f)
    let second = g.begin(f)
    #expect(first)
    #expect(!second)
}

@Test func guardAllowsBeginAgainAfterEnd() {
    var g = ReclaimGuard()
    let f = finding(path: "/a", reclaimPaths: ["/a"])

    let first = g.begin(f)
    g.end(f)
    let afterEnd = g.begin(f)
    #expect(first)
    #expect(afterEnd, "ending the reclaim must clear every key it claimed")
}

@Test func guardBlocksARowWhoseDisplayPathShiftedToAnotherReclaimPath() {
    // The Yarn-style case the identity-set keying exists for: a rescan can bring the row
    // back with the *second* of its two locations as the display path, and that must
    // still be recognized as the same in-flight reclaim.
    var g = ReclaimGuard()
    let original = finding(path: "/one", reclaimPaths: ["/one", "/two"])
    let reappeared = finding(path: "/two", reclaimPaths: ["/two"])

    let first = g.begin(original)
    let second = g.begin(reappeared)
    #expect(first)
    #expect(!second, "shared reclaim path /two must block the second confirm")
}

@Test func guardTreatsFindingsWithNoOverlappingPathsAsIndependent() {
    var g = ReclaimGuard()
    let a = g.begin(finding(path: "/a", reclaimPaths: ["/a"]))
    let b = g.begin(finding(path: "/b", reclaimPaths: ["/b"]))
    #expect(a)
    #expect(b, "unrelated reclaims must not block each other")
}

// MARK: - SizeTally

@Test func tallyFinalizesASinglePathFindingOnItsFirstReport() {
    var t = SizeTally()
    let f = finding(path: "/a", reclaimPaths: ["/a"])
    t.beginPass(for: [f])

    let total = t.report(100, for: f.id)
    #expect(total == 100)
}

@Test func tallyWithholdsATotalUntilEveryPathHasReported() {
    var t = SizeTally()
    let f = finding(path: "/a", reclaimPaths: ["/a", "/b"])
    t.beginPass(for: [f])

    let partial = t.report(100, for: f.id)
    let total = t.report(50, for: f.id)
    #expect(partial == nil, "a partial sum must never be published as final")
    #expect(total == 150, "the finalized total is the sum of every path")
}

@Test func tallyIgnoresALateDuplicateReportForAnAlreadyFinalizedFinding() {
    // Without this, a duplicate of an already-summed path would overwrite the correct
    // total with just that one path's bytes.
    var t = SizeTally()
    let f = finding(path: "/a", reclaimPaths: ["/a"])
    t.beginPass(for: [f])

    let firstTotal = t.report(100, for: f.id)
    let duplicate = t.report(7, for: f.id)
    #expect(firstTotal == 100)
    #expect(duplicate == nil, "a finding is finalized exactly once")
}

@Test func tallyIgnoresAReportForAnUnknownFinding() {
    var t = SizeTally()
    t.beginPass(for: [])
    let result = t.report(100, for: UUID())
    #expect(result == nil)
}

@Test func tallyRejectsReportsFromASupersededPass() {
    // The stale-generation guard: a previous scan's callbacks can still be draining when
    // a new pass starts, and task ordering is not guaranteed FIFO.
    var t = SizeTally()
    t.beginPass(for: [])
    let stale = t.generation
    t.beginPass(for: [])

    #expect(!t.accepts(generation: stale), "a superseded pass must not be able to report")
    #expect(t.accepts(generation: t.generation))
}

@Test func tallyForgetsBookkeepingForRemovedFindings() {
    // A reclaim completing mid-scan removes the row; its pending entry must go with it,
    // so a later report cannot resurrect a total for a row that no longer exists.
    var t = SizeTally()
    let f = finding(path: "/a", reclaimPaths: ["/a", "/b"])
    t.beginPass(for: [f])

    let partial = t.report(100, for: f.id)
    t.forget([f.id])
    let afterForget = t.report(50, for: f.id)
    #expect(partial == nil)
    #expect(afterForget == nil, "a forgotten finding must never finalize")
}

@Test func tallySurvivesDuplicateFindingIDsInAPass() {
    // `Finding.id` is caller-generated and not validated unique, so building the pending
    // map must not trap the way `uniqueKeysWithValues` would.
    var t = SizeTally()
    let f = finding(path: "/a", reclaimPaths: ["/a"])
    t.beginPass(for: [f, f])

    let total = t.report(10, for: f.id)
    #expect(total == 10)
}
