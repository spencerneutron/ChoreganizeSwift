import SwiftUI
import CoreData

struct EditHomeView: View {
    var body: some View {
        List {
            Section {
                ForEach(AddFlowGrouping.allCases) { lens in
                    NavigationLink {
                        AddFlowFlowView(grouping: lens)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(lens.title)
                                Text(lens == .byArea
                                     ? "Pick a room, then add its chores."
                                     : "Pick a day, then add chores for it.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: lens.systemImage)
                        }
                    }
                }
            } header: {
                Text("Add chores & areas")
            } footer: {
                Text("Add several at once — go room by room, or day by day. You can fine-tune anything afterward below.")
            }

            Section("Manage") {
                NavigationLink("Chores") { ChoreListView() }
                NavigationLink("Areas") { AreaListView() }
            }
        }
    }
}

struct ChoreListView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.editMode) private var editMode
    @EnvironmentObject private var model: AppModel
    @FetchRequest(sortDescriptors: [SortDescriptor(\CDChore.name)]) private var chores: FetchedResults<CDChore>
    @FetchRequest(sortDescriptors: [SortDescriptor(\CDArea.name)]) private var areas: FetchedResults<CDArea>
    @State private var showingNew = false
    @State private var editingChore: CDChore?
    /// Selected chores while in edit mode (multi-select bulk actions).
    @State private var selection = Set<NSManagedObjectID>()
    @State private var showDeleteConfirm = false

    private var isEditing: Bool { editMode?.wrappedValue.isEditing ?? false }

    var body: some View {
        let scoped = chores.inScope(model.activeHousehold)
        let scopedAreas = areas.inScope(model.activeHousehold)
        let daily = scoped.filter { $0.isDaily }

        List(selection: $selection) {
            if !daily.isEmpty {
                Section(header: Text("Every Day")) {
                    ForEach(daily, id: \.objectID) { chore in choreRow(chore) }
                        .onDelete { offsets in delete(daily, at: offsets) }
                }
            }

            ForEach(Weekday.standardCases) { day in
                let choresForDay = scoped.filter { !$0.isDaily && $0.assignedDayValue == day }
                if !choresForDay.isEmpty {
                    Section(header: Text(day.displayName)) {
                        ForEach(choresForDay, id: \.objectID) { chore in choreRow(chore) }
                            .onDelete { offsets in delete(choresForDay, at: offsets) }
                    }
                }
            }

            let unassigned = scoped.filter { !$0.isDaily && $0.assignedDayValue == nil }
            if !unassigned.isEmpty {
                Section(header: Text("Unassigned")) {
                    ForEach(unassigned, id: \.objectID) { chore in choreRow(chore) }
                        .onDelete { offsets in delete(unassigned, at: offsets) }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                if !scoped.isEmpty { EditButton() }
            }
            if isEditing {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu("Move") {
                        ForEach(scopedAreas, id: \.objectID) { area in
                            Button(area.name ?? "Untitled") { move(to: area) }
                        }
                        if !scopedAreas.isEmpty { Divider() }
                        Button("No Area") { move(to: nil) }
                    }
                    .disabled(selection.isEmpty)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Delete", role: .destructive) { showDeleteConfirm = true }
                        .disabled(selection.isEmpty)
                }
            } else {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Add") { showingNew = true }
                }
            }
        }
        .confirmationDialog(deleteTitle, isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteSelected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This also removes their completion history and can't be undone.")
        }
        .sheet(isPresented: $showingNew) {
            NewChoreView()
        }
        .sheet(item: $editingChore) { EditChoreView(chore: $0) }
    }

    /// A chore row that opens the editor on tap when not selecting. In edit mode
    /// the gesture is omitted so taps drive `List` multi-selection instead.
    @ViewBuilder
    private func choreRow(_ chore: CDChore) -> some View {
        if isEditing {
            ChoreRowView(chore: chore, showToggle: false)
        } else {
            ChoreRowView(chore: chore, showToggle: false)
                .contentShape(Rectangle())
                .onTapGesture { editingChore = chore }
        }
    }

    private var deleteTitle: String {
        "Delete \(selection.count) chore\(selection.count == 1 ? "" : "s")?"
    }

    private func delete(_ list: [CDChore], at offsets: IndexSet) {
        for index in offsets { context.delete(list[index]) }
        try? context.save()
    }

    private func move(to area: CDArea?) {
        BulkChoreOps.move(selection, to: area, in: context)
        endEditing()
    }

    private func deleteSelected() {
        BulkChoreOps.delete(selection, in: context)
        endEditing()
    }

    private func endEditing() {
        selection.removeAll()
        editMode?.wrappedValue = .inactive
    }
}

