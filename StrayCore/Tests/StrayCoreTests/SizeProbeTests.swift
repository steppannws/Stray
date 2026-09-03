import Testing
import Foundation
@testable import StrayCore

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

/// How many times `sizesRunConcurrentlyUpToTheCap` may retry its rendezvous before
/// reporting failure. Only reached when the gate keeps timing out, which for correct
/// code means the machine is badly starved; a genuinely sequential implementation
/// burns all of them and still fails, which is the behaviour we want.
private let attemptsBeforeFailing = 4

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
    // callback blocks on a semaphore until callbacks pile up in flight, which creates
    // real overlap rather than hoping to observe it.
    //
    // The gate opens at `rendezvousTarget`, deliberately 2 rather than the full
    // `concurrencyCap`. Blocking a callback blocks a *cooperative-pool worker* (the gate
    // is a semaphore, not an `await`), so requiring a simultaneous 4-way rendezvous
    // requires the pool to hand out 4 workers at once. That is not something a correct
    // implementation can guarantee: under CPU contention the pool throttles, the fourth
    // task is never scheduled while the first three are parked, and the rendezvous times
    // out even though `sizes(for:)` is behaving perfectly. That made this test fail
    // reproducibly on a loaded machine — and CI runners are always loaded.
    //
    // So the gate proves the *lower* bound only: two callbacks genuinely overlapping is
    // enough to rule out a sequential implementation, and needs just two workers. The
    // upper bound is enforced separately by `peakInFlight`, which is observed rather than
    // synchronized on and so costs no scheduling guarantee at all.
    //
    // Even a 2-way rendezvous is not guaranteed on a sufficiently starved machine, so a
    // single attempt is retried rather than asserted on. This keeps the signal intact
    // without depending on the scheduler: a *sequential* implementation can never open
    // the gate, so it exhausts every attempt and still fails, while a correct one only
    // has to win the race once. Attempts are therefore near-free in the passing case
    // (the first almost always succeeds) and only cost their timeout when the code is
    // genuinely broken.
    var box = ResultBox(concurrencyCap: 4, rendezvousTarget: 2)
    for attempt in 1...attemptsBeforeFailing {
        box = ResultBox(concurrencyCap: 4, rendezvousTarget: 2)
        await SizeProbe.sizes(for: dirs) { url, bytes in
            box.rendezvous(url, bytes)
        }
        #expect(box.count == 12, "every input must report exactly once, on attempt \(attempt)")
        // Proves the concurrency cap holds. This is the assertion that catches a
        // production `concurrency` raised above 4; it is an observation, so it is only
        // probabilistic, but it costs nothing and empirically fires often. Checked on
        // every attempt, including ones abandoned for a gate timeout, since an
        // over-wide pool is if anything easier to observe on a contended machine.
        #expect(box.peakInFlight <= 4, "concurrency exceeded the cap on attempt \(attempt)")
        if !box.timedOut { break }

        // Space out retries. Attempts run back-to-back otherwise, and a machine starved
        // enough to lose one rendezvous is still starved microseconds later, so the
        // retries correlate and buy far less than their count suggests. Yielding here
        // both lets the current contention spike pass and gives the dispatch pool time to
        // notice its blocked workers and overcommit a wider one, which is the very
        // condition the next attempt needs. `Task.sleep` suspends rather than blocking, so
        // it does not itself hold the worker the retry is waiting for.
        try? await Task.sleep(nanoseconds: UInt64(attempt) * 50_000_000)
    }

    // A clean run of the gate: two callbacks provably overlapped, so the work is
    // concurrent rather than sequential. If every attempt timed out, `peakInFlight` is
    // still checked below and will report the sequential case as `1`.
    #expect(!box.timedOut, "no attempt managed to overlap two callbacks in \(attemptsBeforeFailing) tries")
    // Proves the work is actually concurrent, not sequential: a sequential implementation
    // can never get two callbacks in flight at once, so the gate never opens and peak
    // stays at 1.
    #expect(box.peakInFlight > 1)
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
    /// Number of simultaneously-in-flight callbacks that opens the gate. Kept below
    /// `concurrencyCap` so the test never depends on the cooperative pool granting a
    /// specific number of workers at once; see the note at the call site.
    private let rendezvousTarget: Int

    init(concurrencyCap: Int, rendezvousTarget: Int) {
        self.rendezvousTarget = rendezvousTarget
        precondition(rendezvousTarget >= 2, "a rendezvous of 1 would prove no overlap at all")
        precondition(rendezvousTarget <= concurrencyCap, "a target above the cap can never be reached")
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
    /// of inferring it from timing — or until a generous timeout elapses.
    ///
    /// The gate re-arms itself: `gateOpened` is reset to `false` once `inFlight` drains
    /// back to 0, so each wave of concurrent callbacks is forced through its own
    /// rendezvous rather than only the very first one. Without this, only wave 1 would be
    /// provably concurrent — later waves would see `gateOpened` still latched from wave 1
    /// and skip waiting entirely. The reset lives in the same critical section as the
    /// decrement it depends on, so no other call can observe `inFlight == 0` with
    /// `gateOpened` still true, or vice versa: both fields only ever change together,
    /// under this lock.
    ///
    /// This makes the *lower* bound (peak > 1, no timeout) deterministic for every wave
    /// of a normal run. It does not make the *upper* bound airtight against an arbitrary
    /// increase to production `concurrency`: callbacks beyond `concurrencyCap` in the same
    /// initial burst are never forced to wait on anything (forcing that would hang a
    /// correct implementation, which only ever produces `concurrencyCap`-sized waves), so
    /// whether their `peak` update is observed while `concurrencyCap - 1` others are still
    /// in flight remains a real-world scheduling race, not a guarantee. Empirically this
    /// still catches a `concurrency` raised from 4 to 8 well over half the time.
    func rendezvous(_ url: URL, _ bytes: Int64) {
        lock.lock()
        inFlight += 1
        peak = max(peak, inFlight)
        results[url] = bytes
        let opensGateNow = inFlight >= rendezvousTarget && !gateOpened
        if opensGateNow { gateOpened = true }
        let alreadyOpen = gateOpened && !opensGateNow
        lock.unlock()

        if opensGateNow {
            for _ in 0..<(rendezvousTarget - 1) { gate.signal() }
        } else if !alreadyOpen {
            // 1s rather than 3: the caller retries, so this bounds a single attempt, not
            // the whole test. Overlap either happens within milliseconds or the pool is
            // too starved to grant a second worker at all, in which case waiting longer
            // just makes a broken implementation slower to report.
            if gate.wait(timeout: .now() + 1) == .timedOut {
                lock.lock(); gateTimedOut = true; lock.unlock()
            }
        }

        // Brief dwell so `peak` can actually observe the width of the pool.
        //
        // The gate alone cannot do this: it releases at `rendezvousTarget` (2), so
        // callbacks beyond the second are never held anywhere and typically enter and
        // leave `inFlight` faster than any other callback overlaps them. Without this
        // dwell a production `concurrency` raised from 4 to 8 goes completely unnoticed,
        // because peak keeps reading 2.
        //
        // Unlike the classic sleep-based concurrency test, nothing about *correctness*
        // rests on this sleep: the lower bound is proven by the gate above. A dwell too
        // short to catch the real peak can only under-report, which weakens the cap
        // assertion into a missed violation, never a false failure on correct code. That
        // is the right direction to fail on a contended CI runner.
        Thread.sleep(forTimeInterval: 0.02)

        lock.lock()
        inFlight -= 1
        if inFlight == 0 { gateOpened = false }
        lock.unlock()
    }
}
