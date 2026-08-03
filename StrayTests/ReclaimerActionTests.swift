import Testing
import Foundation
@testable import Stray

@Test func trashMovesFileOutOfPlace() throws {
    let fm = FileManager.default
    let dir = fm.homeDirectoryForCurrentUser
        .appendingPathComponent(".stray-trash-\(UUID().uuidString)")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }

    let name = "node_modules-\(UUID().uuidString)"
    let victim = dir.appendingPathComponent(name)
    try fm.createDirectory(at: victim, withIntermediateDirectories: true)

    let trashedURL = fm.homeDirectoryForCurrentUser
        .appendingPathComponent(".Trash")
        .appendingPathComponent(name)
    defer { try? fm.removeItem(at: trashedURL) }

    try Reclaimer.trash(victim, scanRoots: [])

    // Real deletion (e.g. FileManager.removeItem) would also make the item disappear
    // from its original location, so that alone does not prove this went through the
    // Trash. Assert the item actually landed in ~/.Trash under its (unique) name.
    #expect(!fm.fileExists(atPath: victim.path))
    #expect(fm.fileExists(atPath: trashedURL.path))
}

@Test func trashRefusesUnsafePaths() {
    #expect(throws: ReclaimError.outsideHome) {
        try Reclaimer.trash(URL(fileURLWithPath: "/Library/Caches"), scanRoots: [])
    }
}

@Test func trashForwardsScanRootsToGuard() throws {
    let fm = FileManager.default
    let dir = fm.homeDirectoryForCurrentUser
        .appendingPathComponent(".stray-trash-\(UUID().uuidString)")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }

    // `dir` is an ancestor of the configured scan root `dir/project`, so the guard must
    // reject it. If `trash` fails to forward `scanRoots` to `assertSafe`, this call
    // would succeed (and actually move `dir` to the Trash) instead of throwing.
    #expect(throws: ReclaimError.isScanRoot) {
        try Reclaimer.trash(dir, scanRoots: [dir.appendingPathComponent("project")])
    }
}
