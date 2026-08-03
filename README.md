# Stray

macOS menu bar app that hunts stray processes: orphaned MCP servers, duplicated agent sessions, dead launchd agents, and forgotten dev servers.

Born from a real audit: 3× claude-mem, 2× context7-mcp, 2× playwright-mcp and 4× obsidian-mcp instances quietly running from dead Claude Code / Cursor / Claude Desktop sessions.

## v1 scope

- Menu bar only (`LSUIElement`), SwiftUI `MenuBarExtra`
- Scans every 5 minutes, badge shows finding count
- User-level processes only — no privileged helper yet
- Detection rules:
  1. **Orphan MCP servers** — PPID == 1 + command line matches MCP tooling patterns (`/_npx/`, `-mcp`, `mcp-server`, `/.claude/`)
  2. **Duplicated MCP instances** — same server name, multiple process trees, started >1h apart
  3. **Orphan node/bun/deno** — PPID == 1 and running >24h
  4. **Orphan LaunchAgents** — `~/Library/LaunchAgents/*.plist` pointing to binaries that no longer exist
- Actions: SIGTERM → SIGKILL escalation with inline confirm; launchd plists go to Trash (reversible)

## Setup

```bash
brew install xcodegen
cd ~/Development/tools/Stray
xcodegen generate
open Stray.xcodeproj
```

Build & run from Xcode (⌘R). The app appears in the menu bar as a paw print.

## Roadmap (v2+)

- Privileged helper via `SMAppService.daemon` for `/Library/LaunchDaemons`
- Port/listener scanning (double Postgres detection, zombie dev servers on known ports)
- Per-rule whitelist and custom patterns
- Launch at login
- Notarized direct distribution

## Design decisions

- **No App Sandbox**: sandboxed apps can't enumerate other processes or manage launchd. Direct distribution with notarization, same as Pearcleaner/Stats.
- **Rules are the product**: scanning is commodity (`libproc`, `sysctl`), value lives in `Rules.swift`. Add heuristics there.
- **Never auto-kill**: every action shows evidence (parent, uptime, command line) and requires explicit confirmation. False positives are worse than stray processes.
