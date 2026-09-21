import Testing
import Foundation
import Darwin
@testable import StrayCore

// Two layers under test. `PortRow.rows(processes:portsByPID:)` is the pure join that
// turns a process snapshot plus a per-PID port map into the rows the menu renders, and
// it is where sorting, de-duplication, naming and the infra flag are decided.
// `PortScanner` is the syscall layer; it is covered by one end-to-end test that binds a
// real listening socket in this process and asks the scanner to find it.

private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

private func proc(
    _ pid: pid_t,
    _ path: String,
    args: String? = nil,
    started: Date = epoch
) -> ScannedProcess {
    ScannedProcess(
        pid: pid,
        ppid: 1,
        path: path,
        arguments: args ?? path,
        startedAt: started,
        uid: getuid()
    )
}

// MARK: - The join

@Test func rowsAreSortedByPortAscending() {
    let rows = PortRow.rows(
        processes: [proc(10, "/usr/local/bin/node"), proc(11, "/opt/homebrew/bin/bun")],
        portsByPID: [10: [8080], 11: [3000]]
    )

    #expect(rows.map(\.port) == [3000, 8080])
    #expect(rows.map(\.pid) == [11, 10])
}

// A server bound to both 0.0.0.0 and [::] holds two listening sockets on one port. That
// is one thing to kill, so it is one row.
@Test func aProcessListeningOnIPv4AndIPv6ShowsOneRow() {
    let rows = PortRow.rows(
        processes: [proc(10, "/usr/local/bin/node")],
        portsByPID: [10: [3000, 3000]]
    )

    #expect(rows.count == 1)
    #expect(rows.first?.port == 3000)
}

@Test func aProcessWithoutAListeningPortIsNotListed() {
    let rows = PortRow.rows(
        processes: [proc(10, "/usr/local/bin/node"), proc(11, "/usr/local/bin/bun")],
        portsByPID: [10: [3000]]
    )

    #expect(rows.map(\.pid) == [10])
}

// The port map is gathered from a PID list that can go stale between the two passes, so
// a port whose process is gone must not produce a row with no process behind it.
@Test func aPortWhoseProcessIsGoneIsDropped() {
    let rows = PortRow.rows(
        processes: [proc(10, "/usr/local/bin/node")],
        portsByPID: [99: [1234]]
    )

    #expect(rows.isEmpty)
}

@Test func aProcessListeningOnSeveralPortsGetsARowPerPort() {
    let rows = PortRow.rows(
        processes: [proc(10, "/usr/local/bin/node")],
        portsByPID: [10: [9229, 3000]]
    )

    #expect(rows.map(\.port) == [3000, 9229])
    #expect(rows.allSatisfy { $0.pid == 10 })
}

@Test func rowsCarryThePidAndStartTimeOfTheirProcess() {
    let started = Date(timeIntervalSince1970: 1_600_000_000)
    let rows = PortRow.rows(
        processes: [proc(42, "/usr/local/bin/node", args: "node server.js", started: started)],
        portsByPID: [42: [3000]]
    )

    #expect(rows.first?.pid == 42)
    #expect(rows.first?.startedAt == started)
    #expect(rows.first?.command == "node server.js")
}

// MARK: - The runtime filter

// This list answers "which of my dev servers is on which port". A database or an editor
// helper holding a socket is not that, and burying three dev servers among twenty
// system listeners is what the filter exists to prevent.
@Test func onlyJavaScriptRuntimesAreListed() {
    let rows = PortRow.rows(
        processes: [
            proc(10, "/usr/local/bin/node"),
            proc(11, "/opt/homebrew/bin/bun"),
            proc(12, "/usr/local/bin/deno"),
            proc(13, "/opt/homebrew/bin/postgres"),
            proc(14, "/usr/libexec/rapportd"),
            proc(15, "/opt/homebrew/bin/python3"),
        ],
        portsByPID: [10: [3000], 11: [3001], 12: [3002], 13: [5432], 14: [60810], 15: [8000]]
    )

    #expect(rows.map(\.pid) == [10, 11, 12])
}

@Test func theRuntimeIsCarriedOnTheRow() {
    let rows = PortRow.rows(
        processes: [proc(10, "/opt/homebrew/bin/bun", args: "bun server.ts")],
        portsByPID: [10: [3000]]
    )

    #expect(rows.first?.runtime == "bun")
}

// MARK: - Naming

@Test func aScriptRunningUnderARuntimeIsNamedAfterTheScript() {
    let rows = PortRow.rows(
        processes: [proc(10, "/usr/local/bin/node",
                         args: "node /Users/me/app/node_modules/.bin/vite --port 5173")],
        portsByPID: [10: [5173]]
    )

    #expect(rows.first?.name == "vite")
}

