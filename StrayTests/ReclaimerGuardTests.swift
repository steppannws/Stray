import Testing
import Foundation
@testable import Stray

private let home = FileManager.default.homeDirectoryForCurrentUser

@Test func guardRejectsHomeItself() {
    #expect(throws: ReclaimError.isHome) {
        try Reclaimer.assertSafe(home, scanRoots: [])
    }
}

@Test func guardRejectsPathOutsideHome() {
    #expect(throws: ReclaimError.outsideHome) {
        try Reclaimer.assertSafe(URL(fileURLWithPath: "/Library/Caches"), scanRoots: [])
    }
}

@Test func guardRejectsRoot() {
    #expect(throws: ReclaimError.outsideHome) {
        try Reclaimer.assertSafe(URL(fileURLWithPath: "/"), scanRoots: [])
    }
}

@Test func guardRejectsAncestorOfScanRoot() {
    let root = home.appendingPathComponent("Development/project")
    #expect(throws: ReclaimError.isScanRoot) {
        try Reclaimer.assertSafe(home.appendingPathComponent("Development"), scanRoots: [root])
    }
}

@Test func guardRejectsScanRootItself() {
    let root = home.appendingPathComponent("Development")
    #expect(throws: ReclaimError.isScanRoot) {
        try Reclaimer.assertSafe(root, scanRoots: [root])
    }
}

@Test func guardRejectsParentTraversal() {
    let escaping = home.appendingPathComponent("Development/../../../etc")
    #expect(throws: ReclaimError.outsideHome) {
        try Reclaimer.assertSafe(escaping, scanRoots: [])
    }
}

@Test func guardAcceptsNormalNodeModules() throws {
    let target = home.appendingPathComponent("Development/tools/Stray/node_modules")
    try Reclaimer.assertSafe(target, scanRoots: [home.appendingPathComponent("Development")])
}

@Test func guardRejectsSymlinkEscapingHome() throws {
    let fm = FileManager.default
    let dir = home.appendingPathComponent(".stray-tests-\(UUID().uuidString)")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }

    let link = dir.appendingPathComponent("escape")
    try fm.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/etc"))

    #expect(throws: ReclaimError.outsideHome) {
        try Reclaimer.assertSafe(link, scanRoots: [])
    }
}

@Test func guardRejectsSymlinkEscapingHomeWithNonexistentLeaf() throws {
    let fm = FileManager.default
    let dir = home.appendingPathComponent(".stray-tests-\(UUID().uuidString)")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }

    let link = dir.appendingPathComponent("escape")
    try fm.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/etc"))

    // The leaf does not exist. resolvingSymlinksInPath() alone would stop at the last
    // existing ancestor and never follow `escape`, letting the outside-home target slip
    // through. The guard must still catch it by resolving the symlinked ancestor first.
    let target = link.appendingPathComponent("nope-does-not-exist")

    #expect(throws: ReclaimError.outsideHome) {
        try Reclaimer.assertSafe(target, scanRoots: [])
    }
}

@Test func guardAcceptsNonexistentPathUnderOrdinaryHomeDirectory() throws {
    let target = home.appendingPathComponent("Development/whatever-\(UUID().uuidString)/node_modules")
    try Reclaimer.assertSafe(target, scanRoots: [])
}
