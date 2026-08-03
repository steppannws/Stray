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
            // The dot-directory skip only applies to directories encountered during
            // enumeration, never to the root the caller passed in — the enumerator
            // never yields the root itself, but a root whose own name starts with a
            // dot (e.g. a `.stray-scan-*` fixture directory) must still have its
            // contents walked normally.
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
