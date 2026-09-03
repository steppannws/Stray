import Testing
import Foundation
@testable import StrayCore

// `applySize`, `beginSizing`, `removeDiskFinding`, `beginReclaim`/`endReclaim`,
// `trashAll`, and `cacheFinding` are `internal` rather than `private` specifically to
// make this file possible: none of them need the filesystem or a real disk scan (in
// particular, `beginReclaim`/`endReclaim` let the in-flight guard be tested without
// invoking a real Reclaimer call, and `trashAll`'s empty-list guard is testable
// synchronously with no `Task` since it throws before ever calling `Reclaimer.trash`),
// so there is no reason to defer their correctness to manual QA of the "just wiring"
// that calls them.
//
// `ScanEngine(startTimer: false)` is used throughout instead of the production
// `ScanEngine()` so these tests don't each start a live process scan and leave an
// un-invalidated 5-minute repeating `Timer` running past the test's lifetime.

// MARK: - trashAll

@Test func trashAllThrowsOnAnEmptyPathList() {
    // `reclaimPaths` defaults to `[]`; without this guard, `trashAll` would return
    // cleanly on an empty list and the caller would treat that as a successful reclaim
    // that deleted nothing. `(any Error).self` avoids needing to expose the (private)
    // error type this throws.
    #expect(throws: (any Error).self) {
        try ScanEngine.trashAll([], scanRoots: [])
    }
}

// MARK: - resolve(_:) / resolveCache

@MainActor
@Test func resolvingAToolCacheFindingWithNoMatchingCatalogEntrySurfacesAnError() {
    // `resolveCache`'s catalog join is by title; a title matching no entry must not be a
    // silent no-op. The guard clause runs synchronously before any `Task.detached` is
    // spawned, so this is safe to assert immediately with no async/await.
    let engine = ScanEngine(startTimer: false)
    let orphan = Finding(kind: .toolCache, severity: .info, title: "Not a real cache",
                          detail: "d", pid: nil, path: "/tmp/does-not-exist", startedAt: nil)

    engine.resolve(orphan)

    #expect(engine.lastError != nil)
}

// MARK: - beginSizing / removeDiskFinding

@MainActor
@Test func removeDiskFindingMatchesAcrossARescanByPath() {
    // Models finding 6: a reclaim in flight for `original` completes after a rescan has
    // already replaced `diskFindings` with a fresh `Finding` for the same path but a new
    // id. The completing reclaim only ever knows the *original* value, so removal must
    // still find the (differently-UUID'd) row by path.
    //
    // Also seeds an unrelated row (`untouched`) and asserts it survives: with only one
    // row seeded, `diskFindings.isEmpty` after removal is satisfied just as well by an
    // over-broad `removeAll { true }`, so that assertion alone can't tell a correct
    // matcher from one that deletes everything.
    let engine = ScanEngine(startTimer: false)
    let url = URL(fileURLWithPath: "/tmp/stray-test-\(UUID().uuidString)")
    let original = Finding(kind: .projectJunk, severity: .info, title: "t", detail: "d",
                            pid: nil, path: url.path, startedAt: nil, reclaimPaths: [url])
    let untouchedURL = URL(fileURLWithPath: "/tmp/stray-test-untouched-\(UUID().uuidString)")
    let untouched = Finding(kind: .projectJunk, severity: .info, title: "untouched", detail: "d",
                             pid: nil, path: untouchedURL.path, startedAt: nil, reclaimPaths: [untouchedURL])
    engine.beginSizing(for: [original, untouched])

    let rescanned = Finding(kind: .projectJunk, severity: .info, title: "t", detail: "d",
                             pid: nil, path: url.path, startedAt: nil, reclaimPaths: [url])
    engine.beginSizing(for: [rescanned, untouched]) // simulates the rescan; `rescanned.id != original.id`

    engine.removeDiskFinding(original)

    #expect(engine.diskFindings.map(\.id) == [untouched.id])
}

