import CoreData
import SwiftUI

/// Check off with a photo on the Mac (#121): the same model as iPhone
/// (PhotoCheckModel), presented as a two-column sheet. The room is a pop-up at the
/// top instead of a separate step: a photo that arrives first (dropped, pasted,
/// imported) is matched to one of today's rooms by the model, and changing the room
/// re-checks the same photo. Chores that look done come back checked; nothing is
/// marked done until Mark Done (Return). Always today: a photo shows the room now.
struct MacPhotoCheckSheet: View {
    var initialPhoto: CGImage?

    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @FetchRequest(fetchRequest: displayChoresFetchRequest()) private var chores: FetchedResults<CDChore>
    @FetchRequest(sortDescriptors: [SortDescriptor(\CDLockedDay.date)]) private var lockedDays: FetchedResults<CDLockedDay>

    @StateObject private var check = PhotoCheckModel()
    @State private var roomID: String?
    /// The user picked the room themselves; photos then go straight to that room.
    @State private var roomChosenByUser = false
    /// A photo waiting on the room: being identified, or awaiting the user's pick.
    @State private var pendingPhoto: CGImage?
    @State private var identifying = false

    /// Today's open chores by room, unless today is already finished (locked).
    private var rooms: [PhotoCheckRoom] {
        let today = Date()
        let active = model.activeHousehold
        guard !DayLock.isLocked(today, in: Array(lockedDays).inScope(active)) else { return [] }
        let open = Scheduling.chores(Array(chores).inScope(active), for: today).filter { !$0.isCompleted(on: today) }
        return RoomVisionMapping.checkRooms(for: open)
    }

    var body: some View {
        HStack(spacing: 0) {
            photoColumn
                .frame(width: 320)
                .padding(20)
            Divider()
            contentColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 760, height: 520)
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .acceptsPhotoPasteAndImport { receive($0) }
        .task { chooseFirstRoom() }
        .onDisappear { check.cancel() }
    }

    private func chooseFirstRoom() {
        guard check.phase == .pickRoom, let first = rooms.first else { return }
        roomID = first.id
        check.select(first)
        if let initialPhoto { receive(initialPhoto) }
    }

    /// A photo arrived. With the room already settled (picked, or the only one), check
    /// it; otherwise ask the model which of today's rooms it shows first.
    private func receive(_ photo: CGImage?) {
        guard let photo else { return check.start(with: nil) }   // unreadable → error state
        guard !roomChosenByUser, rooms.count > 1 else { return check.start(with: photo) }
        pendingPhoto = photo
        identifying = true
        let named = rooms.filter { $0.areaID != nil }
        Task {
            var match: PhotoCheckRoom?
            if #available(macOS 27.0, *),
               let name = try? await RoomVisionEngine.identifyRoom(in: photo, among: named.map(\.title)) {
                match = named.first { $0.title == name }
            }
            identifying = false
            guard let match else { return }   // none of today's rooms: the user picks
            pendingPhoto = nil
            roomID = match.id
            check.select(match)
            check.start(with: photo)
        }
    }

    // MARK: Left: the photo

    @ViewBuilder private var photoColumn: some View {
        if let photo = check.photo ?? pendingPhoto {
            VStack(alignment: .leading, spacing: 12) {
                MacPhotoPanel(photo: photo, caption: check.observations)
                Button("Use Another Photo…") {
                    pendingPhoto = nil
                    check.retake()
                }
                .disabled(check.phase == .checking || identifying)
            }
        } else {
            MacPhotoDropZone(prompt: rooms.isEmpty ? "Nothing left to check today" : "Add a photo of the room") {
                receive($0)
            }
            .disabled(rooms.isEmpty)
        }
    }

    // MARK: Right: the room and the verdicts

    @ViewBuilder private var contentColumn: some View {
        if rooms.isEmpty {
            ContentUnavailableView("Nothing Left Today", systemImage: "checkmark.circle",
                                   description: Text("Every chore due today is done, or today is locked."))
        } else {
            VStack(spacing: 0) {
                Picker("Room", selection: Binding(get: { roomID }, set: switchRoom)) {
                    ForEach(rooms) { room in
                        Text("\(room.title) (\(room.chores.count))").tag(Optional(room.id))
                    }
                }
                .fixedSize()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 4)
                phaseContent
            }
        }
    }

    private func switchRoom(_ id: String?) {
        roomID = id
        roomChosenByUser = true
        guard let room = rooms.first(where: { $0.id == id }) else { return }
        if let photo = pendingPhoto {
            pendingPhoto = nil
            check.select(room)
            check.start(with: photo)
        } else {
            check.switchRoom(to: room)
        }
    }

    @ViewBuilder private var phaseContent: some View {
        if identifying {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Finding the room…").font(.headline)
                Spacer()
            }
            .padding(20)
            Spacer()
        } else if pendingPhoto != nil {
            VStack(alignment: .leading, spacing: 10) {
                Text("Which room is this?").font(.title3.bold())
                Text("The photo doesn't look like any room with chores left today. Pick its room above, and Choreganize will check it.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding(20)
        } else {
            verdictContent
        }
    }

    @ViewBuilder private var verdictContent: some View {
        switch check.phase {
        case .pickRoom, .capture:
            VStack(alignment: .leading, spacing: 10) {
                Text("Check Off with a Photo").font(.title2.bold())
                Text("Add a photo of the \(check.roomAreaID == nil ? "place these chores happen" : check.roomTitle.lowercased()). Chores that look done come back checked for you to confirm; nothing is marked done until you do.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding(20)
        case .checking:
            VStack(alignment: .leading) {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Checking \(check.candidateCount) chore\(check.candidateCount == 1 ? "" : "s")…")
                        .font(.headline)
                }
                Spacer()
            }
            .padding(20)
        case .results:
            resultsForm
        case .failed(let error):
            ContentUnavailableView {
                Label("Couldn't Check the Photo", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error.message)
            } actions: {
                if check.photo != nil && error != .unreadablePhoto && error != .unavailable {
                    Button("Try Again") { check.check() }
                }
            }
        }
    }

    private var resultsForm: some View {
        Form {
            ForEach(PhotoCheckModel.sectionOrder, id: \.self) { verdict in
                let items = check.items.filter { $0.verdict == verdict }
                if !items.isEmpty {
                    Section(Self.title(for: verdict)) {
                        ForEach(items) { item in
                            Toggle(item.name, isOn: Binding(get: { check.selected.contains(item.id) },
                                                            set: { _ in check.toggle(item.id) }))
                                .toggleStyle(.checkbox)
                        }
                    }
                }
            }
            if !check.items.contains(where: { $0.verdict == .looksDone }) {
                Section {
                    Text("Nothing in the photo looks done yet. You can still check chores off yourself.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private static func title(for verdict: ChoreVerdict) -> String {
        switch verdict {
        case .looksDone: return "Looks done"
        case .cantTell:  return "Couldn't tell from the photo"
        case .notDone:   return "Still to do"
        }
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(check.selected.isEmpty ? "Mark Done" : "Mark \(check.selected.count) Done") {
                markDone()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(check.phase != .results || check.selected.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func markDone() {
        guard !check.selected.isEmpty else { return }
        BulkChoreOps.markAllDone(check.selected, on: Date(), in: context)
        Log.info("Photo check-off (Mac): marked \(check.selected.count) of \(check.items.count) chore(s) done")
        dismiss()
    }
}
