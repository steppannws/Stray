import Foundation

/// Rule engine. Each rule looks at the full snapshot and returns findings.
/// This is where the real product value lives: add heuristics, not APIs.
enum Rules {

    static func evaluate(_ procs: [ScannedProcess]) -> [Finding] {
        var findings: [Finding] = []
        findings += orphanMCPServers(procs)
        findings += duplicateBinaries(procs)
        findings += orphanNodeProcesses(procs)
        return findings.sorted { $0.severity > $1.severity }
    }

    // Rule 1: orphaned MCP servers.
    // Signature: PPID == 1 + path/args match MCP/agent tooling patterns.
    private static let mcpPatterns = [
        "/_npx/", "mcp-server", "-mcp", "/.claude/", "modelcontextprotocol"
    ]

    private static func orphanMCPServers(_ procs: [ScannedProcess]) -> [Finding] {
        procs.filter { p in
            p.isOrphan && mcpPatterns.contains { p.arguments.contains($0) }
        }.map { p in
            Finding(
                kind: .orphanMCP,
                severity: .strong,
                title: mcpName(from: p.arguments) ?? p.binaryName,
                detail: "PPID 1 (parent session died) · \(p.arguments.prefix(120))",
                pid: p.pid,
                path: p.path,
                startedAt: p.startedAt
            )
        }
    }

    private static func mcpName(from args: String) -> String? {
        let tokens = args.split(separator: " ").map(String.init)

        // 1st: a token matching MCP naming, e.g. ".../node_modules/.bin/context7-mcp"
        if let t = tokens.first(where: { $0.contains("-mcp") || $0.contains("mcp-server") }) {
            return packageName(from: t) ?? (t as NSString).lastPathComponent
        }
        // 2nd: the script argument after the runtime — a node/bun/deno process should be
        // named after what it runs, not after the interpreter.
        if let script = tokens.dropFirst().first(where: {
            $0.hasSuffix(".js") || $0.hasSuffix(".cjs") || $0.hasSuffix(".mjs") || $0.hasSuffix(".ts")
        }) {
            return packageName(from: script) ?? (script as NSString).lastPathComponent
        }
        return nil
    }

    /// ".../cache/thedotmack/claude-mem/10.6.0/scripts/mcp-server.cjs" → "claude-mem".
    /// Package dirs sit right before their version dir; without a version component
    /// (npx caches, global bins) there is nothing to anchor on, so return nil.
    private static func packageName(from path: String) -> String? {
        let comps = (path as NSString).pathComponents
        guard let versionIdx = comps.lastIndex(where: isVersion), versionIdx > 0 else { return nil }
        return comps[versionIdx - 1]
    }

    private static func isVersion(_ component: String) -> Bool {
        let parts = component.split(separator: ".")
        return parts.count >= 2 && parts.allSatisfy { $0.allSatisfy(\.isNumber) }
    }

    // Rule 2: same binary with multiple instances from different trees,
    // started more than 1h apart (two legitimate sessions usually start together... not always;
    // hence severity warning and not strong: we show evidence, the user decides).
    private static func duplicateBinaries(_ procs: [ScannedProcess]) -> [Finding] {
        let interesting = procs.filter { p in
            mcpPatterns.contains { p.arguments.contains($0) } && !p.isOrphan
        }
        let groups = Dictionary(grouping: interesting) {
            mcpName(from: $0.arguments) ?? $0.binaryName
        }
        return groups.compactMap { name, instances -> Finding? in
            let sorted = instances.sorted { $0.startedAt < $1.startedAt }
            guard sorted.count > 1,
                  let oldest = sorted.first,
                  let newest = sorted.last,
                  newest.startedAt.timeIntervalSince(oldest.startedAt) > 3600
            else { return nil }
            let toKill = sorted.dropLast() // everything but the newest
            return Finding(
                kind: .duplicate,
                severity: .warning,
                title: "\(name) ×\(instances.count)",
                detail: "Keeping the newest (PID \(newest.pid)). Killing: \(toKill.map { String($0.pid) }.joined(separator: ", "))",
                pid: oldest.pid,
                extraPIDs: toKill.dropFirst().map(\.pid),
                path: oldest.path,
                startedAt: oldest.startedAt
            )
        }
    }

    // Rule 3: generic orphaned node/bun running for over 24h (metro, dev servers, watchers).
    private static func orphanNodeProcesses(_ procs: [ScannedProcess]) -> [Finding] {
        let runtimes = ["node", "bun", "deno"]
        return procs.filter { p in
            p.isOrphan
                && runtimes.contains(p.binaryName)
                && Date().timeIntervalSince(p.startedAt) > 86_400
                && !mcpPatterns.contains { p.arguments.contains($0) } // already covered by rule 1
        }.map { p in
            Finding(
                kind: .orphanProcess,
                severity: .warning,
                title: p.binaryName,
                detail: "Orphaned for over 24h · \(p.arguments.prefix(120))",
                pid: p.pid,
                path: p.path,
                startedAt: p.startedAt
            )
        }
    }
}
