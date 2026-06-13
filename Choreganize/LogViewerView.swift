import SwiftUI

struct LogViewerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var logs: [String] = []
    @State private var selectedLevel: LogLevel = Log.currentLevel

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Verbosity", selection: $selectedLevel) {
                    ForEach(LogLevel.allCases, id: \.self) { level in
                        Text(String(describing: level).capitalized).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                .padding([.horizontal, .top])
                .onChange(of: selectedLevel) { _, _ in
                    Task { await refresh() }
                }

                Divider()

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(logs.enumerated()), id: \.offset) { idx, line in
                                Text(line)
                                    .font(.system(.footnote, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(idx)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: logs.count) { _, newCount in
                        withAnimation { proxy.scrollTo(max(newCount - 1, 0), anchor: .bottom) }
                    }
                }
            }
            .navigationTitle("Logs")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: exportText) { Image(systemName: "square.and.arrow.up") }
                        .disabled(logs.isEmpty)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh") { Task { await refresh() } }
                }
            }
            .task { await refresh() }
        }
    }

    /// The currently-shown log lines as shareable text (system share sheet =
    /// copy, AirDrop, Messages, Save to Files, …). Captures the full in-memory
    /// buffer that a device `log collect` can't see.
    private var exportText: String {
        let header = "Choreganize logs — \(logs.count) lines @ \(String(describing: selectedLevel)) level"
        return ([header, String(repeating: "—", count: 24)] + logs).joined(separator: "\n")
    }

    private func refresh() async {
        logs = await Log.bufferSnapshot(minLevel: selectedLevel)
    }
}

#Preview {
    LogViewerView()
}
