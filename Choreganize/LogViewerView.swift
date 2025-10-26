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
                .onChange(of: selectedLevel) { _, newValue in
                    Log.setLevel(newValue)
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
                    Button("Refresh") { Task { await refresh() } }
                }
            }
            .task { await refresh() }
        }
    }

    private func refresh() async {
        logs = await Log.bufferSnapshot()
    }
}

#Preview {
    LogViewerView()
}
