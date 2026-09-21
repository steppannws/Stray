import Foundation

/// One listening port and the dev server holding it — the unit the "Ports" tab renders
/// and the unit the Kill button acts on.
///
/// Unlike `Finding`, a row here is not a judgement. Every JavaScript dev server that is
/// listening is listed, stale or not, because the question this answers is "what is on
/// :3000 and can I have it back", not "what does Stray think is garbage".
public struct PortRow: Identifiable, Hashable {
    /// PID and port together: one process listening on two ports is two rows, and each
    /// must keep its own identity across rescans.
    public let id: String
    public let port: UInt16
    public let pid: pid_t
    /// What the process is called in the list: the script it runs, not the runtime that
    /// runs it. See `displayName(for:)`.
    public let name: String
    /// Which of `runtimes` this is, shown in the caption because `vite` under bun and
    /// `vite` under node are different processes with the same name.
    public let runtime: String
    /// The directory the server was started from, by its last component. Nil when the
    /// working directory could not be read; the caption then simply omits it.
    public let project: String?
    /// Full command line, shown as the row's evidence line.
    public let command: String
    public let startedAt: Date

    public var uptimeDescription: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: startedAt, relativeTo: Date())
    }

    /// The caption under a row's name: where it runs from, what runs it, how long it has
    /// been up. The project drops out when it could not be read rather than leaving a
    /// dangling separator.
    public var subtitle: String {
        [project, runtime, uptimeDescription]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// The runtimes this list covers. A database, an editor helper or an adb server
    /// holding a socket is not what "which of my dev servers is on which port" is asking
    /// about, and burying three dev servers among twenty system listeners is exactly
    /// what this filter exists to prevent.
    ///
    /// Also what naming keys off: these are the runtimes named after what they run, so a
    /// row shows `vite` rather than a list of six processes all called `node`.
    static let runtimes: Set<String> = ["node", "bun", "deno"]

    private static let scriptExtensions: Set<String> = ["js", "cjs", "mjs", "ts", "tsx"]

    /// Joins a process snapshot with a per-PID port map into the rows the menu shows.
    ///
    /// Pure, so the filtering, sorting, de-duplication, naming and project rules are
    /// testable without touching a socket. The inputs are gathered in the same pass but
    /// not atomically, so each side drops what the other cannot account for: a process
    /// with no listening port is not a row, and a port whose process has already exited
    /// is not a row either — a Kill button with no process behind it could only ever
    /// mislead.
    static func rows(
        processes: [ScannedProcess],
        portsByPID: [pid_t: [UInt16]],
        workingDirectories: [pid_t: String] = [:]
    ) -> [PortRow] {
        processes.filter { runtimes.contains($0.binaryName) }.flatMap { process -> [PortRow] in
            Set(portsByPID[process.pid] ?? []).map { port in
                PortRow(
                    id: "\(process.pid):\(port)",
                    port: port,
                    pid: process.pid,
                    name: displayName(for: process),
                    runtime: process.binaryName,
                    project: projectName(from: workingDirectories[process.pid]),
                    command: process.arguments,
                    startedAt: process.startedAt
                )
            }
        }
        // By port, because that is what the user came looking for. PID only breaks ties
        // between two processes on one port, which is possible with SO_REUSEPORT.
        .sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
    }

    /// The project a server belongs to: the last component of its working directory.
    /// Root is a directory but not a project and has no last component worth showing.
    private static func projectName(from workingDirectory: String?) -> String? {
        guard let workingDirectory, workingDirectory != "/" else { return nil }
        let name = (workingDirectory as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }

    /// The name a row carries: the script the runtime is running, or the runtime itself
    /// when it is running nothing nameable.
    ///
    /// Three passes over the script path, most specific first. The package directory
    /// inside `node_modules` beats the file name, because `.../foo-mcp/dist/index.js` is
    /// "foo-mcp" and never "index". Failing that, `Rules.packageName` catches the
    /// versioned cache layout (`.../claude-mem/10.6.0/scripts/server.cjs`) that npx and
    /// friends use. Only then does the file name itself stand in.
    static func displayName(for process: ScannedProcess) -> String {
        guard let script = scriptArgument(in: process.arguments) else { return process.binaryName }

        if let package = packageDirectory(in: script) { return package }
        if let package = Rules.packageName(from: script) { return package }
        return stripScriptExtension((script as NSString).lastPathComponent)
    }

    /// The first argument that is not a flag — `node --inspect server.js` runs
    /// `server.js`. Nil for a bare runtime with nothing after it.
    private static func scriptArgument(in arguments: String) -> String? {
        arguments.split(separator: " ").dropFirst()
            .first { !$0.hasPrefix("-") }
            .map(String.init)
    }

    /// The package directory a script lives in: the component right after the last
    /// `node_modules`. Dot directories (`.bin`, `.pnpm`) are dispatch stubs and name
    /// nothing, and a scoped package's name is the component after the scope.
    private static func packageDirectory(in path: String) -> String? {
        let components = (path as NSString).pathComponents
        guard let idx = components.lastIndex(of: "node_modules"),
              idx + 1 < components.count
        else { return nil }

        let name = components[idx + 1]
        if name.hasPrefix(".") { return nil }
        if name.hasPrefix("@") {
            return idx + 2 < components.count ? components[idx + 2] : nil
        }
        return name
    }

    /// "server.mjs" → "server". Only known script extensions are removed, so a name that
    /// merely contains a dot (`vite.config`, `next-server`) survives intact.
    private static func stripScriptExtension(_ name: String) -> String {
        let ext = (name as NSString).pathExtension
        guard scriptExtensions.contains(ext) else { return name }
        return (name as NSString).deletingPathExtension
    }
}
