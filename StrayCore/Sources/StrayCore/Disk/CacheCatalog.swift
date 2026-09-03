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
                   paths: [h(".yarn-cache"), h("Library/Caches/Yarn")], reclaim: .trash,
                   regeneratedBy: "Next yarn install"),
        CacheEntry(id: "pkg.pnpm", name: "pnpm store",
                   paths: [h("Library/pnpm/store")], reclaim: .trash,
                   regeneratedBy: "pnpm repopulates the store as packages are reinstalled — existing node_modules symlink into this store and will need reinstalling"),
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
                   regeneratedBy: "Re-downloaded by the tools that wrote it — can be a large download if ML tool caches (e.g. huggingface, torch) live here"),
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
