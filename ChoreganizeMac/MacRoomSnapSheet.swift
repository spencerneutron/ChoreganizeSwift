import CoreData
import SwiftUI

/// Snap a Room on the Mac (#121): the same flow and model as iPhone (RoomSnapModel),
/// presented the Mac way — a two-column sheet with the photo on the left and the
/// suggestions on the right, native checkboxes, the room as a pop-up, schedules in a
/// popover, Return to add and Esc to cancel. A photo can be dropped, pasted, picked,
/// opened, or imported from an iPhone with Continuity Camera.
struct MacRoomSnapSheet: View {
    var initialPhoto: CGImage?

    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @FetchRequest(sortDescriptors: [SortDescriptor(\CDArea.name)]) private var areas: FetchedResults<CDArea>
    @FetchRequest(sortDescriptors: [SortDescriptor(\CDChore.name)]) private var chores: FetchedResults<CDChore>

    @StateObject private var snap = RoomSnapModel()
    @State private var editingID: ChoreDraft.ID?

    private var scopedAreas: [CDArea] { areas.inScope(model.activeHousehold) }

    var body: some View {
        HStack(spacing: 0) {
            photoColumn
                .frame(width: 320)
                .padding(20)
            Divider()
            contentColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 780, height: 540)
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .acceptsPhotoPasteAndImport { start($0) }
        .task {
            if snap.phase == .capture, let photo = initialPhoto { start(photo) }
        }
        .onDisappear { snap.cancel() }
    }

    private func start(_ photo: CGImage?) {
        snap.start(with: photo, household: household)
    }

    /// What the mapping needs to know about the household, captured when a photo arrives.
    private var household: RoomSnapModel.Household {
        let scopedChores = Array(chores).inScope(model.activeHousehold)
        return RoomSnapModel.Household(
            areas: scopedAreas.compactMap { area in area.id.map { (id: $0, name: area.name ?? "") } },
            home: RoomVisionMapping.homeContext(areas: scopedAreas, chores: scopedChores),
            weekdayLoad: RoomVisionMapping.weekdayLoad(of: scopedChores),
            existingNames: { RoomVisionMapping.existingChoreNames(in: $0, chores: scopedChores) })
    }

    // MARK: Left: the photo

    @ViewBuilder private var photoColumn: some View {
        if let photo = snap.photo {
            VStack(alignment: .leading, spacing: 12) {
                MacPhotoPanel(photo: photo, caption: snap.live.observations)
                Button("Use Another Photo…") { snap.retake() }
                    .disabled(snap.phase == .analyzing)
            }
        } else {
            MacPhotoDropZone(prompt: "Add a photo of a room") { start($0) }
        }
    }

    // MARK: Right: what the model found

    @ViewBuilder private var contentColumn: some View {
        switch snap.phase {
        case .capture:
            VStack(alignment: .leading, spacing: 12) {
                Text("Snap a Room").font(.title2.bold())
                Text("Add a photo of a room and get chore ideas for it: the chores most households do there, with how often to do them. You pick which to keep.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding(24)
        case .analyzing:
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(snap.live.chores.isEmpty
                         ? "Looking at your room…"
                         : "Ideas for your \(snap.live.roomName.lowercased())…")
                        .font(.headline)
                }
                ForEach(Array(snap.live.chores.enumerated()), id: \.offset) { _, chore in
                    Label(chore.name, systemImage: "sparkles")
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                Spacer()
            }
            .padding(24)
        case .review:
            reviewForm
        case .failed(let error):
            ContentUnavailableView {
                Label("Couldn't Read the Photo", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error.message)
            } actions: {
                if snap.photo != nil && error != .unreadablePhoto && error != .unavailable {
                    Button("Try Again") { snap.analyze() }
                }
            }
        }
    }

    private var reviewForm: some View {
        Form {
            Section {
                Picker("Add to", selection: $snap.room) {
                    ForEach(scopedAreas, id: \.objectID) { area in
                        if let id = area.id {
                            Text(area.name ?? "Untitled").tag(RoomSnapModel.RoomChoice.existing(id))
                        }
                    }
                    Divider()
                    Text("New Room…").tag(RoomSnapModel.RoomChoice.new)
                }
                if snap.room == .new {
                    TextField("Room name", text: $snap.newRoomName, prompt: Text("Room name"))
                }
            }
            Section {
                ForEach(snap.drafts) { draft in suggestionRow(draft) }
            } header: {
                Text("Suggested chores")
            } footer: {
                Text("Uncheck any you don't want. Change a schedule with its edit button, or anytime later.")
            }
        }
        .formStyle(.grouped)
        .onChange(of: snap.room) { _, _ in snap.refreshDuplicates() }
        .onChange(of: snap.newRoomName) { _, _ in snap.refreshDuplicates() }
    }

    private func suggestionRow(_ draft: ChoreDraft) -> some View {
        let isDuplicate = snap.duplicateIDs.contains(draft.id)
        return HStack(alignment: .firstTextBaseline) {
            Toggle(isOn: Binding(get: { snap.selected.contains(draft.id) },
                                 set: { _ in snap.toggle(draft.id) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(draft.name)
                    Text(isDuplicate ? "Already in this room" : draft.scheduleSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
            .help("Edit name and schedule")
            .popover(isPresented: Binding(get: { editingID == draft.id },
                                          set: { if !$0 { editingID = nil } }),
                     arrowEdge: .trailing) {
                MacDraftEditor(draft: draft) { snap.update($0) }
            }
        }
        .disabled(isDuplicate)
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack {
            if snap.phase == .review {
                Text("\(snap.chosenCount) of \(snap.drafts.count) selected")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(snap.chosenCount == 0 ? "Add Chores" : "Add \(snap.chosenCount) Chore\(snap.chosenCount == 1 ? "" : "s")") {
                save()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(snap.phase != .review || snap.chosenCount == 0 || snap.areaRef == .none)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func save() {
        let drafts = snap.chosenDrafts
        guard !drafts.isEmpty else { return }
        AddFlowCommit.commit(drafts, in: context, household: model.activeHousehold)
        Log.info("Snap a Room (Mac): added \(drafts.count) chore(s)")
        dismiss()
    }
}

/// Edits one draft's name and schedule in place (a popover on the row), and its room
/// when `areas` are given (Describe Chores, where each chore has its own room).
struct MacDraftEditor: View {
    @State private var draft: ChoreDraft
    var areas: [CDArea] = []
    var onChange: (ChoreDraft) -> Void

    init(draft: ChoreDraft, areas: [CDArea] = [], onChange: @escaping (ChoreDraft) -> Void) {
        _draft = State(initialValue: draft)
        self.areas = areas
        self.onChange = onChange
    }

    /// The Area picker lists existing areas; a room the draft names but that doesn't
    /// exist yet (`.new`) shows as None and is kept until another area is picked.
    private var areaID: Binding<UUID?> {
        Binding(get: {
            if case .existing(let id) = draft.areaRef { return id }
            return nil
        }, set: { id in
            if let id {
                draft.areaRef = .existing(id)
            } else if case .existing = draft.areaRef {
                draft.areaRef = .none
            }
        })
    }

    var body: some View {
        Form {
            TextField("Name", text: $draft.name)
            ChoreFormRows(name: $draft.name, isDaily: $draft.isDaily, frequency: $draft.frequency,
                          day: $draft.day, areaId: areaID, areas: areas,
                          showsName: false, showsArea: !areas.isEmpty)
        }
        .formStyle(.grouped)
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: draft) { _, edited in
            let normalized = edited.normalized()
            if !normalized.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { onChange(normalized) }
        }
    }
}
