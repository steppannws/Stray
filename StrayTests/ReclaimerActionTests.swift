import Testing
import Foundation
@testable import Stray

@Test func trashMovesFileOutOfPlace() throws {
    let fm = FileManager.default
    let dir = fm.homeDirectoryForCurrentUser
        .appendingPathComponent(".stray-trash-\(UUID().uuidString)")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }

    let victim = dir.appendingPathComponent("node_modules")
    try fm.createDirectory(at: victim, withIntermediateDirectories: true)

    try Reclaimer.trash(victim, scanRoots: [])
    #expect(!fm.fileExists(atPath: victim.path))
}

@Test func trashRefusesUnsafePaths() {
    #expect(throws: ReclaimError.outsideHome) {
        try Reclaimer.trash(URL(fileURLWithPath: "/Library/Caches"), scanRoots: [])
    }
}

@Test func trashSizeIsNonNegative() {
    #expect(Reclaimer.trashSize() >= 0)
}
