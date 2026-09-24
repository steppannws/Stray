import Sparkle
import SwiftUI
import StrayCore

@main
struct StrayApp: App {
    @StateObject private var engine = ScanEngine()
    /// Starts Sparkle's scheduled background checks against `SUFeedURL` at launch.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
    )

    var body: some Scene {
        MenuBarExtra {
            MenuView(updater: updaterController.updater)
                .environmentObject(engine)
        } label: {
            // Badge on the icon: number of findings
            if engine.findings.isEmpty {
                Image(systemName: "pawprint")
            } else {
                Image(systemName: "pawprint.fill")
                Text("\(engine.findings.count)")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
