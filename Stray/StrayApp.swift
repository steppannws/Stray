import SwiftUI

@main
struct StrayApp: App {
    @StateObject private var engine = ScanEngine()

    var body: some Scene {
        MenuBarExtra {
            MenuView()
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
