import CoreData
import SwiftUI

/// Opens Describe Chores on the Mac, optionally with text already in hand (snapshots).
struct MacDescribeRequest: Identifiable {
    let id = UUID()
    var text: String?
}

/// Describe Chores on the Mac (#106): the same model as iPhone (DescribeChoresModel),
/// presented like the photo sheets — what you typed on the left, the chores on the
/// right with native checkboxes and a popover editor for schedule and room. ⌘Return
/// reads the text, Return adds, Esc cancels.
struct MacDescribeChoresSheet: View {
    var initialText: String?

    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @FetchRequest(sortDescriptors: [SortDescriptor(\CDArea.name)]) private var areas: FetchedResults<CDArea>
    @FetchRequest(sortDescriptors: [SortDescriptor(\CDChore.name)]) private var chores: FetchedResults<CDChore>

    @StateObject private var describe = DescribeChoresModel()
    @State private var editingID: ChoreDraft.ID?
    @FocusState private var textFocused: Bool

    private var scopedAreas: [CDArea] { areas.inScope(model.activeHousehold) }

    private var household: DescribeChoresModel.Household {
        .make(areas: scopedAreas, chores: Array(chores).inScope(model.activeHousehold),
              household: model.activeHousehold)
    }

    var body: some View {
        HStack(spacing: 0) {
            textColumn
                .frame(width: 320)
                .padding(20)
            Divider()
            contentColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 780, height: 540)
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .task {
            if let initialText, describe.phase == .compose, describe.text.isEmpty {
                describe.text = initialText
                read()
            } else {
                textFocused = true
            }
        }
        .onDisappear { describe.cancel() }
    }

    private func read() {
        textFocused = false   // so Return then means Add, not a new line
        describe.read(household: household)
    }

    // MARK: Left: the text

    private var textColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $describe.text)
                    .font(.body)
                    .focused($textFocused)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .disabled(describe.phase == .reading)
                if describe.text.isEmpty {
                    Text("Vacuum the living room on Saturdays, do the dishes every night, and clean the bathroom every other week.")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.quaternary))
            HStack {
                Spacer()
                Button(describe.phase == .review ? "Read Again" : "Get Chores") { read() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!describe.canRead || describe.phase == .reading)
                    .help("Turn the text into chores (⌘↩)")
            }
            Label("Read on this Mac. What you type isn't saved.", systemImage: "lock.fill")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: Right: the chores

    @ViewBuilder private var contentColumn: some View {
        switch describe.phase {
        case .compose:
            VStack(alignment: .leading, spacing: 12) {
                Text("Describe Chores").font(.title2.bold())
                Text("Type what needs doing and when, in your own words: one chore or a whole routine. Choreganize turns it into chores with their days and rooms, and you pick which to keep.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding(24)
        case .reading:
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Reading your chores…").font(.headline)
                }
                ForEach(Array(describe.live.enumerated()), id: \.offset) { _, chore in
                    Label(chore.name, systemImage: "sparkles")
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                Spacer()
            }
            .padding(24)
        case .review:
            reviewForm
        case .nothingFound:
            ContentUnavailableView("No Chores Found", systemImage: "text.magnifyingglass",
                                   description: Text("Try naming a chore and when it happens, like “water the plants on Sundays.”"))
        case .failed(let error):
            ContentUnavailableView {
                Label("Couldn't Read That", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error.textMessage)
            } actions: {
                if error != .unavailable {
                    Button("Try Again") { read() }
                }
            }
        }
    }

    private var reviewForm: some View {
        Form {
            Section {
                ForEach(describe.drafts) { draft in choreRow(draft) }
            } header: {
                Text("Chores")
            } footer: {
                Text("Uncheck any you don't want. Change a schedule or room with its edit button, or anytime later.")
            }
        }
        .formStyle(.grouped)
    }

    private func choreRow(_ draft: ChoreDraft) -> some View {
        let isDuplicate = describe.duplicateIDs.contains(draft.id)
        return HStack(alignment: .firstTextBaseline) {
            Toggle(isOn: Binding(get: { describe.selected.contains(draft.id) },
                                 set: { _ in describe.toggle(draft.id) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(draft.name)
                    Text(describe.detail(for: draft))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !isDuplicate, let note = describe.plusNotes[draft.id] {
                        Label(note, systemImage: "lock")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .toggleStyle(.checkbox)
            Spacer()
            Button {
                editingID = draft.id
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.borderless)
            .help("Edit name, schedule and room")
            .popover(isPresented: Binding(get: { editingID == draft.id },
                                          set: { if !$0 { editingID = nil } }),
                     arrowEdge: .trailing) {
                MacDraftEditor(draft: draft, areas: scopedAreas) { describe.update($0) }
            }
        }
        .disabled(isDuplicate)
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack {
            if describe.phase == .review {
                Text("\(describe.chosenCount) of \(describe.drafts.count) selected")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(describe.chosenCount == 0 ? "Add Chores"
                   : "Add \(describe.chosenCount) Chore\(describe.chosenCount == 1 ? "" : "s")") {
                save()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(describe.phase != .review || describe.chosenCount == 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func save() {
        let drafts = describe.chosenDrafts
        guard !drafts.isEmpty else { return }
        AddFlowCommit.commit(drafts, in: context, household: model.activeHousehold,
                             allowsPlusSchedule: Entitlements.isPlus(for: model.activeHousehold))
        Log.info("Describe Chores (Mac): added \(drafts.count) chore(s)")
        dismiss()
    }
}