@Test func aScriptFileExtensionIsStrippedFromTheName() {
    let rows = PortRow.rows(
        processes: [proc(10, "/usr/local/bin/node", args: "node /Users/me/app/server.mjs")],
        portsByPID: [10: [3000]]
    )

    #expect(rows.first?.name == "server")
}

// Naming defers to the helper `Rules` already uses for MCP processes, so an npx-cached
// server keeps the package name it is known by rather than "index".
@Test func anMCPStyleScriptKeepsItsPackageName() {
    let rows = PortRow.rows(
        processes: [proc(10, "/usr/local/bin/node",
                         args: "node /Users/me/.npm/_npx/a1/node_modules/foo-mcp/dist/index.js")],
        portsByPID: [10: [7000]]
    )

    #expect(rows.first?.name == "foo-mcp")
}

@Test func aRuntimeWithNoScriptArgumentFallsBackToTheBinaryName() {
    let rows = PortRow.rows(
        processes: [proc(10, "/usr/local/bin/node", args: "node")],
        portsByPID: [10: [3000]]
    )

    #expect(rows.first?.name == "node")
}

// MARK: - The project

// Two dev servers are told apart by the project they belong to far more often than by
// the script that runs them - "vite" twice says nothing, "vite · dashboard" and
// "vite · admin" say everything.
@Test func theProjectIsTheLastComponentOfTheWorkingDirectory() {
    let rows = PortRow.rows(
        processes: [proc(10, "/usr/local/bin/node")],
        portsByPID: [10: [3000]],
        workingDirectories: [10: "/Users/me/Development/my-app"]
    )

    #expect(rows.first?.project == "my-app")
}

// A working directory is not always readable, and a row with no project is still a
// perfectly good row - the caption just drops that part.
@Test func aProcessWithNoReadableWorkingDirectoryHasNoProject() {
    let rows = PortRow.rows(
        processes: [proc(10, "/usr/local/bin/node")],
        portsByPID: [10: [3000]],
        workingDirectories: [:]
    )

    #expect(rows.first?.project == nil)
}

// Root is a directory but not a project, and "/" has no last component to show.
@Test func aProcessRunningFromRootHasNoProject() {
    let rows = PortRow.rows(
        processes: [proc(10, "/usr/local/bin/node")],
        portsByPID: [10: [3000]],
        workingDirectories: [10: "/"]
    )

    #expect(rows.first?.project == nil)
}

// MARK: - Working directories

// Read over the real libproc call, against the one working directory this test can
// know for certain: its own. `realpath` on both sides because the test runner's
// directory reaches us through /private symlinks on macOS.
@Test func theWorkingDirectoryOfThisProcessIsReadable() throws {
    let expected = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .resolvingSymlinksInPath().path

    let found = ProcessScanner.workingDirectories(for: [getpid()])[getpid()]

    let actual = try #require(found).map {
        URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
    }
    #expect(actual == expected)
}

// Nothing is readable for a PID that does not exist, and that must be an absent entry
// rather than an empty string standing in for a real directory.
@Test func anUnknownPIDHasNoWorkingDirectory() {
    // -1 is never a live PID; `kill` gives it a special meaning, `proc_pidinfo` does not.
    let found = ProcessScanner.workingDirectories(for: [-1])

    #expect(found.isEmpty)
}

// Binds a TCP socket on a kernel-chosen loopback port and returns it with that port.
// `listening: false` stops after bind, which claims the port without making the process
// a server — the distinction the scanner has to draw. The caller owns the descriptor.
private func openSocket(listening: Bool) throws -> (fd: Int32, port: UInt16) {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    try #require(fd >= 0)

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    addr.sin_port = 0 // let the kernel pick a free port
    let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    try #require(bound == 0)
    if listening { try #require(listen(fd, 1) == 0) }

    var actual = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &actual) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
    }
    try #require(named == 0)

    return (fd, actual.sin_port.byteSwapped) // sin_port is network order
}

// MARK: - The scanner

// End-to-end over the real libproc calls: bind a listening socket in this very process
// and require the scanner to report it back for our own PID. Nothing is mocked, so this
// is the only test that proves the socket walk and the port byte order are right.
@Test func theScannerFindsAListeningSocketOpenedByThisProcess() throws {
    let (fd, port) = try openSocket(listening: true)
    defer { close(fd) }

    let found = PortScanner.listeningPorts(for: [getpid()])

    #expect(found[getpid()]?.contains(port) == true)
}

