import SwiftUI
import StrayCore

/// Everything Stray has been told not to flag, editable in place.
///
/// Shown in the panel instead of a Settings window: a menu bar app's Settings window
/// opens behind whatever is frontmost, and the panel is where the ignores were added
/// from in the first place.
struct IgnoreListView: View {
    @EnvironmentObject var engine: ScanEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Right-click a finding to ignore it. This list shows everything Stray ignores.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            section("Rules") {
                ForEach(FindingKind.allCases, id: \.self) { kind in
                    Toggle(kind.rawValue, isOn: Binding(
                        get: { !engine.whitelist.ignoredKinds.contains(kind) },
                        set: { on in
                            engine.updateWhitelist {
                                if on { $0.ignoredKinds.remove(kind) } else { $0.ignoredKinds.insert(kind) }
                            }
                        }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.caption)
                }
            }

            section("Ignored commands") {
                EditableStringList(
                    entries: engine.whitelist.ignoredCommands,
                    placeholder: "Text in the command line, e.g. context7-mcp",
                    onChange: { list in engine.updateWhitelist { $0.ignoredCommands = list } }
                )
            }

            section("Ignored paths") {
                EditableStringList(
                    entries: engine.whitelist.ignoredPaths,
                    placeholder: "A folder or file. Stray ignores everything inside it.",
                    onChange: { list in engine.updateWhitelist { $0.ignoredPaths = list } }
                )
            }

            section("Extra MCP patterns") {
                EditableStringList(
                    entries: engine.whitelist.extraMCPPatterns,
                    placeholder: "Text that marks a process as MCP tooling",
                    onChange: { list in engine.updateWhitelist { $0.extraMCPPatterns = list } }
                )
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).fontWeight(.semibold)
            content()
        }
    }
}

/// A list of strings with a remove button per entry and a field to add one. Stateless
/// about the list itself: every edit goes out through `onChange`, and what comes back in
/// `entries` is the normalized result.
private struct EditableStringList: View {
    let entries: [String]
    let placeholder: String
    let onChange: ([String]) -> Void
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(entries, id: \.self) { entry in
                HStack(spacing: 6) {
                    Text(entry)
                        .font(.caption.monospaced())
                        .lineLimit(1).truncationMode(.middle)
                        .help(entry)
                    Spacer()
                    Button {
                        onChange(entries.filter { $0 != entry })
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Stop ignoring")
                }
            }
            TextField(placeholder, text: $draft)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .onSubmit {
                    onChange(entries + [draft])
                    draft = ""
                }
        }
    }
}
