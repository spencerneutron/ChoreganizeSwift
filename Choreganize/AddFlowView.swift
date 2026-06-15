import SwiftUI
import CoreData

// P1: the guided "add chores & areas" wizard UI shell. Engine lives in AddFlow.swift.
// NOT yet wired into the Edit tab — that's P2. This file is self-contained and
// previewable so the flow can be exercised in isolation.

/// Temporary P1 host: pick a lens, then run the wizard. P2 relocates the lens choice
/// into the reframed Edit home (replacing the sparse `EditHomeView`).
struct AddFlowStartView: View {
    @State private var grouping: AddFlowGrouping?

    var body: some View {
        VStack(spacing: 16) {
            Text("Set Up Chores").font(.title2.bold())
            Text("Add several at once — go room by room, or day by day.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            ForEach(AddFlowGrouping.allCases) { lens in
                Button { grouping = lens } label: {
                    Label(lens.title, systemImage: lens.systemImage)
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .sheet(item: $grouping) { lens in AddFlowView(grouping: lens) }
    }
}

/// Wizard steps pushed onto the flow's navigation path. The root (group picker) is
/// not in the path; selecting a group pushes `.addChores`.
enum AddFlowStep: Hashable { case addChores, anotherGroup, review }

/// The wizard. Root = group picker; pushes add-chores → another? → review → commit.
/// One shell for both lenses, parameterized by `AddFlowGrouping` (the grouping key).
struct AddFlowView: View {
    let grouping: AddFlowGrouping

    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @StateObject private var flow: AddFlowModel
    @State private var path: [AddFlowStep] = []

    init(grouping: AddFlowGrouping) {
        self.grouping = grouping
        _flow = StateObject(wrappedValue: AddFlowModel(grouping: grouping))
    }

    var body: some View {
        NavigationStack(path: $path) {
            AddFlowGroupPicker(flow: flow) { group in
                flow.startGroup(group)
                path = [.addChores]
            }
            .navigationTitle(grouping.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                if flow.draftCount > 0 {
                    ToolbarItem(placement: .confirmationAction) { Button("Review") { path = [.review] } }
                }
            }
            .navigationDestination(for: AddFlowStep.self) { step in
                switch step {
                case .addChores:
                    AddChoresStep(flow: flow, onDone: { path.append(.anotherGroup) })
                case .anotherGroup:
                    AnotherGroupStep(flow: flow,
                                     onAddAnother: { path = [] },
                                     onReview: { path = [.review] })
                case .review:
                    AddFlowReview(flow: flow, onSave: save)
                }
            }
        }
    }

    private func save() {
        flow.commit(in: context, household: model.activeHousehold)
        dismiss()
    }
}

// MARK: - Step 1: pick / define the group

private struct AddFlowGroupPicker: View {
    @ObservedObject var flow: AddFlowModel
    var onSelect: (AddFlowGroup) -> Void

    @EnvironmentObject private var model: AppModel
    @FetchRequest(sortDescriptors: [SortDescriptor(\CDArea.name)]) private var areas: FetchedResults<CDArea>
    @State private var newRoom = ""

    private var scopedAreas: [CDArea] { areas.inScope(model.activeHousehold) }
    private var trimmedRoom: String { newRoom.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        List {
            switch flow.grouping {
            case .byArea:
                Section("New room") {
                    HStack {
                        TextField("Room name", text: $newRoom)
                        Button("Add") { onSelect(.area(.new(trimmedRoom))); newRoom = "" }
                            .disabled(trimmedRoom.isEmpty)
                    }
                }
                if !scopedAreas.isEmpty {
                    Section("Existing rooms") {
                        ForEach(scopedAreas, id: \.objectID) { area in
                            Button(area.name ?? "Untitled") {
                                if let id = area.id { onSelect(.area(.existing(id))) }
                            }
                        }
                    }
                }
            case .byDay:
                Section { Button("Every day") { onSelect(.day(.all)) } }
                Section("A day of the week") {
                    ForEach(Weekday.standardCases) { day in
                        Button(day.displayName) { onSelect(.day(day)) }
                    }
                }
            }
        }
    }
}

// MARK: - Step 2: add chores for the active group

private struct AddChoresStep: View {
    @ObservedObject var flow: AddFlowModel
    var onDone: () -> Void

    @EnvironmentObject private var model: AppModel
    @FetchRequest(sortDescriptors: [SortDescriptor(\CDArea.name)]) private var areas: FetchedResults<CDArea>

    @State private var name = ""
    // Per-chore schedule (room lens only — day lens pins the day on the group).
    @State private var isDaily = false
    @State private var frequency: Frequency = .weekly
    @State private var day: Weekday? = .monday
    // Per-chore area (day lens only).
    @State private var areaId: UUID?

    private var scopedAreas: [CDArea] { areas.inScope(model.activeHousehold) }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var groupCount: Int { flow.activeGroup.map { flow.count(in: $0) } ?? 0 }

    var body: some View {
        Form {
            Section {
                ChipTray(count: groupCount, total: flow.draftCount)
            }
            Section("Add a chore") {
                TextField("Name", text: $name)
                if case .area = flow.activeGroup {
                    Toggle("Every Day", isOn: $isDaily)
                    if !isDaily {
                        Picker("Frequency", selection: $frequency) {
                            ForEach(Frequency.allCases) { Text($0.rawValue.capitalized).tag($0) }
                        }
                        Picker("Day", selection: $day) {
                            Text("None").tag(Weekday?.none)
                            ForEach(Weekday.standardCases) { Text($0.displayName).tag(Optional($0)) }
                        }
                    }
                } else {
                    Picker("Area", selection: $areaId) {
                        Text("None").tag(UUID?.none)
                        ForEach(scopedAreas, id: \.objectID) { Text($0.name ?? "Untitled").tag($0.id) }
                    }
                }
                Button("Add chore") { addChore() }.disabled(trimmedName.isEmpty)
            }
        }
        .navigationTitle(groupTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { onDone() } }
        }
    }

    private var groupTitle: String {
        switch flow.activeGroup {
        case .area(.new(let n)):       return n.isEmpty ? "Room" : n
        case .area(.existing(let id)): return scopedAreas.first { $0.id == id }?.name ?? "Room"
        case .area(.none):             return "Room"
        case .day(let weekday):        return weekday.displayName
        case .none:                    return "Chores"
        }
    }

    private func addChore() {
        guard !trimmedName.isEmpty else { return }
        switch flow.activeGroup {
        case .area:
            flow.addToActiveGroup(name: trimmedName, isDaily: isDaily, frequency: frequency,
                                  day: isDaily ? nil : day)
        case .day:
            flow.addToActiveGroup(name: trimmedName, areaRef: areaId.map { .existing($0) } ?? .none)
        case .none:
            break
        }
        name = ""   // reset for the next add — no growing list crowding the view
    }
}

/// Contained "growing" indicator: a condensing chip tray + a live count. Deliberately
/// has NO denominator/progress bar — adding chores is open-ended, so it shows
/// accumulation, never "X of N." (P3 adds motion/refinement.)
private struct ChipTray: View {
    let count: Int     // staged in the active group
    let total: Int     // staged overall
    private let maxChips = 6

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<min(count, maxChips), id: \.self) { _ in
                Circle().frame(width: 8, height: 8).foregroundStyle(.tint)
            }
            if count > maxChips {
                Text("+\(count - maxChips)").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(total) added")
                .font(.callout.weight(.medium))
                .contentTransition(.numericText())
        }
        .animation(.snappy, value: count)
        .animation(.snappy, value: total)
    }
}