struct NewChoreView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject private var model: AppModel
    @FetchRequest(sortDescriptors: [SortDescriptor(\CDArea.name)]) private var areas: FetchedResults<CDArea>

    @State private var name = ""
    @State private var isDaily = false
    @State private var frequency: Frequency = .weekly
    @State private var day: Weekday? = .monday
    @State private var areaId: UUID?

    var body: some View {
        NavigationStack {
            Form {
                ChoreFormFields(name: $name,
                                isDaily: $isDaily,
                                frequency: $frequency,
                                day: $day,
                                areaId: $areaId,
                                areas: Array(areas).inScope(model.activeHousehold))
            }
            .navigationTitle("New Chore")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let assigned = isDaily ? Weekday.all : day
                        let chore = CDChore.make(in: context,
                                                 name: name,
                                                 isDaily: isDaily,
                                                 frequency: isDaily ? nil : frequency,
                                                 assignedDay: assigned,
                                                 createdDate: Date(),
                                                 household: model.activeHousehold)
                        chore.area = areaId.flatMap { id in areas.first { $0.id == id } }
                        try? context.save()
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

struct EditChoreView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) var dismiss
    @ObservedObject var chore: CDChore
    @FetchRequest(sortDescriptors: [SortDescriptor(\CDArea.name)]) private var areas: FetchedResults<CDArea>

    @State private var name: String = ""
    @State private var isDaily: Bool = false
    @State private var frequency: Frequency = .weekly
    @State private var day: Weekday?
    @State private var areaId: UUID?
    @State private var showLogSheet = false
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                ChoreFormFields(name: $name,
                                isDaily: $isDaily,
                                frequency: $frequency,
                                day: $day,
                                areaId: $areaId,
                                areas: Array(areas).inScope(chore.household))

                Section("History") {
                    let completions = chore.completionsArray

                    ScrollView {
                        LazyVStack(alignment: .leading) {
                            ForEach(completions, id: \.objectID) { completion in
                                HStack(spacing: 4) {
                                    Text((completion.date ?? Date()).formatted(date: .abbreviated, time: .omitted))
                                    if let notes = completion.notes, !notes.isEmpty {
                                        Text("\u{2013} \(notes)")
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(height: 200)

                    Button("Log Completion") { showLogSheet = true }
                }
            }
            .navigationTitle("Edit Chore")
            .onAppear {
                guard !loaded else { return }
                name = chore.name ?? ""
                isDaily = chore.isDaily
                frequency = chore.frequencyValue ?? .weekly
                day = chore.assignedDayValue
                areaId = chore.area?.id
                loaded = true
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        chore.name = name
                        chore.isDaily = isDaily
                        chore.frequencyValue = isDaily ? nil : frequency
                        chore.assignedDayValue = isDaily ? .all : day
                        chore.area = areaId.flatMap { id in areas.first { $0.id == id } }
                        try? context.save()
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .sheet(isPresented: $showLogSheet) {
                LogChoreHistoryView(chore: chore)
            }
        }
    }
}

struct AreaListView: View {
    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var model: AppModel
    @FetchRequest(sortDescriptors: [SortDescriptor(\CDArea.name)]) private var areas: FetchedResults<CDArea>
    @State private var showingNew = false

    var body: some View {
        List {
            let scoped = areas.inScope(model.activeHousehold)
            ForEach(scoped, id: \.objectID) { area in
                NavigationLink(destination: EditAreaView(area: area)) {
                    VStack(alignment: .leading) {
                        Text(area.name ?? "Untitled")
                        if let detail = area.detail, !detail.isEmpty {
                            Text(detail)
                                .font(.caption)
                        }
                    }
                }
            }
            .onDelete { offsets in
                for index in offsets { context.delete(scoped[index]) }
                try? context.save()
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Add") { showingNew = true }
            }
        }
        .sheet(isPresented: $showingNew) { NewAreaView() }
    }
}

struct NewAreaView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject private var model: AppModel
    @FetchRequest(sortDescriptors: [SortDescriptor(\CDChore.name)]) private var allChores: FetchedResults<CDChore>
    @State private var name = ""
    @State private var detail = ""
    @State private var selectedChoreIDs: Set<NSManagedObjectID> = []

    var body: some View {
        NavigationStack {
            Form {
                AreaFormFields(name: $name, description: $detail)
                let unassigned = allChores.inScope(model.activeHousehold).filter { $0.area == nil }
                if !unassigned.isEmpty {
                    Section(header: Text("Assign Chores")) {
                        ForEach(unassigned, id: \.objectID) { chore in
                            Toggle(chore.name ?? "Untitled", isOn: Binding(
                                get: { selectedChoreIDs.contains(chore.objectID) },
                                set: { newValue in
                                    if newValue {
                                        selectedChoreIDs.insert(chore.objectID)
                                    } else {
                                        selectedChoreIDs.remove(chore.objectID)
                                    }
                                }
                            ))
                        }
                    }
                }
            }
            .navigationTitle("New Area")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let area = CDArea.make(in: context, name: name, detail: detail, household: model.activeHousehold)
                        for chore in allChores where selectedChoreIDs.contains(chore.objectID) {
                            chore.area = area
                        }
                        try? context.save()
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

struct EditAreaView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) var dismiss
    @ObservedObject var area: CDArea
    @FetchRequest(sortDescriptors: [SortDescriptor(\CDChore.name)]) private var allChores: FetchedResults<CDChore>
    @State private var name: String = ""
    @State private var detail: String = ""
    @State private var selectedChoreIDs: Set<NSManagedObjectID> = []
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                AreaFormFields(name: $name, description: $detail)
                let available = allChores.inScope(area.household).filter { $0.area == nil || $0.area == area }
                Section(header: Text("Chores")) {
                    ForEach(available, id: \.objectID) { chore in
                        Toggle(chore.name ?? "Untitled", isOn: Binding(
                            get: { selectedChoreIDs.contains(chore.objectID) },
                            set: { newValue in
                                if newValue {
                                    selectedChoreIDs.insert(chore.objectID)
                                } else {
                                    selectedChoreIDs.remove(chore.objectID)
                                }
                            }
                        ))
                    }
                }
            }
            .navigationTitle("Edit Area")
            .onAppear {
                guard !loaded else { return }
                name = area.name ?? ""
                detail = area.detail ?? ""
                selectedChoreIDs = Set(allChores.filter { $0.area == area }.map { $0.objectID })
                loaded = true
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        area.name = name
                        area.detail = detail
                        for chore in allChores {
                            if selectedChoreIDs.contains(chore.objectID) {
                                chore.area = area
                            } else if chore.area == area {
                                chore.area = nil
                            }
                        }
                        try? context.save()
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

/// View for logging a past completion for a chore.
struct LogChoreHistoryView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) var dismiss
    @ObservedObject var chore: CDChore
    @State private var date: Date = Date()

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Completion Date", selection: $date, displayedComponents: .date)
            }
            .navigationTitle("Log Completion")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        chore.recordCompletion(on: date, in: context)
                        if let created = chore.createdDate, date < created {
                            chore.createdDate = date
                        } else if chore.createdDate == nil {
                            chore.createdDate = date
                        }
                        try? context.save()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack { EditHomeView() }
        .environment(\.managedObjectContext, PreviewStack.context)
        .environmentObject(AppModel())
}
#endif
