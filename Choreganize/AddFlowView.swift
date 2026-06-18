import SwiftUI
import CoreData
import UIKit

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
    @State private var showDiscardConfirm = false

    enum Step { case pickGroup, addChores, another, review }

    init(grouping: AddFlowGrouping) {
        self.grouping = grouping
        _flow = StateObject(wrappedValue: AddFlowModel(grouping: grouping))
    }

    var body: some View {
        ZStack {
            stepView
                .id(step)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)))
        }
        .navigationTitle(grouping.title)
        .navigationBarTitleDisplayMode(.inline)
        // With staged drafts uncommitted, replace the system back button (which would pop
        // and silently discard them) with a Cancel that confirms first (#53).
        .navigationBarBackButtonHidden(flow.draftCount > 0)
        .toolbar {
            if flow.draftCount > 0 {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { showDiscardConfirm = true }
                }
            }
            // Jump to Review from the group picker after looping back with drafts staged.
            if step == .pickGroup && flow.draftCount > 0 {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Review") { advance(to: .review) }
                }
            }
        }
        .confirmationDialog("Discard \(flow.draftCount) unsaved chore\(flow.draftCount == 1 ? "" : "s")?",
                            isPresented: $showDiscardConfirm, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        }
    }

    @ViewBuilder private var stepView: some View {
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

    private func advance(to next: Step) { withAnimation(.snappy) { step = next } }

    private func save() {
        flow.commit(in: context, household: model.activeHousehold)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
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
    @FocusState private var nameFocused: Bool
    @State private var showUnaddedConfirm = false

    private var scopedAreas: [CDArea] { areas.inScope(model.activeHousehold) }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var groupCount: Int { flow.activeGroup.map { flow.count(in: $0) } ?? 0 }
    private var isRoomLens: Bool {
        if case .area = flow.activeGroup { return true }
        return false
    }
    // Finishing the *group* (room/day), not the chore being typed — phrased for finality.
    private var doneLabel: String { isRoomLens ? "Room Complete" : "Day Complete" }

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
                    .focused($nameFocused)
                    .onSubmit(addChore)
                // Reuse the shared chore-detail rows (the same component New/Edit Chore
                // use — #49), hiding whichever field the active group pins: the area in
                // the room lens, the daily-toggle + day in the day lens. The day lens now
                // keeps its Frequency picker, which it previously dropped (#50).
                ChoreFormRows(name: $name, isDaily: $isDaily, frequency: $frequency,
                              day: $day, areaId: $areaId, areas: scopedAreas,
                              showsName: false,
                              showsDailyToggle: isRoomLens,
                              showsDay: isRoomLens,
                              showsArea: !isRoomLens)
            }
        }
        .navigationTitle(groupTitle)
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.increase, trigger: flow.draftCount)
        .onAppear {
            nameFocused = true
            // The "Every day" day-group makes daily chores; pin isDaily so Frequency/Day
            // (both hidden here) stay irrelevant. Specific weekdays stay non-daily.
            if case .day(.all) = flow.activeGroup { isDaily = true }
        }
        // Prominent call-to-action floating beneath the form — and above the keyboard,
        // so rapid back-to-back entry stays a type → tap rhythm.
        .safeAreaInset(edge: .bottom) {
            Button(action: addChore) {
                Label("Add chore", systemImage: "plus.circle.fill")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(trimmedName.isEmpty)
            .padding()
            .background(.bar)
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                // "Done" was ambiguous (done with this chore vs done with the group);
                // "Room/Day Complete" reads as finishing the group.
                Button(doneLabel) { finishAdding() }
            }
        }
        // Guard against finishing with a typed-but-unadded chore — easy to miss the Add
        // control the first time, and the text would otherwise be silently dropped (#54).
        .confirmationDialog("\u{201C}\(trimmedName)\u{201D} hasn't been added yet",
                            isPresented: $showUnaddedConfirm, titleVisibility: .visible) {
            Button("Add & Finish") { addChore(); onDone() }
            Button("Discard", role: .destructive) { name = ""; onDone() }
            Button("Keep Editing", role: .cancel) { nameFocused = true }
        } message: {
            Text("Tap Add to stage it, or discard it before finishing.")
        }
    }

    /// Finish adding to this group. If a chore was typed but never added, confirm first
    /// so it isn't silently lost; otherwise advance straight through.
    private func finishAdding() {
        nameFocused = false   // drop keyboard before transitioning
        if trimmedName.isEmpty {
            onDone()
        } else {
            showUnaddedConfirm = true
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
            // Carry the per-chore frequency (the engine pins the weekday). For the
            // "every day" group the engine forces daily and ignores frequency.
            flow.addToActiveGroup(name: trimmedName, frequency: frequency,
                                  areaRef: areaId.map { .existing($0) } ?? .none)
        case .none:
            break
        }
        name = ""   // reset for the next add — no growing list crowding the view
        nameFocused = true   // keep focus for rapid successive adds
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
                    .transition(.scale.combined(with: .opacity))
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
