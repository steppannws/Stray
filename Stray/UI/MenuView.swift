import SwiftUI
import StrayCore

struct MenuView: View {
    @EnvironmentObject var engine: ScanEngine
    @State private var tab: Tab = .ports
    @State private var showEmptyTrashConfirmation = false

    /// The three things Stray does. They used to be stacked in one scroll view, which
    /// gave each about a third of the height and made all three hard to read at once;
    /// one at a time, each gets the whole panel. The counts on the tabs are what stops
    /// that from hiding anything — a finding in a tab you are not looking at still
    /// announces itself.
    private enum Tab: String, CaseIterable, Identifiable {
        case ports = "Ports"
        case processes = "Processes"
        case disk = "Disk"

        var id: Self { self }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            tabPicker
            // Pinned above the scroll view, so the disk controls stay reachable no
            // matter how long the list below them gets.
            if tab == .disk {
                Divider()
                diskToolbar
            }
            Divider()
            ScrollView { rows }
                .frame(maxHeight: 420)
            if let lastError = engine.lastError {
                Divider()
                errorBanner(lastError)
            }
            Divider()
            footer
        }
        .frame(width: 420)
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
            .help("Rescan processes and ports")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var tabPicker: some View {
        Picker("", selection: $tab) {
            ForEach(Tab.allCases) { tab in
                Text(label(for: tab)).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// A tab's name, plus what it is holding. The badge is deliberately absent rather
    /// than "0" when a tab is empty: an empty tab is the normal state and should not
    /// read as a number worth checking.
    ///
    /// Built as a `String` rather than interpolated into `Text` so the counts are not
    /// run through number formatting — a port list of "1,024" would be wrong twice.
    private func label(for tab: Tab) -> String {
        switch tab {
        case .ports:
            return engine.ports.isEmpty ? "Ports" : "Ports \(engine.ports.count)"
        case .processes:
            return engine.findings.isEmpty ? "Processes" : "Processes \(engine.findings.count)"
        case .disk:
            guard !engine.diskFindings.isEmpty else { return "Disk" }
            let total = ByteCountFormatter.string(fromByteCount: engine.reclaimableBytes,
                                                  countStyle: .file)
            return "Disk " + total
        }
    }

    @ViewBuilder
    private var rows: some View {
        switch tab {
        case .ports: portRows
        case .processes: findingRows
        case .disk: diskRows
        }
    }

    @ViewBuilder
    private var portRows: some View {
        if engine.ports.isEmpty {
            emptyState(
                icon: "bolt.horizontal.circle",
                title: "Nothing listening",
                detail: "Node, Bun and Deno servers appear here with the port they hold."
            )
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(engine.ports) { row in
                    PortListRow(row: row) { engine.terminate(row) }
                    Divider().padding(.leading, 12)
                }
            }
        }
    }

    @ViewBuilder
    private var findingRows: some View {
        if engine.findings.isEmpty {
            emptyState(
                icon: "checkmark.circle",
                tint: .green,
                title: "No stray processes",
                detail: "Orphaned MCP servers, duplicates and long-dead dev tools show up here."
            )
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(engine.findings) { finding in
                    FindingRow(finding: finding) { engine.resolve(finding) }
                    Divider().padding(.leading, 12)
                }
            }
        }
    }

    @ViewBuilder
    private var diskRows: some View {
        if engine.diskFindings.isEmpty {
            emptyState(
                icon: engine.lastDiskScan == nil ? "internaldrive" : "checkmark.circle",
                tint: engine.lastDiskScan == nil ? .secondary : .green,
                title: engine.lastDiskScan == nil ? "Not scanned yet" : "Nothing to reclaim",
                detail: engine.lastDiskScan == nil
                    ? "Scanning walks your project trees and tool caches. It is never automatic."
                    : "Build artifacts, dependency trees and tool caches would be listed here."
            )
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(engine.diskFindings) { finding in
                    FindingRow(finding: finding) { engine.resolve(finding) }
                    Divider().padding(.leading, 12)
                }
            }
        }
    }

