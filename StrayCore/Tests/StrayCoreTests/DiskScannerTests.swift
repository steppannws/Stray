import Testing
import Foundation
@testable import StrayCore

@Test func nodeModulesMatchesWithoutMarker() {
    #expect(DiskScanner.isMatch(name: "node_modules", siblings: []))
}

@Test func nextAndPycacheMatchWithoutMarker() {
    #expect(DiskScanner.isMatch(name: ".next", siblings: []))
    #expect(DiskScanner.isMatch(name: "__pycache__", siblings: []))
}

@Test func venvRequiresAPythonManifest() {
    // Unlike `.next`/`__pycache__`, the name alone doesn't prove regenerability: a
    // `.venv` with no manifest means nobody recorded what was installed, so deleting it
    // is not a rebuild — the same category as `~/.pyenv`, which the catalog excludes.
    #expect(DiskScanner.isMatch(name: ".venv", siblings: ["requirements.txt"]))
    #expect(DiskScanner.isMatch(name: ".venv", siblings: ["pyproject.toml"]))
    #expect(DiskScanner.isMatch(name: ".venv", siblings: ["Pipfile"]))
    #expect(DiskScanner.isMatch(name: ".venv", siblings: ["poetry.lock"]))
    #expect(DiskScanner.isMatch(name: ".venv", siblings: ["setup.py"]))
    #expect(DiskScanner.isMatch(name: ".venv", siblings: ["environment.yml"]))
    #expect(!DiskScanner.isMatch(name: ".venv", siblings: []))
    #expect(!DiskScanner.isMatch(name: ".venv", siblings: ["README.md"]))
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

@Test func scanFindsDotPrefixedAndMarkerGatedMatches() throws {
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser
    let root = home.appendingPathComponent(".stray-scan-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }

    let project = root.appendingPathComponent("proj")
    try fm.createDirectory(at: project.appendingPathComponent(".next"), withIntermediateDirectories: true)
    try fm.createDirectory(at: project.appendingPathComponent("Pods"), withIntermediateDirectories: true)
    try fm.createDirectory(at: project.appendingPathComponent("build"), withIntermediateDirectories: true)
    fm.createFile(atPath: project.appendingPathComponent("Podfile").path, contents: nil)
    fm.createFile(atPath: project.appendingPathComponent("build.gradle").path, contents: nil)

    let hits = Set(DiskScanner.scan(roots: [root]).map(\.standardizedFileURL.path))

    // `.next` proves the dot-skip guard lets a known dot-prefixed name through walk().
    // `Pods` and `build` prove siblings are read from the target's own parent directory
    // (not the target directory's own contents), so marker-gated matching actually works
    // end to end rather than only in the pure `isMatch` check.
    #expect(hits == Set([
        project.appendingPathComponent(".next").standardizedFileURL.path,
        project.appendingPathComponent("Pods").standardizedFileURL.path,
        project.appendingPathComponent("build").standardizedFileURL.path,
    ]))
}

@Test func scanPrunesTopLevelLibraryButWalksNestedLibrary() throws {
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser
    let root = home.appendingPathComponent(".stray-scan-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }

    // Top-level Library (a direct child of the scan root) must be pruned entirely —
    // its node_modules must never be reported, proving the exclusion skips descendants
    // rather than merely skipping the Library directory node itself.
    try fm.createDirectory(at: root.appendingPathComponent("Library/node_modules"),
                           withIntermediateDirectories: true)

    // A Library directory nested inside a project is not a direct child of the scan
    // root, so it must NOT be pruned — proving the exclusion is top-level-only.
    let nestedNodeModules = root.appendingPathComponent("proj/Library/node_modules")
    try fm.createDirectory(at: nestedNodeModules, withIntermediateDirectories: true)

    let hits = Set(DiskScanner.scan(roots: [root]).map(\.standardizedFileURL.path))

    #expect(hits == Set([nestedNodeModules.standardizedFileURL.path]))
}

@Test func scanPrunesAManifestLessVenvInsteadOfWalkingInto() throws {
    // A `.venv` with no Python manifest fails `isMatch`'s sibling gate, so it is not
    // itself a finding — but that must not turn it into an open door. Before the walk
    // pruned on a rule-name match regardless of gate outcome, the enumerator descended
    // into a gate-failed `.venv` and reported its interior (`node_modules`, `__pycache__`)
    // as independent findings — exactly the harm the manifest gate exists to prevent,
    // reachable one level deeper. This must yield nothing at all.
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser
    let root = home.appendingPathComponent(".stray-scan-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }

    let venv = root.appendingPathComponent("proj/.venv")
    try fm.createDirectory(at: venv.appendingPathComponent("lib/python3.12/site-packages/somepkg/node_modules"),
                           withIntermediateDirectories: true)
    try fm.createDirectory(at: venv.appendingPathComponent("lib/python3.12/site-packages/otherpkg/__pycache__"),
                           withIntermediateDirectories: true)
    // Deliberately no requirements.txt / pyproject.toml / etc. next to .venv.

    let hits = DiskScanner.scan(roots: [root])

    #expect(hits.isEmpty)
}

@Test func scanSkipsASymlinkedNodeModules() throws {
    // The walk's symlink guard is currently inherited from `FileManager`'s enumerator
    // default rather than independently enforced (see the comment in `walk`). This
    // exercises it end to end: a `node_modules` that is actually a symlink to a real
    // directory must never be returned, since the output feeds `reclaimPaths` directly.
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser
    let root = home.appendingPathComponent(".stray-scan-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }

    let project = root.appendingPathComponent("proj")
    let realTarget = root.appendingPathComponent("real-target")
    try fm.createDirectory(at: project, withIntermediateDirectories: true)
    try fm.createDirectory(at: realTarget, withIntermediateDirectories: true)

    let symlink = project.appendingPathComponent("node_modules")
    try fm.createSymbolicLink(at: symlink, withDestinationURL: realTarget)

    let hits = DiskScanner.scan(roots: [root])

    #expect(hits.isEmpty)
}