@MainActor
@Test func removeDiskFindingRemovesARowThatReappearedUnderADifferentDisplayPath() {
    // The multi-path variant of finding 6, reported as an Important in round 3: a
    // reclaim starts on `original` (display path = urlX, one of two reclaim paths). By
    // the time it completes, a rescan has landed mid-reclaim (urlX already trashed, urlY
    // still present) and replaced the row with `reappeared`, whose display path is now
    // urlY — a *different* string from `original.path`, and a different id. Matching on
    // id-or-path alone (the round-1/2 fix) would miss this; matching when `reclaimPaths`
    // intersect must still find it.
    //
    // Also seeds an unrelated row (`untouched`, non-intersecting `reclaimPaths`) and
    // asserts it survives — round 3's added `reclaimPaths`-intersection clause widened
    // the matcher, which is exactly the kind of change an `isEmpty`-only assertion can't
    // catch over-matching in.
    let engine = ScanEngine(startTimer: false)
    let urlX = URL(fileURLWithPath: "/tmp/stray-test-x-\(UUID().uuidString)")
    let urlY = URL(fileURLWithPath: "/tmp/stray-test-y-\(UUID().uuidString)")
    let original = Finding(kind: .toolCache, severity: .info, title: "Yarn cache", detail: "d",
                            pid: nil, path: urlX.path, startedAt: nil, reclaimPaths: [urlX, urlY])
    let reappeared = Finding(kind: .toolCache, severity: .info, title: "Yarn cache", detail: "d",
                              pid: nil, path: urlY.path, startedAt: nil, reclaimPaths: [urlY])
    let untouchedURL = URL(fileURLWithPath: "/tmp/stray-test-untouched-\(UUID().uuidString)")
    let untouched = Finding(kind: .toolCache, severity: .info, title: "Untouched cache", detail: "d",
                             pid: nil, path: untouchedURL.path, startedAt: nil, reclaimPaths: [untouchedURL])
    engine.beginSizing(for: [reappeared, untouched]) // simulates the rescan replacing diskFindings

    engine.removeDiskFinding(original) // the completing reclaim only knows `original`

    #expect(engine.diskFindings.map(\.id) == [untouched.id])
}

// MARK: - beginReclaim / endReclaim

@MainActor
@Test func beginReclaimBlocksASecondConfirmWhenTheDisplayPathHasShiftedToAnotherReclaimPath() {
    // The other half of the same round-3 scenario: while `original`'s reclaim is in
    // flight (urlX display path, urlX+urlY reclaim paths), a rescan lands and the row
    // reappears with urlY as its new display path. Confirming the reappeared row must
    // still be blocked — a guard keyed only on the display path would miss this, since
    // "urlY" was never itself inserted as the sole in-flight key by the first confirm
    // (it's only in-flight as part of `original`'s multi-path identity set).
    let engine = ScanEngine(startTimer: false)
    let urlX = URL(fileURLWithPath: "/tmp/stray-test-x-\(UUID().uuidString)")
    let urlY = URL(fileURLWithPath: "/tmp/stray-test-y-\(UUID().uuidString)")
    let original = Finding(kind: .toolCache, severity: .info, title: "Yarn cache", detail: "d",
                            pid: nil, path: urlX.path, startedAt: nil, reclaimPaths: [urlX, urlY])
    let reappeared = Finding(kind: .toolCache, severity: .info, title: "Yarn cache", detail: "d",
                              pid: nil, path: urlY.path, startedAt: nil, reclaimPaths: [urlY])

    #expect(engine.beginReclaim(for: original)) // first confirm: proceeds

    #expect(!engine.beginReclaim(for: reappeared)) // second confirm on the reappeared row: blocked
}

@MainActor
@Test func endReclaimClearsEveryIdentityKeySoAFutureConfirmForTheSamePathIsAllowedAgain() {
    let engine = ScanEngine(startTimer: false)
    let urlX = URL(fileURLWithPath: "/tmp/stray-test-x-\(UUID().uuidString)")
    let urlY = URL(fileURLWithPath: "/tmp/stray-test-y-\(UUID().uuidString)")
    let finding = Finding(kind: .toolCache, severity: .info, title: "Yarn cache", detail: "d",
                           pid: nil, path: urlX.path, startedAt: nil, reclaimPaths: [urlX, urlY])

    #expect(engine.beginReclaim(for: finding))
    engine.endReclaim(for: finding)

    #expect(engine.beginReclaim(for: finding)) // cleared: a later confirm is allowed again
}

// MARK: - applySize

