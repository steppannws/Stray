import Testing
import Foundation
@testable import StrayCore

/// A timed-out command must not keep running after `run` gives up on it.
///
/// `terminate()` alone assumes SIGTERM is honoured. The two production callers
/// run Apple tools that do honour it, but this path is only reached once a
/// command has already misbehaved by overrunning its bound, which is precisely
/// when that assumption is worth least. A survivor here is invisible: the error
/// is surfaced, the row disappears from the UI, and the command keeps mutating
/// the disk it was told to stop touching.
@Test func aTimedOutCommandThatIgnoresSIGTERMIsStillKilled() throws {
    // Traps SIGTERM and keeps running, so only an escalation can stop it.
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("stray-stubborn-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let bin = dir.appendingPathComponent("stubborn.sh")
    let pidFile = dir.appendingPathComponent("pid").path
    try """
    #!/bin/sh
    trap '' TERM
    echo $$ > \(pidFile)
    sleep 300
    """.write(to: bin, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
    defer { try? FileManager.default.removeItem(at: dir) }

    // Overruns its bound, so `run` times out and must clean up after itself.
    #expect(throws: ReclaimError.self) {
        try Reclaimer.run(bin.path, [], timeout: 0.3)
    }

    guard let raw = try? String(contentsOfFile: pidFile, encoding: .utf8),
          let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        Issue.record("the stub never recorded its pid, so nothing was verified")
        return
    }

    // `run` returns only once the process is reaped, so no polling is needed.
    let alive = kill(pid, 0) == 0
    if alive { kill(pid, SIGKILL) }
    #expect(!alive, "a command that ignored SIGTERM outlived the timeout that gave up on it")
}
