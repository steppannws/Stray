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

@Test func sizesRunConcurrentlyUpToTheCap() async throws {
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

    // `size(of:)` is effectively instant for these tiny fixtures, so nearly all of a
    // task's real lifetime is spent inside this callback. Rather than inferring
    // concurrency from wall-clock timing (a fixed sleep duration is flaky by
    // construction on a CPU-constrained machine: `Thread.sleep` blocks a cooperative-pool
    // worker instead of suspending it, and a small/busy pool may never let tasks overlap
    // within the sleep window even though `sizes(for:)` is behaving correctly), each
    // callback blocks on a semaphore until `concurrencyCap` callbacks are simultaneously
    // in flight. Reaching that rendezvous deterministically proves real overlap
    // regardless of machine speed; a generous timeout turns "the cap is never reached at
    // all" (e.g. a sequential implementation) into a test failure instead of a hang.
    let box = ResultBox(concurrencyCap: 4)
    await SizeProbe.sizes(for: dirs) { url, bytes in
        box.rendezvous(url, bytes)
    }

    #expect(box.count == 12)
    // Proves the four-way rendezvous was actually reached, not just inferred.
    #expect(!box.timedOut)
    // Proves the work is actually concurrent, not sequential.
    #expect(box.peakInFlight > 1)
    // Proves the concurrency cap holds.
    #expect(box.peakInFlight <= 4)
}

/// Small thread-safe collector so the async callback can be asserted on.
final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [URL: Int64] = [:]
    private var inFlight = 0
    private var peak = 0
    private var gateOpened = false
    private var gateTimedOut = false
    private let gate = DispatchSemaphore(value: 0)
    private let concurrencyCap: Int

    init(concurrencyCap: Int) {
        self.concurrencyCap = concurrencyCap
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return results.count
    }

    var peakInFlight: Int {
        lock.lock(); defer { lock.unlock() }
        return peak
    }

    var timedOut: Bool {
        lock.lock(); defer { lock.unlock() }
        return gateTimedOut
    }

    /// Records the probe's result and blocks the caller until `concurrencyCap` callbacks
    /// are simultaneously in flight — proving genuine overlap deterministically instead
    /// of inferring it from timing — or until a generous timeout elapses. Once the cap
    /// has been reached once, later calls pass straight through: the rendezvous only
    /// needs to happen once to prove the property.
    func rendezvous(_ url: URL, _ bytes: Int64) {
        lock.lock()
        inFlight += 1
        peak = max(peak, inFlight)
        results[url] = bytes
        let opensGateNow = inFlight >= concurrencyCap && !gateOpened
        if opensGateNow { gateOpened = true }
        let alreadyOpen = gateOpened && !opensGateNow
        lock.unlock()

        if opensGateNow {
            for _ in 0..<(concurrencyCap - 1) { gate.signal() }
        } else if !alreadyOpen {
            if gate.wait(timeout: .now() + 3) == .timedOut {
                lock.lock(); gateTimedOut = true; lock.unlock()
            }
        }

        lock.lock()
        inFlight -= 1
        lock.unlock()
    }
}
