import SwiftUI
import CoreData

// P2: the guided "add chores & areas" wizard, pushed in-tab from EditHomeView (not a
// modal sheet — keeps the Edit tab context, matching how Chores/Areas already push onto
// the ambient NavigationStack). Engine lives in AddFlow.swift; the step subviews below
// are navigation-agnostic (callback-driven) and reused across both lenses.

/// The guided add-flow, pushed in-tab from `EditHomeView`. One shell for both lenses,
/// parameterized by `AddFlowGrouping` (the swappable grouping key). Steps advance in
/// place; the system back button cancels the flow (drafts are uncommitted until
/// Review → Save). A back-with-unsaved-drafts confirmation is deferred to P3.
struct AddFlowFlowView: View {
    let grouping: AddFlowGrouping

    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @StateObject private var flow: AddFlowModel
    @State private var step: Step = .pickGroup

    enum Step { case pickGroup, addChores, another, review }

    init(grouping: AddFlowGrouping) {
        self.grouping = grouping
        _flow = StateObject(wrappedValue: AddFlowModel(grouping: grouping))
    }

    var body: some View {
        Group {
            switch step {
            case .pickGroup:
                AddFlowGroupPicker(flow: flow) { group in
                    flow.startGroup(group); advance(to: .addChores)
                }
            case .addChores:
                AddChoresStep(flow: flow, onDone: { advance(to: .another) })
            case .another:
                AnotherGroupStep(flow: flow,
                                 onAddAnother: { advance(to: .pickGroup) },
                                 onReview: { advance(to: .review) })
            case .review:
                AddFlowReview(flow: flow, onSave: save)
            }
        }
        .navigationTitle(grouping.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Jump to Review from the group picker after looping back with drafts staged.
            if step == .pickGroup && flow.draftCount > 0 {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Review") { advance(to: .review) }
                }
            }
        }
    }

    private func advance(to next: Step) { withAnimation(.snappy) { step = next } }

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
                            .accessibilityIdentifier("addflow.newRoomField")
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
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
                    .accessibilityIdentifier("addflow.choreNameField")
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
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
    NavigationStack { AddFlowFlowView(grouping: .byArea) }
        .environment(\.managedObjectContext, PreviewStack.context)
        .environmentObject(AppModel())
}
#endif