@MainActor
@Test func applySizeUpdatesTheMatchingRowOnceItsOnlyPathReports() {
    let engine = ScanEngine(startTimer: false)
    let url = URL(fileURLWithPath: "/tmp/stray-test-\(UUID().uuidString)")
    let finding = Finding(kind: .projectJunk, severity: .info, title: "t", detail: "d",
                           pid: nil, path: url.path, startedAt: nil, reclaimPaths: [url])
    engine.beginSizing(for: [finding])

    engine.applySize(1234, to: url, generation: engine.sizingGeneration)

    #expect(engine.diskFindings.first?.bytes == 1234)
}

@MainActor
@Test func applySizeIgnoresAPathThatMatchesNoRow() {
    let engine = ScanEngine(startTimer: false)
    let url = URL(fileURLWithPath: "/tmp/stray-test-\(UUID().uuidString)")
    let finding = Finding(kind: .projectJunk, severity: .info, title: "t", detail: "d",
                           pid: nil, path: url.path, startedAt: nil, reclaimPaths: [url])
    engine.beginSizing(for: [finding])

    let unrelated = URL(fileURLWithPath: "/tmp/stray-test-unrelated-\(UUID().uuidString)")
    engine.applySize(999, to: unrelated, generation: engine.sizingGeneration)

    #expect(engine.diskFindings.first?.bytes == nil)
}

@MainActor
@Test func applySizeForARemovedRowIsANoOpAndDoesNotAffectOtherRows() {
    // A stronger version of "removed row is a no-op": proves both that the removed row
    // isn't resurrected/doesn't crash, and that a still-present row is unaffected and
    // continues to size normally in the same batch.
    let engine = ScanEngine(startTimer: false)
    let urlA = URL(fileURLWithPath: "/tmp/stray-test-a-\(UUID().uuidString)")
    let urlB = URL(fileURLWithPath: "/tmp/stray-test-b-\(UUID().uuidString)")
    let findingA = Finding(kind: .projectJunk, severity: .info, title: "a", detail: "d",
                            pid: nil, path: urlA.path, startedAt: nil, reclaimPaths: [urlA])
    let findingB = Finding(kind: .projectJunk, severity: .info, title: "b", detail: "d",
                            pid: nil, path: urlB.path, startedAt: nil, reclaimPaths: [urlB])
    engine.beginSizing(for: [findingA, findingB])
    engine.removeDiskFinding(findingA) // simulate a reclaim of A completing mid-scan

    engine.applySize(999, to: urlA, generation: engine.sizingGeneration) // late report for the removed row
    engine.applySize(50, to: urlB, generation: engine.sizingGeneration)

    #expect(engine.diskFindings.map(\.title) == ["b"])
    #expect(engine.diskFindings.first?.bytes == 50)
}

@MainActor
@Test func applySizeOnlyFinalizesBytesOnceEveryReclaimPathHasReported() {
    // The core of the sized-equals-deleted invariant: a cache backed by two on-disk
    // locations (e.g. Yarn) must show the sum of both, not the first one to answer.
    let engine = ScanEngine(startTimer: false)
    let urlA = URL(fileURLWithPath: "/tmp/stray-test-a-\(UUID().uuidString)")
    let urlB = URL(fileURLWithPath: "/tmp/stray-test-b-\(UUID().uuidString)")
    let finding = Finding(kind: .toolCache, severity: .info, title: "Yarn cache", detail: "d",
                           pid: nil, path: urlA.path, startedAt: nil, reclaimPaths: [urlA, urlB])
    engine.beginSizing(for: [finding])

    engine.applySize(100, to: urlA, generation: engine.sizingGeneration)
    #expect(engine.diskFindings.first?.bytes == nil) // only one of two paths in: still unknown

    engine.applySize(50, to: urlB, generation: engine.sizingGeneration)
    #expect(engine.diskFindings.first?.bytes == 150) // both in: the sum is now final
}

