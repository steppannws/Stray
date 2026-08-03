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