    /// Disk scanning is manual and slow, so its controls live with the list they govern
    /// rather than in the global footer, where they sat next to two tabs that have
    /// nothing to do with the disk.
    private var diskToolbar: some View {
        HStack(spacing: 8) {
            if engine.isDiskScanning {
                ProgressView().controlSize(.small)
            }
            if !engine.diskFindings.isEmpty {
                Text("Reclaimable: " + ByteCountFormatter.string(
                    fromByteCount: engine.reclaimableBytes, countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            emptyTrashButton
            Button("Scan disk") { engine.scanDisk() }
                .buttonStyle(.borderless).font(.caption)
                .disabled(engine.isDiskScanning)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Unlike `ConfirmButton`'s two-step inline confirm — appropriate for a single row,
    /// whose result lands in the Trash and is recoverable — this action is global and
    /// permanent: it destroys the *entire* Trash, including items Stray never touched
    /// and the user put there for unrelated reasons. A same-label, two-click inline
    /// confirm is exactly the shape an automation or accessibility harness reads as "the
    /// click didn't land" and retries, and the retry fires the destructive action. A
    /// modal `.confirmationDialog` forces an explicit, distinctly-labelled choice.
    @ViewBuilder
    private var emptyTrashButton: some View {
        if !engine.diskFindings.isEmpty || engine.lastDiskScan != nil {
            Button("Empty Trash") {
                showEmptyTrashConfirmation = true
            }
            .buttonStyle(.borderless).font(.caption)
            .help("Asks Finder to empty the Trash. macOS will prompt once to allow Stray to control Finder.")
            .confirmationDialog(
                "Empty the Trash?",
                isPresented: $showEmptyTrashConfirmation,
                titleVisibility: .visible
            ) {
                Button("Empty Trash", role: .destructive) {
                    engine.emptyTrash()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently deletes everything currently in the Trash, not just what Stray found. This cannot be undone.")
            }
        }
    }

    /// One shape for every empty tab, so "nothing here" always looks the same and never
    /// looks like a failure. The detail line says what *would* be here, which is the
    /// part that tells a first-time reader what the tab is for.
    private func emptyState(
        icon: String,
        tint: Color = .secondary,
        title: String,
        detail: String
    ) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title2).foregroundStyle(tint)
            Text(title).font(.callout)
            Text(detail)
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.vertical, 32)
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
        .padding(.horizontal, 12)
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
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless).font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// One listening port and the dev server holding it.
///
/// Unlike `FindingRow` this is an inventory row, not a judgement, so it carries no
/// severity dot — nothing in this list is being called a problem. The command line is a
/// tooltip rather than a third line: at a glance the port, the script and the project
/// are what tell two dev servers apart, and the full argv only matters when something
/// looks wrong.
struct PortListRow: View {
    let row: PortRow
    let onKill: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // `String(row.port)` rather than interpolating the number directly: a `Text`
            // interpolation of an integer is localized, and ":3,000" is not a port.
            Text(":" + String(row.port))
                .font(.system(.callout, design: .monospaced))
                .frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).font(.callout).fontWeight(.medium)
                Text(row.subtitle)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            ConfirmButton(label: "Kill", action: onKill)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .help(row.command)
    }
}

struct FindingRow: View {
    let finding: Finding
    let onResolve: () -> Void

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
                    // Tool-cache rows use `detail` as the only place the UI states what a
                    // deletion costs (`CacheCatalog.regeneratedBy`) — for the entries with
                    // real cost, that warning sits in the tail and must not be truncated.
                    // `.help` still surfaces the full text on hover for the 2-line kinds.
                    .lineLimit(finding.kind == .toolCache ? nil : 2)
                    .help(finding.detail)
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
            Spacer(minLength: 8)
            ConfirmButton(label: actionLabel, action: onResolve)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var severityDot: some View {
        Circle()
            .fill(finding.severity == .strong ? .red : .orange)
            .frame(width: 7, height: 7)
            .padding(.top, 5)
    }

    private var actionLabel: String {
        switch finding.kind {
        case .orphanLaunchd: return "Clean"
        case .duplicate: return "Kill \(finding.extraPIDs.count + 1)"
        // Derived from the reclaim method, not the kind: `xcode.simulators` (simctl) and
        // `docker.dangling` (docker image prune) are both `.toolCache` but permanent —
        // labeling them "Trash" would falsely promise recoverability.
        case .projectJunk, .toolCache: return finding.isReversible ? "Trash" : "Clean"
        default: return "Kill"
        }
    }
}

/// The two-step confirm every row-level destructive action uses: the first click arms
/// the button and relabels it, the second performs the action, and it disarms itself
/// after three seconds so an armed button is never left lying around for a later,
/// unrelated click to land on.
///
/// Shared by `FindingRow` and `PortListRow` so the gesture that kills a process is the
/// same one wherever it appears. The heavier modal confirm is reserved for actions that
/// are global and permanent — see `MenuView.emptyTrashButton`.
struct ConfirmButton: View {
    let label: String
    let action: () -> Void
    @State private var confirming = false

    var body: some View {
        Button(confirming ? "Sure?" : label) {
            if confirming {
                action()
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
}