@MainActor
@Test func applySizeIgnoresALateOrDuplicateReportForAnAlreadyFinalizedRow() {
    // N2(a): re-finalizing on a second report for the same (already-complete) path used
    // to overwrite the correct sum with a single path's bytes, understating what the
    // reclaim button would actually remove.
    let engine = ScanEngine(startTimer: false)
    let url = URL(fileURLWithPath: "/tmp/stray-test-\(UUID().uuidString)")
    let finding = Finding(kind: .projectJunk, severity: .info, title: "t", detail: "d",
                           pid: nil, path: url.path, startedAt: nil, reclaimPaths: [url])
    engine.beginSizing(for: [finding])

    engine.applySize(100, to: url, generation: engine.sizingGeneration) // finalizes at 100
    engine.applySize(999, to: url, generation: engine.sizingGeneration) // late duplicate

    #expect(engine.diskFindings.first?.bytes == 100)
}

@MainActor
@Test func applySizeDropsAReportFromAStaleSizingGeneration() {
    // N2(b): a report tagged with an earlier `scanDisk()` pass's generation must be
    // dropped even though it targets a path a *current* row also happens to use — this
    // is what keeps a slow-draining previous pass from corrupting the current one when
    // task ordering isn't structurally guaranteed.
    let engine = ScanEngine(startTimer: false)
    let url = URL(fileURLWithPath: "/tmp/stray-test-\(UUID().uuidString)")
    let finding = Finding(kind: .projectJunk, severity: .info, title: "t", detail: "d",
                           pid: nil, path: url.path, startedAt: nil, reclaimPaths: [url])

    engine.beginSizing(for: [finding])
    let staleGeneration = engine.sizingGeneration
    engine.beginSizing(for: [finding]) // a second pass starts; generation advances

    engine.applySize(500, to: url, generation: staleGeneration)

    #expect(engine.diskFindings.first?.bytes == nil) // dropped, not applied
}

@MainActor
@Test func applySizeSortsDescendingWithATitleTiebreakOnEqualSizes() {
    // Must actually exercise a tie: two rows with equal (non-nil) bytes, and two more
    // with equal nil bytes, both seeded in reverse-title order. Deleting the tiebreak
    // from `sortDiskFindings` must make this fail.
    let engine = ScanEngine(startTimer: false)
    let urlZ = URL(fileURLWithPath: "/tmp/stray-test-z-\(UUID().uuidString)")
    let urlA = URL(fileURLWithPath: "/tmp/stray-test-a-\(UUID().uuidString)")
    let sizedZ = Finding(kind: .projectJunk, severity: .info, title: "z-sized", detail: "d",
                          pid: nil, path: urlZ.path, startedAt: nil, reclaimPaths: [urlZ])
    let sizedA = Finding(kind: .projectJunk, severity: .info, title: "a-sized", detail: "d",
                          pid: nil, path: urlA.path, startedAt: nil, reclaimPaths: [urlA])
    // No reclaimPaths: bytes stays nil forever, seeded in reverse-title order too.
    let unsizedZ = Finding(kind: .toolCache, severity: .info, title: "z-unsized", detail: "d",
                            pid: nil, path: "test.z-unsized", startedAt: nil)
    let unsizedA = Finding(kind: .toolCache, severity: .info, title: "a-unsized", detail: "d",
                            pid: nil, path: "test.a-unsized", startedAt: nil)
    engine.beginSizing(for: [sizedZ, sizedA, unsizedZ, unsizedA])

    engine.applySize(500, to: urlZ, generation: engine.sizingGeneration)
    engine.applySize(500, to: urlA, generation: engine.sizingGeneration) // equal to the above

    #expect(engine.diskFindings.map(\.title) == ["a-sized", "z-sized", "a-unsized", "z-unsized"])
}

@MainActor
@Test func reclaimableBytesSumsOnlyNonNilBytes() {
    let engine = ScanEngine(startTimer: false)
    let sizedURL = URL(fileURLWithPath: "/tmp/stray-test-\(UUID().uuidString)")
    let sized = Finding(kind: .projectJunk, severity: .info, title: "a", detail: "d",
                         pid: nil, path: sizedURL.path, startedAt: nil, reclaimPaths: [sizedURL])
    // No reclaimPaths (e.g. a simctl-backed row): never sized, stays nil forever.
    let unsized = Finding(kind: .toolCache, severity: .info, title: "b", detail: "d",
                           pid: nil, path: "test.simctl", startedAt: nil)
    engine.beginSizing(for: [sized, unsized])

    engine.applySize(100, to: sizedURL, generation: engine.sizingGeneration)

    #expect(engine.reclaimableBytes == 100)
}

