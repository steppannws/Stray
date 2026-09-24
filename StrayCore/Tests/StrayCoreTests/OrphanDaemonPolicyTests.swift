import Testing
import Foundation
@testable import StrayCore

// `OrphanDaemonPolicy` is what stands between a root process and an arbitrary path, so
// every test here but the first is a refusal. They run against a temporary directory
// standing in for /Library/LaunchDaemons, with `requireRootOwner: false` because the
// suite does not run as root; the root-owner check is the one thing not covered here.

/// A fresh daemons directory, resolved so `/var` → `/private/var` does not make every
/// path fail the "directly inside" check.
private func daemonsDir() throws -> String {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("stray-daemons-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.resolvingSymlinksInPath().path
}

@discardableResult
private func writePlist(_ dict: [String: Any], named name: String, in dir: String) throws -> String {
    let path = (dir as NSString).appendingPathComponent(name)
    let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    try data.write(to: URL(fileURLWithPath: path))
    return path
}

private let missingProgram = "/nonexistent/stray-test/\(UUID().uuidString)"

private func validate(_ path: String, in dir: String) throws -> String {
    try OrphanDaemonPolicy.validate(path: path, daemonsDirectory: dir, requireRootOwner: false)
}

@Test func anOrphanDirectlyInTheDirectoryIsAcceptedAndItsLabelReturned() throws {
    let dir = try daemonsDir()
    let path = try writePlist(["Label": "com.example.gone", "Program": missingProgram],
                              named: "com.example.gone.plist", in: dir)
    #expect(try validate(path, in: dir) == "com.example.gone")
}

@Test func programArgumentsIsUsedWhenProgramIsAbsent() throws {
    let dir = try daemonsDir()
    let path = try writePlist(["Label": "a", "ProgramArguments": [missingProgram, "--flag"]],
                              named: "a.plist", in: dir)
    #expect(try validate(path, in: dir) == "a")
}

@Test func aDaemonWhoseProgramExistsIsRefused() throws {
    // The re-check that makes a compromised client harmless: only broken daemons go.
    let dir = try daemonsDir()
    let path = try writePlist(["Label": "live", "Program": "/bin/ls"], named: "live.plist", in: dir)
    #expect(throws: OrphanDaemonPolicy.Rejection.self) { try validate(path, in: dir) }
}

@Test func aPathOutsideTheDirectoryIsRefused() throws {
    let dir = try daemonsDir()
    let other = try daemonsDir()
    let path = try writePlist(["Label": "x", "Program": missingProgram], named: "x.plist", in: other)
    #expect(throws: OrphanDaemonPolicy.Rejection.self) { try validate(path, in: dir) }
}

@Test func dotDotComponentsAreRefused() throws {
    let dir = try daemonsDir()
    let sub = (dir as NSString).appendingPathComponent("sub")
    try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
    try writePlist(["Label": "x", "Program": missingProgram], named: "x.plist", in: dir)
    #expect(throws: OrphanDaemonPolicy.Rejection.self) { try validate(sub + "/../x.plist", in: dir) }
}

@Test func aFileInASubdirectoryIsRefused() throws {
    let dir = try daemonsDir()
    let sub = (dir as NSString).appendingPathComponent("sub")
    try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
    let path = try writePlist(["Label": "x", "Program": missingProgram], named: "x.plist", in: sub)
    #expect(throws: OrphanDaemonPolicy.Rejection.self) { try validate(path, in: dir) }
}

@Test func aSymlinkIsRefusedEvenWhenItPointsAtAValidOrphan() throws {
    // Otherwise a link inside the directory could aim the helper at any file on disk.
    let dir = try daemonsDir()
    let elsewhere = try daemonsDir()
    let target = try writePlist(["Label": "x", "Program": missingProgram], named: "x.plist", in: elsewhere)
    let link = (dir as NSString).appendingPathComponent("link.plist")
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
    #expect(throws: OrphanDaemonPolicy.Rejection.self) { try validate(link, in: dir) }
}

@Test func aNonPlistExtensionIsRefused() throws {
    let dir = try daemonsDir()
    let path = try writePlist(["Label": "x", "Program": missingProgram], named: "x.txt", in: dir)
    #expect(throws: OrphanDaemonPolicy.Rejection.self) { try validate(path, in: dir) }
}

@Test func aRelativeProgramPathIsRefused() throws {
    // Relative to what? launchd resolves it against its own rules; "missing" cannot be
    // decided from here, so it is not treated as orphaned.
    let dir = try daemonsDir()
    let path = try writePlist(["Label": "x", "Program": "bin/gone"], named: "x.plist", in: dir)
    #expect(throws: OrphanDaemonPolicy.Rejection.self) { try validate(path, in: dir) }
}

@Test func aMissingOrSlashedLabelIsRefused() throws {
    // The label becomes `launchctl bootout system/<label>`; a slash would change the target.
    let dir = try daemonsDir()
    let noLabel = try writePlist(["Program": missingProgram], named: "a.plist", in: dir)
    let slashed = try writePlist(["Label": "gui/501/x", "Program": missingProgram], named: "b.plist", in: dir)
    #expect(throws: OrphanDaemonPolicy.Rejection.self) { try validate(noLabel, in: dir) }
    #expect(throws: OrphanDaemonPolicy.Rejection.self) { try validate(slashed, in: dir) }
}

@Test func quarantineMovesTheFileUnderATimestampedNameWithoutOverwriting() throws {
    let dir = try daemonsDir()
    let quarantine = (try daemonsDir() as NSString).appendingPathComponent("Removed")
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    let first = try writePlist(["Label": "x"], named: "x.plist", in: dir)
    let moved = try OrphanDaemonPolicy.quarantine(first, into: quarantine, now: now)
    #expect(moved.lastPathComponent == "1700000000-x.plist")
    #expect(!FileManager.default.fileExists(atPath: first))

    // Same name, same second: the move must fail rather than replace the first copy.
    let second = try writePlist(["Label": "x"], named: "x.plist", in: dir)
    #expect(throws: (any Error).self) {
        try OrphanDaemonPolicy.quarantine(second, into: quarantine, now: now)
    }
    #expect(FileManager.default.fileExists(atPath: moved.path))
}

@Test func onlyOrphansInLibraryLaunchDaemonsCountAsSystemDaemons() {
    func finding(_ path: String, _ kind: FindingKind = .orphanLaunchd) -> Finding {
        Finding(kind: kind, severity: .strong, title: "t", detail: "d",
                pid: nil, path: path, startedAt: nil)
    }
    #expect(finding("/Library/LaunchDaemons/a.plist").isSystemDaemon)
    #expect(!finding("/Users/me/Library/LaunchAgents/a.plist").isSystemDaemon)
    #expect(!finding("/Library/LaunchDaemonsX/a.plist").isSystemDaemon)
    #expect(!finding("/Library/LaunchDaemons/a", .projectJunk).isSystemDaemon)
}
