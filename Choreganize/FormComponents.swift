import SwiftUI

/// Shared form section used when creating or editing a chore. Keeping the
/// fields in one place ensures consistency across the app.
struct ChoreFormFields: View {
    @Binding var name: String
    @Binding var frequency: Frequency
    @Binding var day: Weekday?
    @Binding var areaId: UUID?
    var areas: [Area]

    var body: some View {
        Section("Details") {
            TextField("Name", text: $name)
            Picker("Frequency", selection: $frequency) {
                ForEach(Frequency.allCases) { Text($0.rawValue.capitalized).tag($0) }
            }
            Picker("Day", selection: $day) {
                Text("None").tag(Weekday?.none)
                ForEach(Weekday.allCases) { Text($0.displayName).tag(Optional($0)) }
            }
            Picker("Area", selection: $areaId) {
                Text("None").tag(UUID?.none)
                ForEach(areas) { area in
                    Text(area.name).tag(Optional(area.id))
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