// MARK: - cacheFinding path selection

@Test func cacheFindingPicksTheFirstExistingPathWhenTheFirstListedOneIsAbsent() throws {
    // `cacheFinding` has no home-directory constraint (only `Reclaimer.trash`'s
    // `assertSafe` does), so a plain temp directory is enough here.
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(".stray-cache-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    let missing = root.appendingPathComponent("missing")
    let present = root.appendingPathComponent("present")
    try fm.createDirectory(at: present, withIntermediateDirectories: true)

    let entry = CacheEntry(id: "test.multi", name: "Test multi-path cache",
                            paths: [missing, present], reclaim: .trash, regeneratedBy: "test")
    let finding = ScanEngine.cacheFinding(entry)

    #expect(finding.path == present.path)
    #expect(finding.reclaimPaths == [present])
}

@Test func cacheFindingWithNoExistingPathFallsBackToTheFirstListedPath() {
    // Shouldn't happen via `CacheCatalog.present()` (which filters for existence), but
    // `cacheFinding` itself must still degrade sanely rather than crash or size nothing.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("stray-cache-nonexistent-\(UUID().uuidString)")
    let entry = CacheEntry(id: "test.absent", name: "Test absent cache",
                            paths: [root], reclaim: .trash, regeneratedBy: "test")
    let finding = ScanEngine.cacheFinding(entry)

    #expect(finding.path == root.path)
    #expect(finding.reclaimPaths.isEmpty) // nothing exists, so nothing is sized or reclaimed
}

@Test func cacheFindingWithNoPathsAtAllUsesTheEntryIDAndHasNoPathURL() {
    // Mirrors the real `docker.dangling` catalog entry. `reclaimPaths` (empty here) is
    // what actually keeps this non-path identifier out of `SizeProbe`; `pathURL == nil`
    // is a separate, additional invariant worth holding too.
    let entry = CacheEntry(id: "docker.dangling", name: "Docker dangling images",
                            paths: [], reclaim: .dockerImagePrune, regeneratedBy: "test")
    let finding = ScanEngine.cacheFinding(entry)

    #expect(finding.path == "docker.dangling")
    #expect(finding.pathURL == nil)
    #expect(finding.reclaimPaths.isEmpty)
}

@Test func cacheFindingLeavesReclaimPathsEmptyForNonTrashMethodsEvenWhenThePathExists() throws {
    // Mirrors `xcode.simulators`: a huge, mostly-active directory reclaimed by a command
    // (`simctl delete unavailable`) that only removes an orphaned subset of it. Sizing
    // the whole directory would grossly overstate what the button actually frees.
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(".stray-cache-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }

    let entry = CacheEntry(id: "test.simctl", name: "Test simctl-backed entry",
                            paths: [root], reclaim: .simctlDeleteUnavailable, regeneratedBy: "test")
    let finding = ScanEngine.cacheFinding(entry)

    #expect(finding.reclaimPaths.isEmpty)
    #expect(finding.bytes == nil)
}

// MARK: - Pure Finding accessors

@Test func pathURLResolvesOnlyForAbsolutePaths() {
    let real = Finding(kind: .projectJunk, severity: .info, title: "a", detail: "d",
                        pid: nil, path: "/tmp/real", startedAt: nil)
    let identifier = Finding(kind: .toolCache, severity: .info, title: "b", detail: "d",
                              pid: nil, path: "docker.dangling", startedAt: nil)

    #expect(real.pathURL == URL(fileURLWithPath: "/tmp/real"))
    #expect(identifier.pathURL == nil)
}

@Test func sizeDescriptionIsAnEmDashOnlyWhileBytesIsNil() {
    let unsized = Finding(kind: .toolCache, severity: .info, title: "a", detail: "d",
                           pid: nil, path: "/tmp/a", startedAt: nil, bytes: nil)
    let sized = Finding(kind: .toolCache, severity: .info, title: "b", detail: "d",
                         pid: nil, path: "/tmp/b", startedAt: nil, bytes: 1_048_576)

    #expect(unsized.sizeDescription == "—")
    #expect(sized.sizeDescription != "—")
    #expect(!sized.sizeDescription.isEmpty)
}
