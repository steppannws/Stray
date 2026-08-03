# Dev Environment Cleaner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a manually-triggered disk scan to Stray that finds regenerable developer artifacts (project `node_modules`/build dirs and known tool caches), sizes them progressively, and reclaims them to Trash.

**Architecture:** Four new files under `Stray/Core/Disk/` with one responsibility each — a curated catalog of known cache roots, a home-directory walker for project junk, a concurrent size prober, and the single code path allowed to delete. `ScanEngine` gains a separate disk-scan lane so the existing 5-minute process timer never triggers disk I/O. The existing `Finding` model and row view are reused rather than duplicated.

**Tech Stack:** Swift 5.10, SwiftUI, macOS 14+, XcodeGen (`project.yml` is the source of truth — never edit `Stray.xcodeproj` by hand), Swift Testing (`import Testing`), Xcode 26.3.

## Global Constraints

- All code, comments, and user-facing strings in **English**. No Spanish reaches a file.
- `project.yml` is the project source of truth. After editing it, run `xcodegen generate`.
- Build command used throughout: `xcodebuild -project Stray.xcodeproj -scheme Stray -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO build`
- Test command used throughout: `xcodebuild test -project Stray.xcodeproj -scheme Stray -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
- Deletion is **Trash-only** (`FileManager.trashItem`), except simulators (`xcrun simctl delete unavailable`) and Docker (`docker image prune -f`).
- Never follow symlinks when sizing or deleting.
- No new third-party dependencies.
- **This directory is not a git repository.** Commit steps below are written out but are **gated**: run them only after the user asks for commits. If the user opts in, run `git init` once before Task 1's commit step.

---

### Task 1: Test target and the deletion guard

The guard is the only thing in this feature that can destroy data, so it is built first and with tests.

**Files:**
- Modify: `project.yml`
- Create: `Stray/Core/Disk/Reclaimer.swift`
- Test: `StrayTests/ReclaimerGuardTests.swift`

**Interfaces:**
- Consumes: nothing (first task)
- Produces: `Reclaimer.assertSafe(_ url: URL, scanRoots: [URL]) throws`, `enum ReclaimError: Error, Equatable { case isHome, outsideHome, isScanRoot }`

- [ ] **Step 1: Add the test target to `project.yml`**

Add to the `targets:` map, as a sibling of `Stray`:

```yaml
  StrayTests:
    type: bundle.unit-test
    platform: macOS
    sources: [StrayTests]
    dependencies:
      - target: Stray
    settings:
      base:
        SWIFT_VERSION: "5.10"
        GENERATE_INFOPLIST_FILE: true
```

Then add a top-level `schemes:` block so `xcodebuild test` has a scheme that knows about tests:

```yaml
schemes:
  Stray:
    build:
      targets:
        Stray: all
        StrayTests: [test]
    run:
      config: Debug
    test:
      config: Debug
      targets: [StrayTests]
```

- [ ] **Step 2: Regenerate the project**

Run: `xcodegen generate`
Expected: `Created project at /Users/stepan/Development/tools/Stray/Stray.xcodeproj`

- [ ] **Step 3: Write the failing test**

Create `StrayTests/ReclaimerGuardTests.swift`:

```swift
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
```

- [ ] **Step 4: Run the tests to verify they fail**

Run: `xcodebuild test -project Stray.xcodeproj -scheme Stray -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Testing|TEST"`
Expected: compile failure — `cannot find 'Reclaimer' in scope`.

- [ ] **Step 5: Write the minimal implementation**

Create `Stray/Core/Disk/Reclaimer.swift`:

