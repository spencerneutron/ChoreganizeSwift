#if os(iOS)
import CoreData
import SwiftUI

/// Snap a Room (CG-A1 / #105): photograph a room, get chore suggestions for it from
/// the on-device model, keep the ones you want, and save them through the add-flow
/// engine. Pushed in-tab from EditHomeView, like the add-flow lenses.
struct RoomSnapFlowView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @FetchRequest(sortDescriptors: [SortDescriptor(\CDArea.name)]) private var areas: FetchedResults<CDArea>
    @FetchRequest(sortDescriptors: [SortDescriptor(\CDChore.name)]) private var chores: FetchedResults<CDChore>

    @StateObject private var snap = RoomSnapModel()
    @State private var editing: ChoreDraft?
    // Pre-warmed so the Add haptic doesn't cold-start the engine on the main thread.
    @State private var successHaptic = SuccessHaptic()

    private var scopedAreas: [CDArea] { areas.inScope(model.activeHousehold) }

    var body: some View {
        Group {
            switch snap.phase {
            case .capture:          captureStep
            case .analyzing:        analyzingStep
            case .review:           reviewStep
            case .failed(let error): failedStep(error)
            }
        }
        .navigationTitle("Snap a Room")
        .compatInlineNavigationTitle()
        .onAppear { successHaptic.prepare() }
        .onDisappear { snap.cancel() }
        #if DEBUG
        .task {
            if snap.phase == .capture, let photo = PhotoInput.testPhoto { snap.start(with: photo, household: household) }
        }
        #endif
        .sheet(item: $editing) { draft in
            AddFlowDraftEditor(draft: draft, grouping: .byArea, areas: scopedAreas, showsArea: false) {
                snap.update($0)
            }
        }
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

    // MARK: Capture

    private var captureStep: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tint)
            VStack(spacing: 8) {
                Text("Snap a Room").font(.title2.bold())
                Text("Take a photo of a room and get chore ideas for it.")
                    .multilineTextAlignment(.center)
            }
            Label("Analyzed on this device. The photo isn't saved.", systemImage: "lock.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            PhotoSourceButtons { snap.start(with: $0, household: household) }
        }
        .padding(24)
    }

    // MARK: Analyzing

    private var analyzingStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                photoHeader
                HStack(spacing: 10) {
                    ProgressView()
                    // The room name is complete before the first chore streams in.
                    Text(snap.live.chores.isEmpty
                         ? "Looking at your room…"
                         : "Ideas for your \(snap.live.roomName.lowercased())…")
                        .font(.headline)
                }
                if !snap.live.observations.isEmpty {
                    Text(snap.live.observations)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(snap.live.chores.enumerated()), id: \.offset) { _, chore in
                    Label(chore.name, systemImage: "sparkles")
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding()
        }
    }

    // MARK: Review

    private var reviewStep: some View {
        List {
            Section {
                photoHeader
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            } footer: {
                if !snap.live.observations.isEmpty { Text(snap.live.observations) }
            }

            Section("Room") {
                Picker("Add to", selection: $snap.room) {
                    ForEach(scopedAreas, id: \.objectID) { area in
                        if let id = area.id {
                            Text(area.name ?? "Untitled").tag(RoomSnapModel.RoomChoice.existing(id))
                        }
                    }
                    Text("New Room").tag(RoomSnapModel.RoomChoice.new)
                }
                .accessibilityIdentifier("roomsnap.room")
                if snap.room == .new {
                    TextField("Room name", text: $snap.newRoomName)
                        .compatAutocapitalizeWords()
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("roomsnap.newRoomName")
                }
            }

            Section {
                ForEach(Array(snap.drafts.enumerated()), id: \.element.id) { index, draft in
                    suggestionRow(draft, index: index)
                }
            } header: {
                Text("Suggested chores")
            } footer: {
                Text("Tap a chore to leave it out. You can change its schedule here, or anytime later.")
            }
        }
        .onChange(of: snap.room) { _, _ in snap.refreshDuplicates() }
        .onChange(of: snap.newRoomName) { _, _ in snap.refreshDuplicates() }
        .safeAreaInset(edge: .bottom) {
            Button(action: save) {
                Text(snap.chosenCount == 0 ? "Add Chores" : "Add \(snap.chosenCount) Chore\(snap.chosenCount == 1 ? "" : "s")")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(snap.chosenCount == 0 || snap.areaRef == .none)
            .padding()
            .background(.bar)
            .accessibilityIdentifier("roomsnap.add")
        }
        .toolbar {
            ToolbarItem(placement: .compatTrailing) {
                Button("Retake") { snap.retake() }
                    .accessibilityIdentifier("roomsnap.retake")
            }
        }
    }

    private func suggestionRow(_ draft: ChoreDraft, index: Int) -> some View {
        let isDuplicate = snap.duplicateIDs.contains(draft.id)
        let isOn = snap.selected.contains(draft.id)
        return HStack(spacing: 12) {
            Button { snap.toggle(draft.id) } label: {
                HStack(spacing: 12) {
                    Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(draft.name).foregroundStyle(.primary)
                        Text(isDuplicate ? "Already in this room" : draft.scheduleSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("roomsnap.suggestion.\(index)")
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

    // MARK: Failed

    private func failedStep(_ error: RoomVisionError) -> some View {
        ContentUnavailableView {
            Label("Couldn't Read the Photo", systemImage: "exclamationmark.triangle")
        } description: {
            Text(error.message)
        } actions: {
            if snap.photo != nil && error != .unreadablePhoto && error != .unavailable {
                Button("Try Again") { snap.analyze() }
                    .buttonStyle(.borderedProminent)
            }
            Button("Choose Another Photo") { snap.retake() }
        }
    }

    // MARK: Shared

    @ViewBuilder private var photoHeader: some View {
        if let photo = snap.photo {
            Image(decorative: photo, scale: 1)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity)
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .accessibilityHidden(true)
        }
    }

    private func save() {
        let drafts = snap.chosenDrafts
        guard !drafts.isEmpty else { return }
        AddFlowCommit.commit(drafts, in: context, household: model.activeHousehold)
        Log.info("Snap a Room: added \(drafts.count) chore(s)")
        successHaptic.success()
        dismiss()
    }
}

/// State for one Snap a Room pass: the photo, the streaming suggestion, and the
/// user's picks. Engine calls are gated to iOS 27; the model itself is iOS 18-safe.
@MainActor
final class RoomSnapModel: ObservableObject {
    enum Phase: Equatable {
        case capture, analyzing, review
        case failed(RoomVisionError)
    }

    /// Where the kept chores go: an existing area, or a new room named in `newRoomName`.
    enum RoomChoice: Hashable {
        case existing(UUID)
        case new
    }

    /// The household facts the mapping needs, snapshotted when a photo arrives.
    struct Household {
        var areas: [(id: UUID, name: String)] = []
        var home = RoomVisionHomeContext()
        var weekdayLoad: [Weekday: Int] = [:]
        var existingNames: (AreaRef) -> [String] = { _ in [] }
    }

    @Published private(set) var phase: Phase = .capture
    @Published private(set) var photo: CGImage?
    @Published private(set) var live = RoomSuggestion(observations: "", roomName: "", chores: [])
    @Published private(set) var drafts: [ChoreDraft] = []
    @Published private(set) var selected: Set<ChoreDraft.ID> = []
    @Published private(set) var duplicateIDs: Set<ChoreDraft.ID> = []
    @Published var room: RoomChoice = .new
    @Published var newRoomName = ""

    private var household = Household()
    private var task: Task<Void, Never>?

    var areaRef: AreaRef {
        switch room {
        case .existing(let id):
            return .existing(id)
        case .new:
            let name = newRoomName.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? .none : .new(name)
        }
    }

    /// The kept suggestions, pointed at the chosen room.
    var chosenDrafts: [ChoreDraft] {
        let ref = areaRef
        return drafts
            .filter { selected.contains($0.id) && !duplicateIDs.contains($0.id) }
            .map { draft in
                var draft = draft
                draft.areaRef = ref
                return draft
            }
    }

    var chosenCount: Int { drafts.filter { selected.contains($0.id) && !duplicateIDs.contains($0.id) }.count }

    func start(with image: CGImage?, household: Household) {
        self.household = household
        guard let image else {
            photo = nil
            phase = .failed(.unreadablePhoto)
            return
        }
        photo = image
        analyze()
    }

    func analyze() {
        guard let photo else { return }
        task?.cancel()
        live = RoomSuggestion(observations: "", roomName: "", chores: [])
        phase = .analyzing
        guard #available(iOS 27.0, macOS 27.0, *) else {
            phase = .failed(.unavailable)
            return
        }
        let home = household.home
        let started = Date()
        task = Task { [weak self] in
            do {
                for try await snapshot in RoomVisionEngine.streamSuggestions(for: photo, home: home) {
                    guard let self else { return }
                    if snapshot.chores.count != self.live.chores.count {
                        withAnimation(.snappy) { self.live = snapshot }
                    } else {
                        self.live = snapshot
                    }
                }
                guard let self, !Task.isCancelled else { return }
                Log.info("Snap a Room: \(self.live.chores.count) suggestion(s) for \"\(self.live.roomName)\" in "
                         + String(format: "%.1f s", Date().timeIntervalSince(started)))
                self.finish()
            } catch is CancellationError {
                return
            } catch {
                Log.error("Snap a Room failed: \(error)")
                self?.phase = .failed(error as? RoomVisionError ?? .failed)
            }
        }
    }

    private func finish() {
        guard !live.chores.isEmpty else {
            phase = .failed(.failed)
            return
        }
        let ref = RoomVisionMapping.areaRef(forRoomName: live.roomName, among: household.areas)
        switch ref {
        case .existing(let id):
            room = .existing(id)
            newRoomName = ""
        case .new(let name):
            room = .new
            newRoomName = name
        case .none:
            room = .new
            newRoomName = ""
        }
        drafts = RoomVisionMapping.drafts(from: live.chores, areaRef: ref, weekdayLoad: household.weekdayLoad)
        duplicateIDs = RoomVisionMapping.duplicates(in: drafts, existingNames: household.existingNames(ref))
        selected = Set(drafts.map(\.id)).subtracting(duplicateIDs)
        phase = .review
    }

    /// Re-checks which suggestions the chosen room already has. Rows that become
    /// duplicates are deselected; rows that stop being duplicates are selected again.
    func refreshDuplicates() {
        let previous = duplicateIDs
        duplicateIDs = RoomVisionMapping.duplicates(in: drafts, existingNames: household.existingNames(areaRef))
        selected.subtract(duplicateIDs)
        selected.formUnion(previous.subtracting(duplicateIDs))
    }

    func toggle(_ id: ChoreDraft.ID) {
        guard !duplicateIDs.contains(id) else { return }
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    /// Applies an edit from the draft editor (same id, same position).
    func update(_ draft: ChoreDraft) {
        guard let index = drafts.firstIndex(where: { $0.id == draft.id }) else { return }
        drafts[index] = draft
        refreshDuplicates()
    }

    func retake() {
        task?.cancel()
        photo = nil
        live = RoomSuggestion(observations: "", roomName: "", chores: [])
        drafts = []
        selected = []
        duplicateIDs = []
        phase = .capture
    }

    func cancel() { task?.cancel() }
}
#endif