// MARK: - Step 3: another group, or review

private struct AnotherGroupStep: View {
    @ObservedObject var flow: AddFlowModel
    var onAddAnother: () -> Void
    var onReview: () -> Void

    private var unit: String { flow.grouping == .byArea ? "room" : "day" }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(.tint)
            Text("\(flow.draftCount) chore\(flow.draftCount == 1 ? "" : "s") ready").font(.headline)
            Button { onAddAnother() } label: {
                Label("Add another \(unit)", systemImage: "plus").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            Button { onReview() } label: {
                Text("Review & Save").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .navigationTitle("Nice work")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Step 4: review & commit

private struct AddFlowReview: View {
    @ObservedObject var flow: AddFlowModel
    var onSave: () -> Void

    @EnvironmentObject private var model: AppModel
    @FetchRequest(sortDescriptors: [SortDescriptor(\CDArea.name)]) private var areas: FetchedResults<CDArea>

    private struct DraftGroup { let label: String; let drafts: [ChoreDraft] }

    var body: some View {
        List {
            ForEach(groups, id: \.label) { group in
                Section(group.label) {
                    ForEach(group.drafts) { draft in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(draft.name)
                            Text(scheduleText(draft)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { onSave() }.disabled(flow.draftCount == 0).bold()
            }
        }
    }

    private var groups: [DraftGroup] {
        let keyed: [String: [ChoreDraft]]
        switch flow.grouping {
        case .byArea: keyed = Dictionary(grouping: flow.drafts) { areaLabel($0.areaRef) }
        case .byDay:  keyed = Dictionary(grouping: flow.drafts) { dayLabel($0) }
        }
        return keyed.map { DraftGroup(label: $0.key, drafts: $0.value) }.sorted { $0.label < $1.label }
    }

    private func areaLabel(_ ref: AreaRef) -> String {
        switch ref {
        case .none:             return "No room"
        case .new(let n):       return n
        case .existing(let id): return areas.first { $0.id == id }?.name ?? "Room"
        }
    }
    private func dayLabel(_ d: ChoreDraft) -> String {
        d.isDaily ? "Every Day" : (d.day?.displayName ?? "Unassigned")
    }
    private func scheduleText(_ d: ChoreDraft) -> String {
        d.isDaily ? "Every day" : "\(d.frequency.rawValue.capitalized) · \(d.day?.displayName ?? "No day")"
    }
}

#if DEBUG
#Preview {
    AddFlowStartView()
        .environment(\.managedObjectContext, PreviewStack.context)
        .environmentObject(AppModel())
}
#endif
