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
    for entry in CacheCatalog.present() where entry.reclaim == .trash {
        #expect(entry.paths.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }
}
