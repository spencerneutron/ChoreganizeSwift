import SwiftUI
import CoreData

/// CG-11 / #64 — sheet for moving Personal chores & areas into the Household.
///
/// Whole rooms are selected as a unit (a partial room would leave cross-zone
/// relationships behind — see `HouseholdMigration.closure`); loose chores are
/// individually selectable. The footer explains what will happen, which
/// differs by role: owners MOVE items, participants ADD COPIES and keep their
/// Personal originals.
struct MigrationPickerView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @FetchRequest(sortDescriptors: [NSSortDescriptor(key: "name", ascending: true)])
    private var allAreas: FetchedResults<CDArea>
    @FetchRequest(sortDescriptors: [NSSortDescriptor(key: "name", ascending: true)])
    private var allChores: FetchedResults<CDChore>

    @State private var selectedAreas = Set<NSManagedObjectID>()
    @State private var selectedChores = Set<NSManagedObjectID>()
    @State private var working = false
    @State private var errorMessage: String?

    private var personalAreas: [CDArea] { Array(allAreas).inScope(nil) }
    /// Loose chores only — chores in a room ride along with the room.
    private var personalLooseChores: [CDChore] {
        Array(allChores).inScope(nil).filter { $0.area == nil }
    }

    private var household: CDHousehold? { model.resolvedHousehold }
    private var mode: HouseholdMigration.Mode? {
        household.map { HouseholdMigration.mode(for: $0) }
    }
    private var selectionCount: Int { selectedAreas.count + selectedChores.count }

    var body: some View {
        NavigationStack {
            Group {
                if personalAreas.isEmpty && personalLooseChores.isEmpty {
                    ContentUnavailableView(
                        "Nothing to Add",
                        systemImage: "tray",
                        description: Text("You don't have any Personal rooms or chores to bring into the household.")
                    )
                } else {
                    pickerList
                }
            }
            .navigationTitle(mode == .participantCopy ? "Add to Household" : "Move to Household")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmTitle) { migrate() }
                        .disabled(selectionCount == 0 || working || household == nil)
                }
            }
            .interactiveDismissDisabled(working)
            .overlay {
                if working { ProgressView().controlSize(.large) }
            }
            .alert("Couldn't Migrate", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "Unknown error")
            }
        }
    }

    private var pickerList: some View {
        List {
            if !personalAreas.isEmpty {
                Section {
                    ForEach(personalAreas, id: \.objectID) { area in
                        selectableRow(
                            title: area.name ?? "Room",
                            subtitle: choreCountLabel(area.choresArray.count),
                            systemImage: "square.split.bottomrightquarter",
                            isContributed: contributed(area.id),
                            isSelected: selectedAreas.contains(area.objectID)
                        ) { toggle(area.objectID, in: &selectedAreas) }
                    }
                } header: {
                    Text("Rooms")
                } footer: {
                    Text("A room brings all of its chores and history with it.")
                }
            }
            if !personalLooseChores.isEmpty {
                Section("Chores without a room") {
                    ForEach(personalLooseChores, id: \.objectID) { chore in
                        selectableRow(
                            title: chore.name ?? "Chore",
                            subtitle: nil,
                            systemImage: "checkmark.circle",
                            isContributed: contributed(chore.id),
                            isSelected: selectedChores.contains(chore.objectID)
                        ) { toggle(chore.objectID, in: &selectedChores) }
                    }
                }
            }
            Section {
                EmptyView()
            } footer: {
                Text(explainer)
            }
        }
    }

    private func selectableRow(title: String, subtitle: String?, systemImage: String,
                               isContributed: Bool, isSelected: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isContributed {
                    Text("Added")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                }
            }
        }
        .foregroundStyle(.primary)
        .disabled(isContributed)
    }

    private var confirmTitle: String {
        let base = mode == .participantCopy ? "Add" : "Move"
        return selectionCount > 0 ? "\(base) \(selectionCount)" : base
    }

    private var explainer: String {
        switch mode {
        case .participantCopy:
            return "Copies of the selected items are added to \(model.householdName) for everyone. Your Personal originals stay untouched."
        default:
            return "The selected items move from Personal into \(model.householdName). Household members will see them once the household is shared."
        }
    }

    /// Participant provenance ("Added" tag). Owners moved items out of
    /// Personal entirely, so an owner's migrated items simply aren't listed.
    private func contributed(_ id: UUID?) -> Bool {
        guard mode == .participantCopy, let household,
              let ctx = household.managedObjectContext else { return false }
        return HouseholdMigration.isContributed(id, in: ctx)
    }

    private func choreCountLabel(_ count: Int) -> String {
        count == 1 ? "1 chore" : "\(count) chores"
    }

    private func toggle(_ id: NSManagedObjectID, in set: inout Set<NSManagedObjectID>) {
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
    }

    private func migrate() {
        guard let household else { return }
        let selection = HouseholdMigration.Selection(
            areas: personalAreas.filter { selectedAreas.contains($0.objectID) },
            chores: personalLooseChores.filter { selectedChores.contains($0.objectID) }
        )
        working = true
        Task { @MainActor in
            do {
                let outcome = try await HouseholdMigration.migrate(selection, into: household)
                working = false
                dismiss()
                let verb = outcome.mode == .participantCopy ? "Added" : "Moved"
                var message = "\(verb) \(outcome.migratedRoots) item\(outcome.migratedRoots == 1 ? "" : "s") to \(model.householdName)."
                if outcome.skippedRoots > 0 {
                    message += " \(outcome.skippedRoots) already added."
                }
                model.showBanner(message: message, style: .success)
            } catch {
                working = false
                errorMessage = error.localizedDescription
            }
        }
    }
}
