import ServiceManagement
import SwiftUI

/// "Open at login", backed by `SMAppService.mainApp`.
///
/// The system owns this state, not the app: the user can remove Stray from System
/// Settings → General → Login Items at any time. So nothing is stored here — the status
/// is re-read every time the panel appears, and the toggle only ever shows what
/// `SMAppService` reports back after a change.
struct LaunchAtLoginToggle: View {
    @State private var status = SMAppService.mainApp.status
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle("Open at login", isOn: Binding(
                get: { status == .enabled || status == .requiresApproval },
                set: { setEnabled($0) }
            ))
            .toggleStyle(.checkbox)
            .font(.caption)

            // Registered, but the user has not allowed it yet — without this the
            // checkbox reads as on while Stray will not actually start at login.
            if status == .requiresApproval {
                Button("Allow in Login Items…") {
                    SMAppService.openSystemSettingsLoginItems()
                }
                .buttonStyle(.link)
                .font(.caption2)
            }
            if let error {
                Text(error).font(.caption2).foregroundStyle(.red)
            }
        }
        .onAppear { status = SMAppService.mainApp.status }
    }

    private func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        status = SMAppService.mainApp.status
    }
}
