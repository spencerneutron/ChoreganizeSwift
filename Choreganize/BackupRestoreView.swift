import SwiftUI
import CoreData
import UniformTypeIdentifiers

/// JSON document wrapper for the backup file exporter (#63).
struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Back up the user's **Personal** chores/areas/completion history to a JSON file (Files /
/// iCloud Drive) and restore from one (#63). Restore is a non-destructive UUID merge.
///
/// Uses the shared main context directly (`CoreDataStack.shared.viewContext`) so it works
/// regardless of how this view is presented (the Hub sheet doesn't propagate the
/// environment's managed-object context).
struct BackupRestoreView: View {
    private var context: NSManagedObjectContext { CoreDataStack.shared.viewContext }

    @State private var document: BackupDocument?
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var pendingURL: URL?
    @State private var confirmRestore = false
    @State private var result: ResultInfo?

    // CG-20 / #102: automatic scheduled backups (Plus).
    @ObservedObject private var entitlements = EntitlementStore.shared
    @AppStorage(AutoBackup.Keys.enabled) private var autoEnabled = false
    @AppStorage(AutoBackup.Keys.cadence) private var autoCadenceRaw = AutoBackupPolicy.Cadence.weekly.rawValue
    @State private var autoBackupFiles: [URL] = []
    @State private var lastAutoBackup: Date?

    private struct ResultInfo: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    var body: some View {
        Form {
            Section {
                Button {
                    exportNow()
                } label: {
                    Label("Export Backup…", systemImage: "square.and.arrow.up")
                }
            } header: {
                Text("Back Up")
            } footer: {
                Text("Saves your Personal chores, areas, and completion history to a JSON file in Files or iCloud Drive.")
            }

            Section {
                Button {
                    showImporter = true
                } label: {
                    Label("Restore from Backup…", systemImage: "square.and.arrow.down")
                }
            } header: {
                Text("Restore")
            } footer: {
                Text("Merges chores and history from a backup into your Personal data. Items with the same ID are updated, never duplicated — and nothing is deleted.")
            }

            // CG-20 / #102: automatic scheduled backups (Plus). Personal-scope
            // like the manual export, and gated on the user's OWN entitlement
            // (not the household flag) — it backs up their Personal data.
            Section {
                if entitlements.isPlus {
                    Toggle("Automatic backups", isOn: $autoEnabled)
                    if autoEnabled {
                        Picker("Frequency", selection: $autoCadenceRaw) {
                            ForEach(AutoBackupPolicy.Cadence.allCases) { cadence in
                                Text(cadence.displayName).tag(cadence.rawValue)
                            }
                        }
                        LabeledContent("Last backup",
                                       value: lastAutoBackup?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
                    }
                } else {
                    Label("Automatic backups", systemImage: "lock")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Automatic Backups")
            } footer: {
                Text(entitlements.isPlus
                     ? "Backs up your Personal data on a schedule. Files are kept in Files ▸ On My iPhone ▸ Choreganize ▸ Backups; only the \(AutoBackupPolicy.keepCount) most recent are kept. Household chores already live in iCloud and sync to every member, so they're covered automatically."
                     : "Back up your Personal data automatically on a schedule. Requires Choreganize Plus (Hub ▸ Get Choreganize Plus). Household chores already live in iCloud and sync to every member, so they're covered automatically.")
            }

            if entitlements.isPlus && !autoBackupFiles.isEmpty {
                Section {
                    ForEach(autoBackupFiles, id: \.self) { url in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Self.backupDayLabel(for: url))
                                Text(url.lastPathComponent)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            // Same confirm-then-merge flow as a picked file:
                            // restore is a UUID upsert, never a wipe.
                            Button("Restore…") {
                                pendingURL = url
                                confirmRestore = true
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .onDelete(perform: deleteAutoBackups)
                } header: {
                    Text("Automatic Backup Files")
                } footer: {
                    Text("Swipe left to delete a backup file.")
                }
            }
        }
        .navigationTitle("Backup & Restore")
        .navigationBarTitleDisplayMode(.inline)
        .task { refreshAutoBackups() }
        .onChange(of: autoEnabled) { _, isOn in
            AutoBackup.scheduleNextIfEnabled()   // cancels the pending request when off
            if isOn {
                // First enable has no lastBackupDate, so this takes the initial
                // backup right away — instant feedback in the list below.
                AutoBackup.runCatchUpIfDue { _ in refreshAutoBackups() }
            }
        }
        .onChange(of: autoCadenceRaw) { _, _ in
            AutoBackup.scheduleNextIfEnabled()
        }
        .fileExporter(isPresented: $showExporter, document: document, contentType: .json,
                      defaultFilename: Self.defaultFilename) { outcome in
            switch outcome {
            case .success:
                result = ResultInfo(title: "Backup saved", message: "Your Personal data was exported.")
            case .failure(let error):
                result = ResultInfo(title: "Export failed", message: error.localizedDescription)
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { outcome in
            switch outcome {
            case .success(let url):
                pendingURL = url
                confirmRestore = true
            case .failure(let error):
                result = ResultInfo(title: "Couldn’t open file", message: error.localizedDescription)
            }
        }
        .confirmationDialog("Restore this backup?", isPresented: $confirmRestore, titleVisibility: .visible) {
            Button("Restore") { restore() }
            Button("Cancel", role: .cancel) { pendingURL = nil }
        } message: {
            Text("Chores and history from the file will be merged into your Personal data. Matching items are updated; nothing is deleted.")
        }
        .alert(item: $result) { info in
            Alert(title: Text(info.title), message: Text(info.message), dismissButton: .default(Text("OK")))
        }
    }

    private static var defaultFilename: String {
        "Choreganize-Backup-\(Date().formatted(.iso8601.year().month().day()))"
    }

    // MARK: Automatic backups (CG-20 / #102)

    /// Row title for an auto-backup file: its backup day, from the filename.
    private static func backupDayLabel(for url: URL) -> String {
        AutoBackupPolicy.date(fromFilename: url.lastPathComponent)?
            .formatted(date: .abbreviated, time: .omitted) ?? url.lastPathComponent
    }

    private func refreshAutoBackups() {
        autoBackupFiles = AutoBackup.listBackupFiles()
        lastAutoBackup = AutoBackup.lastBackupDate
    }

    private func deleteAutoBackups(at offsets: IndexSet) {
        for index in offsets {
            AutoBackup.deleteBackupFile(at: autoBackupFiles[index])
        }
        refreshAutoBackups()
    }

    private func exportNow() {
        do {
            document = BackupDocument(data: try BackupCodec.exportData(in: context))
            showExporter = true
        } catch {
            result = ResultInfo(title: "Export failed", message: error.localizedDescription)
        }
    }

    private func restore() {
        guard let url = pendingURL else { return }
        defer { pendingURL = nil }
        // Imported files come from the security-scoped Files provider.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let summary = try BackupCodec.restore(try Data(contentsOf: url), into: context)
            result = ResultInfo(
                title: "Restore complete",
                message: "Imported \(summary.chores) chores, \(summary.areas) areas, and \(summary.completions) completions.")
        } catch {
            result = ResultInfo(title: "Restore failed", message: error.localizedDescription)
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack { BackupRestoreView() }
}
#endif
