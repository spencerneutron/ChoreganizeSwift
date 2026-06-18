import SwiftUI

/// Shared form section used when creating or editing a chore. Keeping the
/// fields in one place ensures consistency across the app. A thin `Section`
/// wrapper around `ChoreFormRows` so the same fields can also be composed into
/// other forms (e.g. the add-flow wizard) without the section chrome.
struct ChoreFormFields: View {
    @Binding var name: String
    @Binding var isDaily: Bool
    @Binding var frequency: Frequency
    @Binding var day: Weekday?
    @Binding var areaId: UUID?
    var areas: [CDArea]

    var body: some View {
        Section("Details") {
            ChoreFormRows(name: $name, isDaily: $isDaily, frequency: $frequency,
                          day: $day, areaId: $areaId, areas: areas)
        }
    }
}

/// The bare chore-detail rows (no `Section` wrapper). Visibility flags let a
/// caller hide a field it pins elsewhere — the add-flow wizard hides the area
/// in the room lens and the daily-toggle/day in the day lens, while still
/// surfacing every other control (notably Frequency, which the day lens used
/// to drop). Defaults reproduce the full New/Edit Chore form exactly.
struct ChoreFormRows: View {
    @Binding var name: String
    @Binding var isDaily: Bool
    @Binding var frequency: Frequency
    @Binding var day: Weekday?
    @Binding var areaId: UUID?
    var areas: [CDArea]

    var showsName = true
    var showsDailyToggle = true
    var showsDay = true
    var showsArea = true

    var body: some View {
        if showsName {
            TextField("Name", text: $name)
        }
        if showsDailyToggle {
            Toggle("Every Day", isOn: $isDaily)
        }
        if !isDaily {
            Picker("Frequency", selection: $frequency) {
                ForEach(Frequency.allCases) { Text($0.rawValue.capitalized).tag($0) }
            }
            if showsDay {
                Picker("Day", selection: $day) {
                    Text("None").tag(Weekday?.none)
                    ForEach(Weekday.standardCases) { Text($0.displayName).tag(Optional($0)) }
                }
            }
        } else if showsDay {
            Picker("Day", selection: .constant(Weekday.all)) {
                Text(Weekday.all.displayName).tag(Weekday.all)
            }
            .disabled(true)
        }
        if showsArea {
            Picker("Area", selection: $areaId) {
                Text("None").tag(UUID?.none)
                ForEach(areas, id: \.objectID) { area in
                    Text(area.name ?? "Untitled").tag(area.id)
                }
            }
        }
    }
}

/// Section for editing area metadata to match the style of `ChoreFormFields`.
struct AreaFormFields: View {
    @Binding var name: String
    @Binding var description: String

    var body: some View {
        Section("Details") {
            TextField("Name", text: $name)
            TextField("Description", text: $description)
        }
    }
}
