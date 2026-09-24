import Testing
import Foundation
import Darwin
@testable import StrayCore

// The whitelist decides what Stray stops showing, so the failure that matters is one
// ignore silencing far more than the row it was added from. Most of these tests pin a
// boundary: an empty entry, a sibling path sharing a prefix, a runtime binary shared by
// every node process.

private func orphan(_ pid: pid_t, _ args: String, path: String = "/usr/local/bin/node") -> ScannedProcess {
    ScannedProcess(pid: pid, ppid: 1, path: path, arguments: args,
                   startedAt: Date(timeIntervalSinceNow: -2 * 86_400), uid: getuid())
}

private func diskFinding(_ path: String, kind: FindingKind = .projectJunk) -> Finding {
    Finding(kind: kind, severity: .info, title: (path as NSString).lastPathComponent,
            detail: "d", pid: nil, path: path, startedAt: nil,
            reclaimPaths: [URL(fileURLWithPath: path)])
}

private func processFinding(pid: pid_t, path: String) -> Finding {
    Finding(kind: .orphanProcess, severity: .warning, title: "node",
            detail: "d", pid: pid, path: path, startedAt: nil)
}

/// A throwaway `UserDefaults` suite, so no test reads or writes the user's real list.
private func freshDefaults() -> UserDefaults {
    let name = "stray.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

// MARK: - Matching

@Test func anIgnoredCommandDropsOnlyProcessesContainingIt() {
    var list = Whitelist()
    list.ignoredCommands = ["context7-mcp"]
    #expect(!list.allows(orphan(1, "node /x/node_modules/.bin/context7-mcp")))
    #expect(list.allows(orphan(2, "node /x/node_modules/.bin/other-mcp")))
}

@Test func anEmptyCommandEntryMatchesNothing() {
    // `"abc".contains("")` is true, so an unguarded empty entry would hide every process.
    var list = Whitelist()
    list.ignoredCommands = [""]
    #expect(list.allows(orphan(1, "node server.js")))
    #expect(list.normalized().ignoredCommands.isEmpty)
}

@Test func anIgnoredKindHidesEveryFindingOfThatKind() {
    var list = Whitelist()
    list.ignoredKinds = [.projectJunk]
    #expect(!list.allows(diskFinding("/Users/me/dev/app/node_modules")))
    #expect(list.allows(diskFinding("/Users/me/Library/Caches/pip", kind: .toolCache)))
}

@Test func anIgnoredPathCoversItselfAndEverythingUnderIt() {
    var list = Whitelist()
    list.ignoredPaths = ["/Users/me/dev/keep"]
    #expect(!list.allows(diskFinding("/Users/me/dev/keep")))
    #expect(!list.allows(diskFinding("/Users/me/dev/keep/node_modules")))
}

@Test func anIgnoredPathDoesNotCoverASiblingSharingItsPrefix() {
    var list = Whitelist()
    list.ignoredPaths = ["/Users/me/dev/app"]
    #expect(list.allows(diskFinding("/Users/me/dev/app-old/node_modules")))
}

@Test func pathIgnoresNeverApplyToProcessFindings() {
    // A process finding's path is its runtime binary. Ignoring `/usr/local/bin/node` by
    // path would silence every JS process, so paths only act on file findings.
    var list = Whitelist()
    list.ignoredPaths = ["/usr/local/bin"]
    #expect(list.allows(processFinding(pid: 42, path: "/usr/local/bin/node")))
}

@Test func normalizingTrimsDedupesAndDropsTrailingSlashes() {
    var list = Whitelist()
    list.ignoredCommands = ["  vite ", "vite", ""]
    list.ignoredPaths = ["/a/b/", "/a/b", "/"]
    list.extraMCPPatterns = ["\n"]
    let clean = list.normalized()
    #expect(clean.ignoredCommands == ["vite"])
    #expect(clean.ignoredPaths == ["/a/b", "/"])
    #expect(clean.extraMCPPatterns.isEmpty)
}

// MARK: - Persistence

@Test func aSavedListLoadsBackUnchanged() {
    let store = WhitelistStore(defaults: freshDefaults())
    var list = Whitelist()
    list.ignoredKinds = [.duplicate, .toolCache]
    list.ignoredCommands = ["metro"]
    list.ignoredPaths = ["/Users/me/dev/keep"]
    list.extraMCPPatterns = ["my-agent"]
    store.save(list)
    #expect(store.load() == list)
}

@Test func anUnreadableSavedValueLoadsAsAnEmptyList() {
    let defaults = freshDefaults()
    defaults.set(Data("not json".utf8), forKey: "whitelist")
    #expect(WhitelistStore(defaults: defaults).load() == Whitelist())
}

// MARK: - Rules

@Test func anExtraMCPPatternMakesAMatchingOrphanAnMCPFinding() {
    let procs = [orphan(7, "node /opt/tools/my-agent/server.js")]
    #expect(Rules.evaluate(procs).allSatisfy { $0.kind != .orphanMCP })
    let findings = Rules.evaluate(procs, extraMCPPatterns: ["my-agent"])
    #expect(findings.contains { $0.kind == .orphanMCP && $0.pid == 7 })
}

@Test func everyProcessFindingsIgnoreKeyMatchesItsOwnCommandLine() {
    // The ignore written from a row must actually silence that row on the next scan.
    let procs = [
        orphan(1, "node /x/node_modules/.bin/context7-mcp"),
        orphan(2, "/usr/local/bin/node /Users/me/app/node_modules/.bin/metro start"),
        orphan(3, "node"),
    ]
    let findings = Rules.evaluate(procs)
    #expect(!findings.isEmpty)
    for finding in findings {
        let key = try! #require(finding.ignoreKey)
        var list = Whitelist()
        list.ignoredCommands = [key]
        let survivors = Rules.evaluate(procs.filter(list.allows))
        #expect(!survivors.contains { $0.pid == finding.pid }, "\(key) did not silence PID \(finding.pid!)")
    }
}

// MARK: - ScanEngine

@MainActor
@Test func updatingTheWhitelistHidesMatchingDiskRowsAndPersists() {
    let store = WhitelistStore(defaults: freshDefaults())
    let engine = ScanEngine(startTimer: false, whitelistStore: store)
    engine.beginSizing(for: [
        diskFinding("/Users/me/dev/keep/node_modules"),
        diskFinding("/Users/me/dev/other/node_modules"),
    ])

    engine.updateWhitelist { $0.ignoredPaths.append("/Users/me/dev/keep/") }

    #expect(engine.diskFindings.map(\.path) == ["/Users/me/dev/other/node_modules"])
    #expect(store.load().ignoredPaths == ["/Users/me/dev/keep"])
}