```swift
import Foundation

enum ReclaimError: Error, Equatable {
    case isHome
    case outsideHome
    case isScanRoot
}

/// The only code in the app allowed to delete anything on disk.
/// Every public action routes through `assertSafe` first.
enum Reclaimer {

    /// Rejects anything that is not a disposable path strictly inside the user's home:
    /// home itself, anything outside home (after resolving symlinks), and any directory
    /// that contains a configured scan root.
    static func assertSafe(_ url: URL, scanRoots: [URL]) throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
            .resolvingSymlinksInPath().standardizedFileURL
        let target = url.resolvingSymlinksInPath().standardizedFileURL

        guard target.path != home.path else { throw ReclaimError.isHome }
        guard target.path.hasPrefix(home.path + "/") else { throw ReclaimError.outsideHome }

        for root in scanRoots {
            let root = root.resolvingSymlinksInPath().standardizedFileURL
            if root.path == target.path || root.path.hasPrefix(target.path + "/") {
                throw ReclaimError.isScanRoot
            }
        }
    }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `xcodebuild test -project Stray.xcodeproj -scheme Stray -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20`
Expected: all 8 tests pass.

- [ ] **Step 7: Commit (gated — only if the user asked for commits)**

```bash
git add project.yml Stray/Core/Disk/Reclaimer.swift StrayTests/ReclaimerGuardTests.swift
git commit -m "feat: add test target and deletion path guard"
```

---

### Task 2: Cache catalog

**Files:**
- Create: `Stray/Core/Disk/CacheCatalog.swift`
- Test: `StrayTests/CacheCatalogTests.swift`

**Interfaces:**
- Consumes: nothing
- Produces: `struct CacheEntry { let id: String; let name: String; let paths: [URL]; let reclaim: ReclaimMethod; let regeneratedBy: String }`, `enum ReclaimMethod { case trash, simctlDeleteUnavailable, dockerImagePrune }`, `CacheCatalog.all: [CacheEntry]`, `CacheCatalog.present() -> [CacheEntry]`

- [ ] **Step 1: Write the failing test**

Create `StrayTests/CacheCatalogTests.swift`:

```swift
import Testing
import Foundation
@testable import Stray

@Test func catalogIDsAreUnique() {
    let ids = CacheCatalog.all.map(\.id)
    #expect(Set(ids).count == ids.count)
}

@Test func catalogEntriesAreWellFormed() {
    for entry in CacheCatalog.all {
        #expect(!entry.id.isEmpty)
        #expect(!entry.name.isEmpty)
        #expect(!entry.regeneratedBy.isEmpty)
        #expect(!entry.paths.isEmpty)
    }
}

@Test func catalogNeverTargetsHomeOrSystemRoots() throws {
    let home = FileManager.default.homeDirectoryForCurrentUser
        .resolvingSymlinksInPath().standardizedFileURL
    for entry in CacheCatalog.all where entry.reclaim == .trash {
        for path in entry.paths {
            let p = path.standardizedFileURL
            #expect(p.path != home.path)
            #expect(p.path != "/")
            // every trashable catalog path must survive the deletion guard
            try Reclaimer.assertSafe(p, scanRoots: [])
        }
    }
}

@Test func catalogExcludesInstalledTooling() {
    // These match cache-shaped heuristics but are installed tooling or downloaded
    // model weights — deleting them costs hours, not a rebuild.
    let forbidden = [".pyenv", ".local", ".platformio", ".lmstudio"]
    for entry in CacheCatalog.all {
        for path in entry.paths {
            #expect(!forbidden.contains(path.lastPathComponent))
        }
    }
}

