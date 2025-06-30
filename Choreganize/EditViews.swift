import SwiftUI

struct EditHomeView: View {
    var body: some View {
        List {
            NavigationLink("Chores") { ChoreListView() }
            NavigationLink("Areas") { AreaListView() }
        }
    }
}

struct ChoreListView: View {
    @EnvironmentObject var model: AppModel
    @State private var showingNew = false
    @State private var editingChore: Chore?

    var body: some View {
        List {
            ForEach(Weekday.allCases) { day in
                let choresForDay = model.chores.filter { $0.assignedDay == day }
                if !choresForDay.isEmpty {
                    Section(header: Text(day.displayName)) {
                        ForEach(choresForDay) { chore in
                            ChoreRowView(chore: chore)
                                .contentShape(Rectangle())
                                .onTapGesture { editingChore = chore }
                        }
                        .onDelete { offsets in
                            let ids = offsets.map { choresForDay[$0].id }
                            model.deleteChores(withIDs: ids)
                        }
                    }
                }
            }

            let unassigned = model.chores.filter { $0.assignedDay == nil }
            if !unassigned.isEmpty {
                Section(header: Text("Unassigned")) {
                    ForEach(unassigned) { chore in
                        ChoreRowView(chore: chore)
                            .contentShape(Rectangle())
                            .onTapGesture { editingChore = chore }
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { unassigned[$0].id }
                        model.deleteChores(withIDs: ids)
                    }
                }
            }
        }
        .navigationTitle("Chores")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Add") { showingNew = true }
            }
        }
        .sheet(isPresented: $showingNew) {
            NewChoreView()
        }
        .sheet(item: $editingChore) { EditChoreView(chore: $0) }
    }
}

struct NewChoreView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss

    @State private var name = ""
    @State private var frequency: Frequency = .daily
    @State private var day: Weekday? = .monday
    @State private var areaId: UUID?

    var body: some View {
        NavigationStack {
            Form {
                ChoreFormFields(name: $name,
                                frequency: $frequency,
                                day: $day,
                                areaId: $areaId,
                                areas: model.areas)
            }
            .navigationTitle("New Chore")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let new = Chore(name: name, frequency: frequency, assignedDay: day, areaId: areaId, createdDate: Date())
                        model.addChore(new)
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
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    private let choreID: UUID
    private let createdDate: Date

    @State private var name: String
    @State private var frequency: Frequency
    @State private var day: Weekday?
    @State private var areaId: UUID?

    init(chore: Chore) {
        self.choreID = chore.id
        self.createdDate = chore.createdDate
        _name = State(initialValue: chore.name)
        _frequency = State(initialValue: chore.frequency)
        _day = State(initialValue: chore.assignedDay)
        _areaId = State(initialValue: chore.areaId)
    }

    var body: some View {
        NavigationStack {
            Form {
                ChoreFormFields(name: $name,
                                frequency: $frequency,
                                day: $day,
                                areaId: $areaId,
                                areas: model.areas)
            }
            .navigationTitle("Edit Chore")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let updated = Chore(id: choreID, name: name, frequency: frequency, assignedDay: day, areaId: areaId, createdDate: createdDate)
                        model.updateChore(updated)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

struct AreaListView: View {
    @EnvironmentObject var model: AppModel
    @State private var showingNew = false

    var body: some View {
        List {
            ForEach(model.areas) { area in
                NavigationLink(destination: EditAreaView(area: area)) {
                    VStack(alignment: .leading) {
                        Text(area.name)
                        Text(area.description).font(.caption)
                    }
                }
            }
            .onDelete(perform: model.deleteAreas)
        }
        .navigationTitle("Areas")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Add") { showingNew = true }
            }
        }
        .sheet(isPresented: $showingNew) { NewAreaView() }
    }
}

struct NewAreaView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var selectedChoreIDs: Set<UUID> = []

    var body: some View {
        NavigationStack {
            Form {
                AreaFormFields(name: $name, description: $description)
                let unassigned = model.chores.filter { $0.areaId == nil }
                if !unassigned.isEmpty {
                    Section(header: Text("Assign Chores")) {
                        ForEach(unassigned) { chore in
                            Toggle(chore.name, isOn: Binding(
                                get: { selectedChoreIDs.contains(chore.id) },
                                set: { newValue in
                                    if newValue {
                                        selectedChoreIDs.insert(chore.id)
                                    } else {
                                        selectedChoreIDs.remove(chore.id)
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
                        let area = Area(name: name, description: description)
                        model.addArea(area)
                        model.assignChores(Array(selectedChoreIDs), toAreaID: area.id)
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
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State var area: Area
    @State private var selectedChoreIDs: Set<UUID> = []

    var body: some View {
        NavigationStack {
            Form {
                AreaFormFields(name: $area.name, description: $area.description)
                Section(header: Text("Chores")) {
                    ForEach(model.chores) { chore in
                        Toggle(chore.name, isOn: Binding(
                            get: { selectedChoreIDs.contains(chore.id) },
                            set: { newValue in
                                if newValue {
                                    selectedChoreIDs.insert(chore.id)
                                } else {
                                    selectedChoreIDs.remove(chore.id)
                                }
                            }
                        ))
                    }
                }
            }
            .navigationTitle("Edit Area")
            .onAppear {
                selectedChoreIDs = Set(model.chores.filter { $0.areaId == area.id }.map { $0.id })
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.updateArea(area)
                        model.assignChores(Array(selectedChoreIDs), toAreaID: area.id)
                        let toUnassign = model.chores
                            .filter { $0.areaId == area.id && !selectedChoreIDs.contains($0.id) }
                            .map { $0.id }
                        if !toUnassign.isEmpty {
                            model.assignChores(toUnassign, toAreaID: nil)
                        }
                        dismiss()
                    }
                    .disabled(area.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

#Preview {
    EditHomeView()
        .environmentObject(AppModel())
}