// Binding claims the port but does not make the process a server. Only sockets that
// have been listened on belong in the list, so a bound-but-not-listening socket must
// not produce a row.
@Test func theScannerIgnoresABoundSocketThatIsNotListening() throws {
    let (fd, port) = try openSocket(listening: false)
    defer { close(fd) }

    let found = PortScanner.listeningPorts(for: [getpid()])

    #expect(found[getpid()]?.contains(port) != true)
}

// MARK: - Engine wiring

/// Where `node` lives, or nil if this machine has none. The end-to-end engine test needs
/// a real listening process that is really a JavaScript runtime, which the test runner
/// itself is not, so it spawns one — and skips rather than fails where node is absent.
private let nodePath: String? = {
    let which = Process()
    which.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    which.arguments = ["which", "node"]
    let out = Pipe()
    which.standardOutput = out
    which.standardError = FileHandle.nullDevice
    guard (try? which.run()) != nil else { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    which.waitUntilExit()
    guard which.terminationStatus == 0 else { return nil }
    let path = String(decoding: data, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return path.isEmpty ? nil : path
}()

// End-to-end through the engine over a real node server: it must appear in
// `ScanEngine.ports` on the port it actually bound, named with the project directory it
// was started from. This is what proves the whole chain — the socket walk, the runtime
// filter, the working-directory read and the join — is wired into the same pass that
// already walks every process.
@MainActor
@Test(.enabled(if: nodePath != nil))
func scanningPublishesARowForARealNodeServer() async throws {
    let node = try #require(nodePath)

    // A named directory, because the row is expected to be labelled with it.
    let project = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("stray-port-fixture-\(UUID().uuidString)")
        .appendingPathComponent("checkout-under-test")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: project.deletingLastPathComponent()) }

    // The server reports the kernel-chosen port through a file rather than stdout, so
    // nothing here blocks on a pipe that a failed child would never write to.
    let portFile = project.appendingPathComponent("port")
    let script = """
    const fs = require('fs'), net = require('net');
    const s = net.createServer();
    s.listen(0, '127.0.0.1', () => fs.writeFileSync('\(portFile.path)', String(s.address().port)));
    setTimeout(() => process.exit(0), 60000);
    """

    let child = Process()
    child.executableURL = URL(fileURLWithPath: node)
    child.arguments = ["-e", script]
    child.currentDirectoryURL = project
    child.standardOutput = FileHandle.nullDevice
    child.standardError = FileHandle.nullDevice
    try child.run()
    defer { if child.isRunning { child.terminate() } }

    let port = try await waitFor(timeout: 15) {
        (try? String(contentsOf: portFile, encoding: .utf8))
            .flatMap { UInt16($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    let engine = ScanEngine(startTimer: false)
    let row = try await waitFor(timeout: 15) { () -> PortRow? in
        engine.scan()
        while engine.isScanning { await Task.yield() }
        return engine.ports.first { $0.pid == child.processIdentifier }
    }

    #expect(row.port == port)
    #expect(row.runtime == "node")
    #expect(row.project == "checkout-under-test")
}

/// Polls `body` until it returns a value or `timeout` seconds pass. Used instead of a
/// fixed sleep so the tests are neither flaky on a loaded machine nor slow on a quiet
/// one; a timeout fails the test with its own message rather than hanging the suite.
private func waitFor<T>(
    timeout: TimeInterval,
    _ body: () async -> T?
) async throws -> T {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
        if let value = await body() { return value }
        try #require(Date() < deadline, "condition not met within \(Int(timeout))s")
        try await Task.sleep(for: .milliseconds(50))
    }
}

// Killing a row must kill the process behind it. A real child process is spawned and
// really terminated here — the whole point of the row is that its button does something
// irreversible, so "it compiles" is not evidence.
@MainActor
@Test func terminatingARowKillsTheProcessBehindIt() async throws {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["30"]
    try child.run()
    defer { if child.isRunning { child.terminate() } }

    let row = PortRow(
        id: "\(child.processIdentifier):3000",
        port: 3000,
        pid: child.processIdentifier,
        name: "sleep",
        runtime: "node",
        project: nil,
        command: "/bin/sleep 30",
        startedAt: Date()
    )

    let engine = ScanEngine(startTimer: false)
    engine.terminate(row)

    let deadline = Date().addingTimeInterval(10)
    while child.isRunning {
        try #require(Date() < deadline, "child survived the kill")
        try await Task.sleep(for: .milliseconds(20))
    }

    #expect(!child.isRunning)
}
