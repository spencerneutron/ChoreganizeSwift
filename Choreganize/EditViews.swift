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
            ForEach(model.chores) { chore in
                VStack(alignment: .leading) {
                    Text(chore.name)
                    if let area = model.areas.first(where: { $0.id == chore.areaId }) {
                        Text(area.name).font(.caption)
                    }
                }
                .onTapGesture { editingChore = chore }
            }
            .onDelete(perform: model.deleteChores)
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
    @State private var day: Weekday = .monday
    @State private var area: Area?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                Picker("Frequency", selection: $frequency) {
                    ForEach(Frequency.allCases) { Text($0.rawValue.capitalized).tag($0) }
                }
                Picker("Day", selection: $day) {
                    ForEach(Weekday.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("Area", selection: Binding(
                    get: { area?.id },
                    set: { id in area = model.areas.first(where: { $0.id == id }) }
                )) {
                    Text("None").tag(UUID?.none)
                    ForEach(model.areas) { area in
                        Text(area.name).tag(Optional(area.id))
                    }
                }
            }
            .navigationTitle("New Chore")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let new = Chore(name: name, frequency: frequency, assignedDay: day, areaId: area?.id)
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

    @State private var name: String
    @State private var frequency: Frequency
    @State private var day: Weekday
    @State private var areaId: UUID?

    init(chore: Chore) {
        self.choreID = chore.id
        _name = State(initialValue: chore.name)
        _frequency = State(initialValue: chore.frequency)
        _day = State(initialValue: chore.assignedDay)
        _areaId = State(initialValue: chore.areaId)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                Picker("Frequency", selection: $frequency) {
                    ForEach(Frequency.allCases) { Text($0.rawValue.capitalized).tag($0) }
                }
                Picker("Day", selection: $day) {
                    ForEach(Weekday.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("Area", selection: $areaId) {
                    Text("None").tag(UUID?.none)
                    ForEach(model.areas) { area in
                        Text(area.name).tag(Optional(area.id))
                    }
                }
            }
            .navigationTitle("Edit Chore")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let updated = Chore(id: choreID, name: name, frequency: frequency, assignedDay: day, areaId: areaId)
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
                TextField("Name", text: $name)
                TextField("Description", text: $description)
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
                TextField("Name", text: $area.name)
                TextField("Description", text: $area.description)
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
