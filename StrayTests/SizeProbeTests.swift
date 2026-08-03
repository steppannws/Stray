import Testing
import Foundation
@testable import Stray

@Test func sizeCountsFilesInATree() throws {
    let fm = FileManager.default
    let root = fm.homeDirectoryForCurrentUser
        .appendingPathComponent(".stray-size-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    try fm.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)

    let payload = Data(repeating: 0x41, count: 8192)
    try payload.write(to: root.appendingPathComponent("a.bin"))
    try payload.write(to: root.appendingPathComponent("nested/b.bin"))

    // allocated size rounds up to block size, so assert a floor rather than equality
    #expect(SizeProbe.size(of: root) >= 16384)
}

@Test func sizeIgnoresSymlinkTargets() throws {
    let fm = FileManager.default
    let root = fm.homeDirectoryForCurrentUser
        .appendingPathComponent(".stray-size-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    try fm.createDirectory(at: root, withIntermediateDirectories: true)

    let big = root.appendingPathComponent("real.bin")
    try Data(repeating: 0x41, count: 65536).write(to: big)

    let linkDir = root.appendingPathComponent("links")
    try fm.createDirectory(at: linkDir, withIntermediateDirectories: true)
    try fm.createSymbolicLink(at: linkDir.appendingPathComponent("dup"), withDestinationURL: big)

    // the symlink must not add another 64 KB
    #expect(SizeProbe.size(of: root) < 131072)
}

@Test func sizeCountsInsideBundleDirectories() throws {
    let fm = FileManager.default
    let root = fm.homeDirectoryForCurrentUser
        .appendingPathComponent(".stray-size-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }

    // A directory ending in `.app` is a "package" as far as FileManager/LaunchServices
    // is concerned. `.xcarchive` and `.framework` behave the same way.
    let bundleDir = root.appendingPathComponent("Fixture.app/Contents/MacOS")
    try fm.createDirectory(at: bundleDir, withIntermediateDirectories: true)
    try Data(repeating: 0x41, count: 50000).write(to: bundleDir.appendingPathComponent("binary"))

    // With `.skipsPackageDescendants` set, the enumerator treats `Fixture.app` as opaque
    // and never yields anything inside it, so this would total 0. `xcode.archives` is
    // entirely `.xcarchive` packages and `xcode.derived-data` is full of build products
    // inside `.app`/`.framework` bundles, so this has to walk into them.
    #expect(SizeProbe.size(of: root) >= 50000)
}

@Test func sizesRunsConcurrentlyAndStreamsResults() async throws {
    let fm = FileManager.default
    let root = fm.homeDirectoryForCurrentUser
        .appendingPathComponent(".stray-size-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }

    var dirs: [URL] = []
    for i in 0..<12 {
        let d = root.appendingPathComponent("d\(i)")
        try fm.createDirectory(at: d, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 1024).write(to: d.appendingPathComponent("f.bin"))
        dirs.append(d)
    }

    let box = ResultBox()
    let start = Date()

    // `size(of:)` is effectively instant for these tiny fixtures, so nearly all of a
    // task's real lifetime ends up spent inside this callback's artificial delay. That
    // makes "a callback is between beginTask/endTask" a stand-in for "the task group
    // considers this URL's probe still running" — which is exactly the window
    // `sizes(for:)` is supposed to cap at 4 concurrent and report on as it closes.
    // A fully sequential implementation, or one that computes everything first and only
    // then fires all callbacks in a final loop, would never have more than one callback
    // open at a time and would never report a result before the whole call is done —
    // both would fail the assertions below.
    await SizeProbe.sizes(for: dirs) { url, bytes in
        box.beginTask()
        Thread.sleep(forTimeInterval: 0.05)
        box.endTask(url, bytes, elapsed: Date().timeIntervalSince(start))
    }
    let total = Date().timeIntervalSince(start)

    #expect(box.count == 12)

    // Proves the work is actually concurrent, not sequential.
    #expect(box.peakInFlight > 1)
    // Proves the concurrency cap holds.
    #expect(box.peakInFlight <= 4)

    // Proves results are streamed rather than all delivered together at the very end:
    // the earliest completion should land well before the whole call finishes, and
    // completions should be spread out rather than clustered into one instant.
    let timestamps = box.timestamps.sorted()
    let first = try #require(timestamps.first)
    let last = try #require(timestamps.last)
    #expect(first < total * 0.8)
    #expect(last - first > 0.04)
}

/// Small thread-safe collector so the async callback can be asserted on.
final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [URL: Int64] = [:]
    private var inFlight = 0
    private var peak = 0
    private var completionTimestamps: [TimeInterval] = []

    func record(_ url: URL, _ bytes: Int64) {
        lock.lock(); defer { lock.unlock() }
        results[url] = bytes
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return results.count
    }

    /// Marks a simulated probe as started; tracks the running peak of concurrently
    /// open probes.
    func beginTask() {
        lock.lock(); defer { lock.unlock() }
        inFlight += 1
        peak = max(peak, inFlight)
    }

    /// Marks a simulated probe as finished and records its result and completion time.
    func endTask(_ url: URL, _ bytes: Int64, elapsed: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        inFlight -= 1
        results[url] = bytes
        completionTimestamps.append(elapsed)
    }

    var peakInFlight: Int {
        lock.lock(); defer { lock.unlock() }
        return peak
    }

    var timestamps: [TimeInterval] {
        lock.lock(); defer { lock.unlock() }
        return completionTimestamps
    }
}
