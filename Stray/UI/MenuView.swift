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
            diskSection
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

    private var diskSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Disk").font(.subheadline).fontWeight(.medium)
                Spacer()
                if engine.isDiskScanning {
                    ProgressView().controlSize(.small)
                }
                if engine.diskFindings.isEmpty {
                    Button("Scan disk") { engine.scanDisk() }
                        .buttonStyle(.borderless).font(.caption)
                } else {
                    Text("Reclaimable: \(ByteCountFormatter.string(fromByteCount: engine.reclaimableBytes, countStyle: .file))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(10)

            if let lastError = engine.lastError {
                errorBanner(lastError)
            }

            if !engine.diskFindings.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(engine.diskFindings) { finding in
                            FindingRow(finding: finding) { engine.resolve(finding) }
                            Divider().padding(.leading, 10)
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
        }
    }

    /// A failed reclaim must never look like a silent success — this renders
    /// `engine.lastError` in a way that cannot be missed or mistaken for a normal caption.
    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.red)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.12))
    }

    private var footer: some View {
        HStack {
            if let last = engine.lastScan {
                Text("Last scan: \(last.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if !engine.diskFindings.isEmpty || engine.lastDiskScan != nil {
                Button("Empty Trash") { engine.emptyTrash() }
                    .buttonStyle(.borderless).font(.caption2)
            }
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
                HStack(spacing: 6) {
                    if finding.bytes != nil || finding.kind == .projectJunk || finding.kind == .toolCache {
                        Text(finding.sizeDescription)
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if finding.startedAt != nil {
                        Text("Since: \(finding.uptimeDescription)")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    if finding.isActiveProject {
                        Text("active")
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.orange.opacity(0.25), in: Capsule())
                    }
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
        case .projectJunk, .toolCache: return "Trash"
        default: return "Kill"
        }
    }
}
