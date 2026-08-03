import Testing
import Foundation
@testable import Stray

// These two functions are `internal` rather than `private` specifically to make this
// file possible: neither needs the filesystem or a real disk scan, so there is no
// reason to defer their correctness to manual QA of the "just wiring" that calls them.

// MARK: - resolve(_:) / resolveCache

@MainActor
@Test func resolvingAToolCacheFindingWithNoMatchingCatalogEntrySurfacesAnError() {
    // `resolveCache`'s catalog join is by title; a title matching no entry must not be a
    // silent no-op. The guard clause runs synchronously before any `Task.detached` is
    // spawned, so this is safe to assert immediately with no async/await.
    let engine = ScanEngine()
    let orphan = Finding(kind: .toolCache, severity: .info, title: "Not a real cache",
                          detail: "d", pid: nil, path: "/tmp/does-not-exist", startedAt: nil)

    engine.resolve(orphan)

    #expect(engine.lastError != nil)
}

// MARK: - applySize / beginSizing

@MainActor
@Test func applySizeUpdatesTheMatchingRowOnceItsOnlyPathReports() {
    let engine = ScanEngine()
    let url = URL(fileURLWithPath: "/tmp/stray-test-\(UUID().uuidString)")
    let finding = Finding(kind: .projectJunk, severity: .info, title: "t", detail: "d",
                           pid: nil, path: url.path, startedAt: nil, reclaimPaths: [url])
    engine.beginSizing(for: [finding])

    engine.applySize(1234, to: url)

    #expect(engine.diskFindings.first?.bytes == 1234)
}

@MainActor
@Test func applySizeIgnoresAPathThatMatchesNoRow() {
    let engine = ScanEngine()
    let url = URL(fileURLWithPath: "/tmp/stray-test-\(UUID().uuidString)")
    let finding = Finding(kind: .projectJunk, severity: .info, title: "t", detail: "d",
                           pid: nil, path: url.path, startedAt: nil, reclaimPaths: [url])
    engine.beginSizing(for: [finding])

    let unrelated = URL(fileURLWithPath: "/tmp/stray-test-unrelated-\(UUID().uuidString)")
    engine.applySize(999, to: unrelated)

    #expect(engine.diskFindings.first?.bytes == nil)
}

@MainActor
@Test func applySizeForARowRemovedSinceTheScanIsANoOp() {
    let engine = ScanEngine()
    let url = URL(fileURLWithPath: "/tmp/stray-test-\(UUID().uuidString)")
    let finding = Finding(kind: .projectJunk, severity: .info, title: "t", detail: "d",
                           pid: nil, path: url.path, startedAt: nil, reclaimPaths: [url])
    engine.beginSizing(for: [finding])
    engine.diskFindings.removeAll() // simulate a reclaim that already removed the row

    engine.applySize(1234, to: url) // must neither crash nor resurrect the row

    #expect(engine.diskFindings.isEmpty)
}

@MainActor
@Test func applySizeOnlyFinalizesBytesOnceEveryReclaimPathHasReported() {
    // The core of the sized-equals-deleted invariant: a cache backed by two on-disk
    // locations (e.g. Yarn) must show the sum of both, not the first one to answer.
    let engine = ScanEngine()
    let urlA = URL(fileURLWithPath: "/tmp/stray-test-a-\(UUID().uuidString)")
    let urlB = URL(fileURLWithPath: "/tmp/stray-test-b-\(UUID().uuidString)")
    let finding = Finding(kind: .toolCache, severity: .info, title: "Yarn cache", detail: "d",
                           pid: nil, path: urlA.path, startedAt: nil, reclaimPaths: [urlA, urlB])
    engine.beginSizing(for: [finding])

    engine.applySize(100, to: urlA)
    #expect(engine.diskFindings.first?.bytes == nil) // only one of two paths in: still unknown

    engine.applySize(50, to: urlB)
    #expect(engine.diskFindings.first?.bytes == 150) // both in: the sum is now final
}

@MainActor
@Test func applySizeSortsDescendingWithATitleTiebreak() {
    let engine = ScanEngine()
    let urlA = URL(fileURLWithPath: "/tmp/stray-test-a-\(UUID().uuidString)")
    let urlB = URL(fileURLWithPath: "/tmp/stray-test-b-\(UUID().uuidString)")
    let small = Finding(kind: .projectJunk, severity: .info, title: "small", detail: "d",
                         pid: nil, path: urlA.path, startedAt: nil, reclaimPaths: [urlA])
    let big = Finding(kind: .projectJunk, severity: .info, title: "big", detail: "d",
                       pid: nil, path: urlB.path, startedAt: nil, reclaimPaths: [urlB])
    engine.beginSizing(for: [small, big])

    engine.applySize(10, to: urlA)
    engine.applySize(1000, to: urlB)

    #expect(engine.diskFindings.map(\.title) == ["big", "small"])
}

@MainActor
@Test func reclaimableBytesSumsOnlyNonNilBytes() {
    let engine = ScanEngine()
    let sizedURL = URL(fileURLWithPath: "/tmp/stray-test-\(UUID().uuidString)")
    let sized = Finding(kind: .projectJunk, severity: .info, title: "a", detail: "d",
                         pid: nil, path: sizedURL.path, startedAt: nil, reclaimPaths: [sizedURL])
    // No reclaimPaths (e.g. a simctl-backed row): never sized, stays nil forever.
    let unsized = Finding(kind: .toolCache, severity: .info, title: "b", detail: "d",
                           pid: nil, path: "test.simctl", startedAt: nil)
    engine.beginSizing(for: [sized, unsized])

    engine.applySize(100, to: sizedURL)

    #expect(engine.reclaimableBytes == 100)
}

// MARK: - cacheFinding path selection

@Test func cacheFindingPicksTheFirstExistingPathWhenTheFirstListedOneIsAbsent() throws {
    let fm = FileManager.default
    let root = fm.homeDirectoryForCurrentUser.appendingPathComponent(".stray-cache-\(UUID().uuidString)")
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
    let root = URL(fileURLWithPath: "/tmp/stray-cache-nonexistent-\(UUID().uuidString)")
    let entry = CacheEntry(id: "test.absent", name: "Test absent cache",
                            paths: [root], reclaim: .trash, regeneratedBy: "test")
    let finding = ScanEngine.cacheFinding(entry)

    #expect(finding.path == root.path)
    #expect(finding.reclaimPaths.isEmpty) // nothing exists, so nothing is sized or reclaimed
}

@Test func cacheFindingWithNoPathsAtAllUsesTheEntryIDAndHasNoPathURL() {
    // Mirrors the real `docker.dangling` catalog entry. `pathURL == nil` is the only
    // thing that keeps this non-path identifier out of `SizeProbe`.
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
    let root = fm.homeDirectoryForCurrentUser.appendingPathComponent(".stray-cache-\(UUID().uuidString)")
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
