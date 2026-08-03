import Testing
import Foundation
@testable import Stray

@Test func catalogIDsAreUnique() {
    let ids = CacheCatalog.all.map(\.id)
    #expect(Set(ids).count == ids.count)
}

@Test func catalogNamesAreUnique() {
    // `ScanEngine.resolveCache` joins a `Finding` back to its `CacheEntry` by `name`
    // (see the comment there for why) rather than a dedicated key. A duplicate name
    // would make that join silently pick the wrong entry — and therefore reclaim the
    // wrong cache — so this enforces the invariant the join key relies on.
    let names = CacheCatalog.all.map(\.name)
    #expect(Set(names).count == names.count)
}

@Test func catalogEntriesAreWellFormed() {
    for entry in CacheCatalog.all {
        #expect(!entry.id.isEmpty)
        #expect(!entry.name.isEmpty)
        #expect(!entry.regeneratedBy.isEmpty)
        // Entries reclaimed via a CLI subcommand (e.g. `docker image prune`) operate
        // on no fixed filesystem path, so `paths` is legitimately empty for those.
        if entry.reclaim != .dockerImagePrune {
            #expect(!entry.paths.isEmpty)
        }
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
    // `present()` includes an entry when at least one of its paths exists (see its
    // `contains` filter), not when all of them do — relevant now that some entries
    // (e.g. Yarn) list multiple candidate locations for the same cache.
    for entry in CacheCatalog.present() where entry.reclaim == .trash {
        #expect(entry.paths.contains { FileManager.default.fileExists(atPath: $0.path) })
    }
}
