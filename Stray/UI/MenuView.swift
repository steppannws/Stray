import SwiftUI

struct MenuView: View {
    @EnvironmentObject var engine: ScanEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if engine.findings.isEmpty {
                emptyState
            } else {
                findingsList
            }
            Divider()
            footer
        }
        .frame(width: 380)
    }

    private var header: some View {
        HStack {
            Text("Stray").font(.headline)
            Spacer()
            if engine.isScanning {
                ProgressView().controlSize(.small)
            }
            Button {
                engine.scan()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.circle")
                .font(.title2).foregroundStyle(.green)
            Text("No stray processes").font(.callout)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var findingsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(engine.findings) { finding in
                    FindingRow(finding: finding) {
                        engine.resolve(finding)
                    }
                    Divider().padding(.leading, 10)
                }
            }
        }
        .frame(maxHeight: 420)
    }

    private var footer: some View {
        HStack {
            if let last = engine.lastScan {
                Text("Last scan: \(last.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless).font(.caption)
        }
        .padding(8)
    }
}

struct FindingRow: View {
    let finding: Finding
    let onResolve: () -> Void
    @State private var confirming = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            severityDot
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(finding.title).font(.callout).fontWeight(.medium)
                    Text(finding.kind.rawValue)
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                Text(finding.detail)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2)
                if finding.startedAt != nil {
                    Text("Since: \(finding.uptimeDescription)")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            actionButton
        }
        .padding(10)
    }

    private var severityDot: some View {
        Circle()
            .fill(finding.severity == .strong ? .red : .orange)
            .frame(width: 7, height: 7)
            .padding(.top, 5)
    }

    private var actionButton: some View {
        Button(confirming ? "Sure?" : actionLabel) {
            if confirming {
                onResolve()
                confirming = false
            } else {
                confirming = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { confirming = false }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(confirming ? .red : nil)
    }

    private var actionLabel: String {
        switch finding.kind {
        case .orphanLaunchd: return "Clean"
        case .duplicate: return "Kill \(finding.extraPIDs.count + 1)"
        default: return "Kill"
        }
    }
}
