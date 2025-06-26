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

    var body: some View {
        List {
            ForEach(model.chores) { chore in
                VStack(alignment: .leading) {
                    Text(chore.name)
                    if let area = model.areas.first(where: { $0.id == chore.areaId }) {
                        Text(area.name).font(.caption)
                    }
                }
            }
            .onDelete(perform: model.deleteChores)
        }
        .navigationTitle("Chores")
        .toolbar {
            Button("Add") { showingNew = true }
        }
        .sheet(isPresented: $showingNew) {
            NewChoreView()
        }
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

struct AreaListView: View {
    @EnvironmentObject var model: AppModel
    @State private var showingNew = false

    var body: some View {
        List {
            ForEach(model.areas) { area in
                VStack(alignment: .leading) {
                    Text(area.name)
                    Text(area.description).font(.caption)
                }
            }
            .onDelete(perform: model.deleteAreas)
        }
        .navigationTitle("Areas")
        .toolbar { Button("Add") { showingNew = true } }
        .sheet(isPresented: $showingNew) { NewAreaView() }
    }
}

struct NewAreaView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var description = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                TextField("Description", text: $description)
            }
            .navigationTitle("New Area")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.addArea(Area(name: name, description: description))
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
