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

@Test func sizesEmitsOneResultPerURL() async throws {
    let fm = FileManager.default
    let root = fm.homeDirectoryForCurrentUser
        .appendingPathComponent(".stray-size-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }

    var dirs: [URL] = []
    for i in 0..<6 {
        let d = root.appendingPathComponent("d\(i)")
        try fm.createDirectory(at: d, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 1024).write(to: d.appendingPathComponent("f.bin"))
        dirs.append(d)
    }

    let box = ResultBox()
    await SizeProbe.sizes(for: dirs) { url, bytes in box.record(url, bytes) }
    #expect(box.count == 6)
}

/// Small thread-safe collector so the async callback can be asserted on.
final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [URL: Int64] = [:]
    func record(_ url: URL, _ bytes: Int64) {
        lock.lock(); defer { lock.unlock() }
        results[url] = bytes
    }
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return results.count
    }
}