@Test func presentOnlyReturnsExistingPaths() {
    for entry in CacheCatalog.present() where entry.reclaim == .trash {
        #expect(entry.paths.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project Stray.xcodeproj -scheme Stray -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:" | head -5`
Expected: `cannot find 'CacheCatalog' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Stray/Core/Disk/CacheCatalog.swift`:

```swift
import Foundation

enum ReclaimMethod: Equatable {
    case trash
    case simctlDeleteUnavailable
    case dockerImagePrune
}

struct CacheEntry: Identifiable {
    let id: String
    let name: String
    let paths: [URL]
    let reclaim: ReclaimMethod
    /// Shown as the finding's evidence line: what brings this back.
    let regeneratedBy: String
}

/// Curated table of known developer caches.
///
/// Deliberately a hand-maintained list rather than a pattern match: `~/.pyenv`,
/// `~/.local`, `~/.platformio` and `~/.lmstudio` all look cache-shaped but hold
/// installed tooling and downloaded model weights. Adding a cache is one literal here.
enum CacheCatalog {

    private static let home = FileManager.default.homeDirectoryForCurrentUser

    private static func h(_ path: String) -> URL {
        home.appendingPathComponent(path)
    }

    static let all: [CacheEntry] = [
        // Package manager stores
        CacheEntry(id: "pkg.yarn", name: "Yarn cache",
                   paths: [h(".yarn-cache")], reclaim: .trash,
                   regeneratedBy: "Next yarn install"),
        CacheEntry(id: "pkg.pnpm", name: "pnpm store",
                   paths: [h("Library/pnpm")], reclaim: .trash,
                   regeneratedBy: "Next pnpm install — existing node_modules symlink into this store and will need reinstalling"),
        CacheEntry(id: "pkg.npm", name: "npm cache",
                   paths: [h(".npm")], reclaim: .trash,
                   regeneratedBy: "Next npm install"),
        CacheEntry(id: "pkg.bun", name: "Bun install cache",
                   paths: [h(".bun/install/cache")], reclaim: .trash,
                   regeneratedBy: "Next bun install"),
        CacheEntry(id: "pkg.gradle", name: "Gradle caches",
                   paths: [h(".gradle/caches")], reclaim: .trash,
                   regeneratedBy: "Next Gradle build"),
        CacheEntry(id: "pkg.cocoapods", name: "CocoaPods cache",
                   paths: [h("Library/Caches/CocoaPods")], reclaim: .trash,
                   regeneratedBy: "Next pod install"),

        // Xcode artifacts
        CacheEntry(id: "xcode.derived-data", name: "Xcode DerivedData",
                   paths: [h("Library/Developer/Xcode/DerivedData")], reclaim: .trash,
                   regeneratedBy: "Next Xcode build"),
        CacheEntry(id: "xcode.archives", name: "Xcode Archives",
                   paths: [h("Library/Developer/Xcode/Archives")], reclaim: .trash,
                   regeneratedBy: "Nothing — these are shipped build archives, delete only if you no longer need to symbolicate old crashes"),
        CacheEntry(id: "xcode.device-support", name: "iOS DeviceSupport",
                   paths: [h("Library/Developer/Xcode/iOS DeviceSupport")], reclaim: .trash,
                   regeneratedBy: "Reconnecting the device"),
        CacheEntry(id: "xcode.simulators", name: "Unavailable simulators",
                   paths: [h("Library/Developer/CoreSimulator/Devices")],
                   reclaim: .simctlDeleteUnavailable,
                   regeneratedBy: "Xcode recreates simulators on demand — only runtimes with no matching Xcode are removed"),

        // Allowlisted generic caches
        CacheEntry(id: "cache.dot-cache", name: "~/.cache",
                   paths: [h(".cache")], reclaim: .trash,
                   regeneratedBy: "The tools that wrote it"),
        CacheEntry(id: "cache.homebrew", name: "Homebrew downloads",
                   paths: [h("Library/Caches/Homebrew")], reclaim: .trash,
                   regeneratedBy: "Next brew install"),
        CacheEntry(id: "cache.pip", name: "pip cache",
                   paths: [h("Library/Caches/pip")], reclaim: .trash,
                   regeneratedBy: "Next pip install"),
        CacheEntry(id: "cache.playwright", name: "Playwright browsers",
                   paths: [h("Library/Caches/ms-playwright")], reclaim: .trash,
                   regeneratedBy: "npx playwright install"),

        // Docker
        CacheEntry(id: "docker.dangling", name: "Docker dangling images",
                   paths: [], reclaim: .dockerImagePrune,
                   regeneratedBy: "Rebuilding images — only untagged layers are removed"),
    ]

    /// Entries whose targets actually exist on this machine.
    /// Docker is included only when the CLI is installed.
    static func present() -> [CacheEntry] {
        all.filter { entry in
            switch entry.reclaim {
            case .dockerImagePrune:
                return dockerAvailable
            default:
                return entry.paths.contains { FileManager.default.fileExists(atPath: $0.path) }
            }
        }
    }

    static var dockerAvailable: Bool {
        ["/usr/local/bin/docker", "/opt/homebrew/bin/docker"]
            .contains { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -project Stray.xcodeproj -scheme Stray -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20`
Expected: all tests pass, including Task 1's.

- [ ] **Step 5: Commit (gated)**

```bash
git add Stray/Core/Disk/CacheCatalog.swift StrayTests/CacheCatalogTests.swift
git commit -m "feat: add curated developer cache catalog"
```

---

### Task 3: Project junk scanner

**Files:**
- Create: `Stray/Core/Disk/DiskScanner.swift`
- Test: `StrayTests/DiskScannerTests.swift`

**Interfaces:**
- Consumes: nothing
- Produces: `DiskScanner.defaultRoots: [URL]`, `DiskScanner.isMatch(name: String, siblings: Set<String>) -> Bool`, `DiskScanner.scan() -> [URL]`

- [ ] **Step 1: Write the failing test**

Create `StrayTests/DiskScannerTests.swift`:

```swift
import Testing
import Foundation
@testable import Stray

@Test func nodeModulesMatchesWithoutMarker() {
    #expect(DiskScanner.isMatch(name: "node_modules", siblings: []))
}

@Test func nextAndVenvMatchWithoutMarker() {
    #expect(DiskScanner.isMatch(name: ".next", siblings: []))
    #expect(DiskScanner.isMatch(name: ".venv", siblings: []))
    #expect(DiskScanner.isMatch(name: "__pycache__", siblings: []))
}

@Test func podsRequiresPodfile() {
    #expect(DiskScanner.isMatch(name: "Pods", siblings: ["Podfile"]))
    #expect(!DiskScanner.isMatch(name: "Pods", siblings: ["README.md"]))
}

@Test func buildRequiresBuildMarker() {
    #expect(DiskScanner.isMatch(name: "build", siblings: ["build.gradle"]))
    #expect(DiskScanner.isMatch(name: "build", siblings: ["build.gradle.kts"]))
    #expect(DiskScanner.isMatch(name: "build", siblings: ["CMakeLists.txt"]))
    #expect(!DiskScanner.isMatch(name: "build", siblings: ["index.html", "style.css"]))
}

@Test func targetRequiresRustOrMavenMarker() {
    #expect(DiskScanner.isMatch(name: "target", siblings: ["Cargo.toml"]))
    #expect(DiskScanner.isMatch(name: "target", siblings: ["pom.xml"]))
    #expect(!DiskScanner.isMatch(name: "target", siblings: ["main.c"]))
}

@Test func unknownNamesNeverMatch() {
    #expect(!DiskScanner.isMatch(name: "src", siblings: ["package.json"]))
    #expect(!DiskScanner.isMatch(name: "dist", siblings: ["package.json"]))
}

@Test func scanFindsNodeModulesInAFixtureTree() throws {
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser
    let root = home.appendingPathComponent(".stray-scan-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }

    let project = root.appendingPathComponent("proj")
    try fm.createDirectory(at: project.appendingPathComponent("node_modules/inner/node_modules"),
                           withIntermediateDirectories: true)
    try fm.createDirectory(at: project.appendingPathComponent("src/build"),
                           withIntermediateDirectories: true)

    let hits = DiskScanner.scan(roots: [root])

    // outer node_modules found, nested one pruned, unmarked build ignored
    #expect(hits.count == 1)
    #expect(hits.first?.lastPathComponent == "node_modules")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project Stray.xcodeproj -scheme Stray -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:" | head -5`
Expected: `cannot find 'DiskScanner' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Stray/Core/Disk/DiskScanner.swift`:

```swift
import Foundation

/// Finds regenerable project directories by walking the user's home.
///
/// Hidden directories are skipped by name check rather than `.skipsHiddenFiles`,
/// because `.next` and `.venv` are themselves targets. This is what keeps the
/// thousands of hits inside dot-caches (`~/.yarn-cache`, `~/.cache`) out of the
/// project list — those are covered by `CacheCatalog` as one entry each.
enum DiskScanner {

    struct MatchRule {
        let name: String
        /// Any one of these files must sit next to the directory for it to count.
        /// Empty means the name alone is enough.
        let requiredSiblings: [String]
    }

    static let rules: [MatchRule] = [
        MatchRule(name: "node_modules", requiredSiblings: []),
        MatchRule(name: ".next", requiredSiblings: []),
        MatchRule(name: ".venv", requiredSiblings: []),
        MatchRule(name: "__pycache__", requiredSiblings: []),
        MatchRule(name: "Pods", requiredSiblings: ["Podfile"]),
        MatchRule(name: "build", requiredSiblings: ["build.gradle", "build.gradle.kts", "CMakeLists.txt"]),
        MatchRule(name: "target", requiredSiblings: ["Cargo.toml", "pom.xml"]),
    ]

    private static let excludedTopLevel: Set<String> = [
        "Library", "Pictures", "Movies", "Music", "Applications", ".Trash"
    ]

    static var defaultRoots: [URL] { [FileManager.default.homeDirectoryForCurrentUser] }

    static func isMatch(name: String, siblings: Set<String>) -> Bool {
        guard let rule = rules.first(where: { $0.name == name }) else { return false }
        if rule.requiredSiblings.isEmpty { return true }
        return rule.requiredSiblings.contains { siblings.contains($0) }
    }

    static func scan(roots: [URL] = defaultRoots) -> [URL] {
        roots.flatMap { walk($0) }
    }

    private static func walk(_ root: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return [] }

        var hits: [URL] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }

            let name = url.lastPathComponent
            let isTopLevel = url.deletingLastPathComponent().standardizedFileURL.path
                == root.standardizedFileURL.path

            if isTopLevel && excludedTopLevel.contains(name) {
                enumerator.skipDescendants()
                continue
            }

            let known = rules.contains { $0.name == name }
            if name.hasPrefix(".") && !known {
                enumerator.skipDescendants()
                continue
            }
            guard known else { continue }

            let siblings = Set((try? fm.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)) ?? [])
            if isMatch(name: name, siblings: siblings) {
                hits.append(url)
                enumerator.skipDescendants()
            }
        }
        return hits
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -project Stray.xcodeproj -scheme Stray -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20`
Expected: all tests pass.

- [ ] **Step 5: Sanity-check the walk against the real disk**

Run:
```bash
xcodebuild -project Stray.xcodeproj -scheme Stray -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|BUILD"
```
Expected: `** BUILD SUCCEEDED **`. Real-disk hit counts are verified in Task 7.

- [ ] **Step 6: Commit (gated)**

```bash
git add Stray/Core/Disk/DiskScanner.swift StrayTests/DiskScannerTests.swift
git commit -m "feat: add project junk scanner with sibling-marker match rules"
```

---

### Task 4: Size probe

**Files:**
- Create: `Stray/Core/Disk/SizeProbe.swift`
- Test: `StrayTests/SizeProbeTests.swift`

**Interfaces:**
- Consumes: nothing
- Produces: `SizeProbe.size(of url: URL) -> Int64`, `SizeProbe.sizes(for urls: [URL], onResult: @Sendable @escaping (URL, Int64) -> Void) async`

- [ ] **Step 1: Write the failing test**

Create `StrayTests/SizeProbeTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project Stray.xcodeproj -scheme Stray -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:" | head -5`
Expected: `cannot find 'SizeProbe' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Stray/Core/Disk/SizeProbe.swift`:

```swift
import Foundation

/// Computes allocated size for directory trees.
///
/// Symlinks are never resolved: `~/Library/pnpm` and the yarn store are symlink
/// farms, so following them would both double-count and let a later delete escape
/// the intended tree.
enum SizeProbe {

    /// Max simultaneous probes. Disk sizing is I/O bound; more than this thrashes the SSD
    /// without finishing sooner.
    private static let concurrency = 4

    static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return 0 }

        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: keys) else { continue }
            if values.isSymbolicLink == true { continue }
            guard values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Sizes every URL, at most `concurrency` at a time, calling `onResult` as each finishes.
    static func sizes(for urls: [URL], onResult: @Sendable @escaping (URL, Int64) -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            var pending = urls.makeIterator()
            var running = 0

            func addNext() {
                guard let url = pending.next() else { return }
                running += 1
                group.addTask(priority: .utility) {
                    onResult(url, size(of: url))
                }
            }

            for _ in 0..<concurrency { addNext() }
            while running > 0 {
                await group.next()
                running -= 1
                addNext()
            }
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -project Stray.xcodeproj -scheme Stray -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20`
Expected: all tests pass.

- [ ] **Step 5: Commit (gated)**

```bash
git add Stray/Core/Disk/SizeProbe.swift StrayTests/SizeProbeTests.swift
git commit -m "feat: add concurrent directory size probe"
```

---

### Task 5: Reclaim actions

Extends Task 1's guard-only `Reclaimer` with the three actions that actually free space.

**Files:**
- Modify: `Stray/Core/Disk/Reclaimer.swift`
- Test: `StrayTests/ReclaimerActionTests.swift`

**Interfaces:**
- Consumes: `Reclaimer.assertSafe(_:scanRoots:)` from Task 1, `CacheCatalog.dockerAvailable` from Task 2
- Produces: `Reclaimer.trash(_ url: URL, scanRoots: [URL]) throws`, `Reclaimer.simctlDeleteUnavailable() throws`, `Reclaimer.dockerImagePrune() throws`, `Reclaimer.trashSize() -> Int64`, `Reclaimer.emptyTrash() throws`, `ReclaimError.commandFailed(Int32)`

- [ ] **Step 1: Write the failing test**

Create `StrayTests/ReclaimerActionTests.swift`:

```swift
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
```

Note: `simctlDeleteUnavailable` and `dockerImagePrune` are not unit-tested — both mutate global machine state and shelling out in a test would delete real simulators or images. They are verified manually in Task 7.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project Stray.xcodeproj -scheme Stray -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:" | head -5`
Expected: `type 'Reclaimer' has no member 'trash'`.

- [ ] **Step 3: Write the implementation**

Add to `Stray/Core/Disk/Reclaimer.swift` — extend `ReclaimError` with `case commandFailed(Int32)` and append these methods inside `enum Reclaimer`:

```swift
    /// Move to Trash. Reversible until the Trash is emptied.
    static func trash(_ url: URL, scanRoots: [URL]) throws {
        try assertSafe(url, scanRoots: scanRoots)
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// Removes simulator runtimes with no matching Xcode. Configured devices are user
    /// data and are left alone, so this never goes through `trash`.
    static func simctlDeleteUnavailable() throws {
        try run("/usr/bin/xcrun", ["simctl", "delete", "unavailable"])
    }

    /// Dangling (untagged) images only. Never `system prune -a`, which also removes
    /// named volumes.
    static func dockerImagePrune() throws {
        let docker = ["/opt/homebrew/bin/docker", "/usr/local/bin/docker"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let docker else { throw ReclaimError.commandFailed(-1) }
        try run(docker, ["image", "prune", "-f"])
    }

    static func trashSize() -> Int64 {
        let trash = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash")
        guard FileManager.default.fileExists(atPath: trash.path) else { return 0 }
        return SizeProbe.size(of: trash)
    }

    static func emptyTrash() throws {
        let fm = FileManager.default
        let trash = fm.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        for entry in (try? fm.contentsOfDirectory(atPath: trash.path)) ?? [] {
            try? fm.removeItem(at: trash.appendingPathComponent(entry))
        }
    }

    private static func run(_ launchPath: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ReclaimError.commandFailed(process.terminationStatus)
        }
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -project Stray.xcodeproj -scheme Stray -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20`
Expected: all tests pass.

- [ ] **Step 5: Commit (gated)**

```bash
git add Stray/Core/Disk/Reclaimer.swift StrayTests/ReclaimerActionTests.swift
git commit -m "feat: add trash, simctl and docker reclaim actions"
```

---

### Task 6: Model and engine wiring

**Files:**
- Modify: `Stray/Models/Finding.swift`
- Modify: `Stray/Core/ScanEngine.swift`

**Interfaces:**
- Consumes: `DiskScanner.scan(roots:)`, `CacheCatalog.present()`, `SizeProbe.sizes(for:onResult:)`, `Reclaimer.trash(_:scanRoots:)`, `Reclaimer.simctlDeleteUnavailable()`, `Reclaimer.dockerImagePrune()`, `Reclaimer.trashSize()`, `Reclaimer.emptyTrash()`
- Produces: `Finding.bytes: Int64?`, `Finding.isActiveProject: Bool`, `FindingKind.projectJunk`, `FindingKind.toolCache`, `ScanEngine.diskFindings`, `ScanEngine.isDiskScanning`, `ScanEngine.trashBytes`, `ScanEngine.reclaimableBytes`, `ScanEngine.scanDisk()`, `ScanEngine.emptyTrash()`

- [ ] **Step 1: Extend `FindingKind` and `Finding`**

In `Stray/Models/Finding.swift`, add two cases to `FindingKind`:

```swift
    case projectJunk = "Project junk"
    case toolCache = "Tool cache"
```

and two properties to `Finding`. They must be declared **after `startedAt`**, as the last
two stored properties of the struct:

```swift
    var bytes: Int64?           // nil while sizing is in flight
    var isActiveProject = false // project files touched in the last 7 days
```

Swift's memberwise initializer follows declaration order, so declaring these last is what
lets the disk call sites in Step 3 pass `isActiveProject:` after `startedAt:`. Both have
defaults, so the existing process-rule call sites keep compiling unchanged.

Add a formatted accessor at the bottom of the struct:

```swift
    var sizeDescription: String {
        guard let bytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
```

- [ ] **Step 2: Build to confirm nothing broke**

Run: `xcodebuild -project Stray.xcodeproj -scheme Stray -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|BUILD"`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Add the disk lane to `ScanEngine`**

In `Stray/Core/ScanEngine.swift`, add these published properties next to the existing ones:

```swift
    @Published var diskFindings: [Finding] = []
    @Published var isDiskScanning = false
    @Published var lastDiskScan: Date?
    @Published var trashBytes: Int64?

    var reclaimableBytes: Int64 {
        diskFindings.compactMap(\.bytes).reduce(0, +)
    }
```

Then add the scan itself. Discovery publishes immediately with `bytes: nil`; sizing fills rows in as it completes.

```swift
    /// Manual only — disk walks are I/O heavy and never run on the process timer.
    func scanDisk() {
        guard !isDiskScanning else { return }
        isDiskScanning = true

        Task.detached(priority: .utility) {
            let junk = DiskScanner.scan()
            let caches = CacheCatalog.present()
            let findings = junk.map(Self.junkFinding) + caches.map(Self.cacheFinding)

            await MainActor.run {
                self.diskFindings = findings
                self.lastDiskScan = Date()
            }

            let sizable = findings.compactMap { $0.pathURL }
            await SizeProbe.sizes(for: sizable) { url, bytes in
                Task { @MainActor in self.applySize(bytes, to: url) }
            }

            let trash = Reclaimer.trashSize()
            await MainActor.run {
                self.trashBytes = trash
                self.diskFindings.sort { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
                self.isDiskScanning = false
            }
        }
    }

    private func applySize(_ bytes: Int64, to url: URL) {
        guard let idx = diskFindings.firstIndex(where: { $0.path == url.path }) else { return }
        diskFindings[idx].bytes = bytes
    }

    private static func junkFinding(_ url: URL) -> Finding {
        let project = url.deletingLastPathComponent()
        let modified = (try? project.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        let active = modified.map { Date().timeIntervalSince($0) < 7 * 86_400 } ?? false
        return Finding(
            kind: .projectJunk,
            severity: .info,
            title: "\(project.lastPathComponent)/\(url.lastPathComponent)",
            detail: project.path,
            pid: nil,
            path: url.path,
            startedAt: modified,
            isActiveProject: active
        )
    }

    private static func cacheFinding(_ entry: CacheEntry) -> Finding {
        Finding(
            kind: .toolCache,
            severity: .info,
            title: entry.name,
            detail: entry.regeneratedBy,
            pid: nil,
            path: entry.paths.first?.path ?? entry.id,
            startedAt: nil
        )
    }

    func emptyTrash() {
        try? Reclaimer.emptyTrash()
        let trash = Reclaimer.trashSize()
        trashBytes = trash
    }
```

Add a helper to `Finding` in `Stray/Models/Finding.swift` so the engine can map sizes back:

```swift
    var pathURL: URL? {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : nil
    }
```

The `Finding` memberwise initializer takes arguments in declaration order, so `isActiveProject` is passed last — after `startedAt`. Verify the order matches the struct when writing these call sites.

- [ ] **Step 4: Route disk kinds through `resolve`**

In `ScanEngine.resolve(_:)`, extend the `switch finding.kind` with:

```swift
        case .projectJunk:
            try? Reclaimer.trash(URL(fileURLWithPath: finding.path), scanRoots: DiskScanner.defaultRoots)
            diskFindings.removeAll { $0.id == finding.id }
            trashBytes = Reclaimer.trashSize()
        case .toolCache:
            resolveCache(finding)
```

and add:

```swift
    private func resolveCache(_ finding: Finding) {
        guard let entry = CacheCatalog.all.first(where: { $0.name == finding.title }) else { return }
        switch entry.reclaim {
        case .trash:
            for path in entry.paths {
                try? Reclaimer.trash(path, scanRoots: [])
            }
        case .simctlDeleteUnavailable:
            try? Reclaimer.simctlDeleteUnavailable()
        case .dockerImagePrune:
            try? Reclaimer.dockerImagePrune()
        }
        diskFindings.removeAll { $0.id == finding.id }
        trashBytes = Reclaimer.trashSize()
    }
```

The existing `default:` branch keeps handling process kills unchanged.

- [ ] **Step 5: Build**

Run: `xcodebuild -project Stray.xcodeproj -scheme Stray -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|BUILD"`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Run the full test suite**

Run: `xcodebuild test -project Stray.xcodeproj -scheme Stray -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20`
Expected: all tests from Tasks 1–5 still pass.

- [ ] **Step 7: Commit (gated)**

```bash
git add Stray/Models/Finding.swift Stray/Core/ScanEngine.swift
git commit -m "feat: wire disk scan lane into ScanEngine"
```

---

### Task 7: Panel UI and real-disk verification

**Files:**
- Modify: `Stray/UI/MenuView.swift`

**Interfaces:**
- Consumes: `ScanEngine.diskFindings`, `ScanEngine.isDiskScanning`, `ScanEngine.reclaimableBytes`, `ScanEngine.trashBytes`, `ScanEngine.scanDisk()`, `ScanEngine.emptyTrash()`, `Finding.sizeDescription`, `Finding.isActiveProject`
- Produces: nothing consumed by later tasks

- [ ] **Step 1: Add the Disk section**

In `Stray/UI/MenuView.swift`, insert between `findingsList`/`emptyState` and the footer `Divider()`:

```swift
            Divider()
            diskSection
```

and add the section itself:

```swift
    private var diskSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Disk").font(.subheadline).fontWeight(.medium)
                Spacer()
                if engine.isDiskScanning {
                    ProgressView().controlSize(.small)
                }
                if engine.diskFindings.isEmpty {
                    Button("Scan disk") { engine.scanDisk() }
                        .buttonStyle(.borderless).font(.caption)
                } else {
                    Text("Reclaimable: \(ByteCountFormatter.string(fromByteCount: engine.reclaimableBytes, countStyle: .file))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(10)

            if !engine.diskFindings.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(engine.diskFindings) { finding in
                            FindingRow(finding: finding) { engine.resolve(finding) }
                            Divider().padding(.leading, 10)
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
        }
    }
```

- [ ] **Step 2: Show size and the active chip in `FindingRow`**

In `FindingRow.body`, inside the trailing `VStack`, replace the `if finding.startedAt != nil` block with:

```swift
                HStack(spacing: 6) {
                    if finding.bytes != nil || finding.kind == .projectJunk || finding.kind == .toolCache {
                        Text(finding.sizeDescription)
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if finding.startedAt != nil {
                        Text("Since: \(finding.uptimeDescription)")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    if finding.isActiveProject {
                        Text("active")
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.orange.opacity(0.25), in: Capsule())
                    }
                }
```

- [ ] **Step 3: Add the disk action labels**

In `FindingRow.actionLabel`, add before `default:`:

```swift
        case .projectJunk, .toolCache: return "Trash"
```

- [ ] **Step 4: Add the Trash row to the footer**

In `MenuView.footer`, insert before the existing `Spacer()`:

```swift
            if let trash = engine.trashBytes, trash > 0 {
                Text("Trash: \(ByteCountFormatter.string(fromByteCount: trash, countStyle: .file))")
                    .font(.caption2).foregroundStyle(.secondary)
                Button("Empty") { engine.emptyTrash() }
                    .buttonStyle(.borderless).font(.caption2)
            }
```

- [ ] **Step 5: Build and launch**

```bash
pkill -f "Stray.app/Contents/MacOS/Stray"
xcodebuild -project Stray.xcodeproj -scheme Stray -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|BUILD"
open build/Build/Products/Debug/Stray.app
```
Expected: `** BUILD SUCCEEDED **`, app appears in the menu bar.

- [ ] **Step 6: Verify against the real disk**

Open the panel, click **Scan disk**, and confirm each of these. Do not click any Trash button during this step.

1. Rows appear in roughly 2 seconds showing `—` for size.
2. Sizes fill in progressively; the `Reclaimable:` total climbs.
3. `~/Development` project rows appear (expect on the order of 55 `node_modules` entries) and no rows come from inside `~/.yarn-cache`, `~/.cache` or `~/.lmstudio`.
4. Cache rows appear for the catalog entries that exist — Xcode DerivedData, pnpm store, Yarn cache, npm cache, `~/.cache`, Bun, Gradle.
5. No row targets `~/.pyenv`, `~/.local`, `~/.platformio` or `~/.lmstudio`.
6. A project modified today shows the amber `active` chip.
7. Cross-check one row against the shell, e.g. `du -sh ~/Library/Developer/Xcode/DerivedData`, and confirm the panel figure is in the same ballpark (allocated vs apparent size differ slightly by design).

- [ ] **Step 7: Verify one reclaim end to end**

Pick a **low-stakes** row — a `node_modules` in a project you are not working on.

1. Click its button once; it reads `Sure?`.
2. Click again.
3. Confirm the row disappears and the directory is gone from disk (`ls` the path).
4. Confirm it is present in `~/.Trash`.
5. Confirm the footer `Trash:` figure grew.
6. Click `Empty`, confirm `~/.Trash` is emptied and `df -h /System/Volumes/Data` shows the space returned.

- [ ] **Step 8: Screenshot the result**

```bash
osascript -e 'tell application "System Events" to tell process "Stray" to click menu bar item 1 of menu bar 2'
screencapture -x -R 870,20,440,700 ~/Desktop/stray-disk.png
```
Look at the screenshot — confirm both sections render and nothing is clipped.

- [ ] **Step 9: Commit (gated)**

```bash
git add Stray/UI/MenuView.swift
git commit -m "feat: add disk section with progressive sizes and trash controls"
```

---

## Self-Review

**Spec coverage:** `CacheCatalog` → Task 2. `DiskScanner` incl. sibling markers and dot-dir rule → Task 3. `SizeProbe` incl. symlink and concurrency rules → Task 4. `Reclaimer` guard → Task 1, actions → Task 5. Model changes (`bytes`, new kinds) → Task 6. Data flow (discover → publish → size progressively → sort) → Task 6 Step 3. UI (two sections, reclaimable total, active chip, Trash+Empty) → Task 7. Error handling (per-row, non-aborting) → Task 6 Steps 3–4 via `try?` per row. Testing (`assertSafe`, catalog validation, match rules) → Tasks 1–3.

**Deviations from the spec, deliberate:** the spec listed `~/.gradle`; the catalog uses `~/.gradle/caches` because `~/.gradle` also holds `gradle.properties` and wrapper configuration. `Finding.severity` for disk rows is `.info`, so the existing dot renders orange rather than red — disk findings are not urgent the way an orphaned process is.

**Type consistency:** `assertSafe(_:scanRoots:)` keeps the same signature in Tasks 1 and 5. `SizeProbe.size(of:)` / `sizes(for:onResult:)` are used with those exact names in Task 6. `CacheEntry.name` is the join key used by `resolveCache`, matching `cacheFinding`'s `title: entry.name`.
