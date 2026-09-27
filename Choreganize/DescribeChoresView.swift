#if os(iOS)
import CoreData
import SwiftUI

/// Describe Chores (CG-A2 / #106): type or dictate chores in your own words, and the
/// on-device model turns them into scheduled chores to review and add through the
/// add-flow engine. Pushed in-tab from EditHomeView, next to Snap a Room.
struct DescribeChoresFlowView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @FetchRequest(sortDescriptors: [SortDescriptor(\CDArea.name)]) private var areas: FetchedResults<CDArea>
    @FetchRequest(sortDescriptors: [SortDescriptor(\CDChore.name)]) private var chores: FetchedResults<CDChore>

    @StateObject private var describe = DescribeChoresModel()
    @State private var editing: ChoreDraft?
    @FocusState private var textFocused: Bool
    // Pre-warmed so the Add haptic doesn't cold-start the engine on the main thread.
    @State private var successHaptic = SuccessHaptic()

    private var scopedAreas: [CDArea] { areas.inScope(model.activeHousehold) }

    private var household: DescribeChoresModel.Household {
        .make(areas: scopedAreas, chores: Array(chores).inScope(model.activeHousehold),
              household: model.activeHousehold)
    }

    var body: some View {
        Group {
            switch describe.phase {
            case .compose:           composeStep
            case .reading:           readingStep
            case .review:            reviewStep
            case .nothingFound:      nothingFoundStep
            case .failed(let error): failedStep(error)
            }
        }
        .navigationTitle("Describe Chores")
        .compatInlineNavigationTitle()
        .onAppear { successHaptic.prepare() }
        .onDisappear { describe.cancel() }
        #if DEBUG
        .task {
            if describe.phase == .compose, describe.text.isEmpty, let text = DescribeChoresModel.testTextFromEnvironment {
                describe.text = text
                describe.read(household: household)
            }
        }
        #endif
        .sheet(item: $editing) { draft in
            AddFlowDraftEditor(draft: draft, grouping: .byArea, areas: scopedAreas) { describe.update($0) }
        }
    }

    // MARK: Compose

    private var composeStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Describe Your Chores").font(.title2.bold())
                    Text("Say what needs doing and when, in your own words. Type it, or tap the mic on the keyboard.")
                        .foregroundStyle(.secondary)
                }
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $describe.text)
                        .focused($textFocused)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 180)
                        .padding(8)
                        .accessibilityIdentifier("describe.text")
                    if describe.text.isEmpty {
                        Text("Vacuum the living room on Saturdays, do the dishes every night, and clean the bathroom every other week.")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 16)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .background(Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Label("Read on this device. What you type isn't saved.", systemImage: "lock.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .background(Color.compatGroupedBackground)
        .safeAreaInset(edge: .bottom) {
            Button {
                textFocused = false
                describe.read(household: household)
            } label: {
                Text("Get Chores")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!describe.canRead)
            .padding()
            .background(.bar)
            .accessibilityIdentifier("describe.read")
        }
        .onAppear { if describe.text.isEmpty { textFocused = true } }
    }

    // MARK: Reading

    private var readingStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                quote
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Reading your chores…").font(.headline)
                }
                ForEach(Array(describe.live.enumerated()), id: \.offset) { _, chore in
                    Label(chore.name, systemImage: "sparkles")
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding()
        }
        .background(Color.compatGroupedBackground)
    }

    private var quote: some View {
        Text(describe.text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: Review

    private var reviewStep: some View {
        List {
            Section("You wrote") {
                Text(describe.text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section {
                ForEach(Array(describe.drafts.enumerated()), id: \.element.id) { index, draft in
                    choreRow(draft, index: index)
                }
            } header: {
                Text("Chores")
            } footer: {
                Text("Tap a chore to leave it out. You can change its schedule or room here, or anytime later.")
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button(action: save) {
                Text(describe.chosenCount == 0 ? "Add Chores"
                     : "Add \(describe.chosenCount) Chore\(describe.chosenCount == 1 ? "" : "s")")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(describe.chosenCount == 0)
            .padding()
            .background(.bar)
            .accessibilityIdentifier("describe.add")
        }
        .toolbar {
            ToolbarItem(placement: .compatTrailing) {
                Button("Edit Text") { describe.edit() }
                    .accessibilityIdentifier("describe.edit")
            }
        }
    }

    private func choreRow(_ draft: ChoreDraft, index: Int) -> some View {
        let isDuplicate = describe.duplicateIDs.contains(draft.id)
        let isOn = describe.selected.contains(draft.id)
        return HStack(spacing: 12) {
            Button { describe.toggle(draft.id) } label: {
                HStack(spacing: 12) {
                    Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(draft.name).foregroundStyle(.primary)
                        Text(describe.detail(for: draft))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !isDuplicate, let note = describe.plusNotes[draft.id] {
                            Label(note, systemImage: "lock")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("describe.chore.\(index)")
            .accessibilityAddTraits(isOn ? .isSelected : [])

            Button { editing = draft } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Edit \(draft.name)")
        }
        .disabled(isDuplicate)
        .opacity(isDuplicate ? 0.5 : 1)
    }

    // MARK: Nothing found / failed

    private var nothingFoundStep: some View {
        ContentUnavailableView {
            Label("No Chores Found", systemImage: "text.magnifyingglass")
        } description: {
            Text("Try naming a chore and when it happens, like “water the plants on Sundays.”")
        } actions: {
            Button("Edit Text") { describe.edit() }
                .buttonStyle(.borderedProminent)
        }
    }

    private func failedStep(_ error: RoomVisionError) -> some View {
        ContentUnavailableView {
            Label("Couldn't Read That", systemImage: "exclamationmark.triangle")
        } description: {
            Text(error.textMessage)
        } actions: {
            if error != .unavailable {
                Button("Try Again") { describe.read(household: household) }
                    .buttonStyle(.borderedProminent)
            }
            Button("Edit Text") { describe.edit() }
        }
    }

    private func save() {
        let drafts = describe.chosenDrafts
        guard !drafts.isEmpty else { return }
        AddFlowCommit.commit(drafts, in: context, household: model.activeHousehold,
                             allowsPlusSchedule: Entitlements.isPlus(for: model.activeHousehold))
        Log.info("Describe Chores: added \(drafts.count) chore(s)")
        successHaptic.success()
        dismiss()
    }
}

#endif
