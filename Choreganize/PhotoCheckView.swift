#if os(iOS)
import CoreData
import SwiftUI

/// Check off with a photo (CG-A3 / #107): pick a room, photograph it, and the
/// on-device model says which of the room's open chores look done. Those come back
/// pre-checked; nothing is completed until the user taps Mark Done. Presented as a
/// sheet from today's DayPage.
struct PhotoCheckView: View {
    let date: Date
    /// Today's open, in-scope chores (the DayPage's "incomplete" set).
    let chores: [CDChore]

    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @StateObject private var check = PhotoCheckModel()
    // Pre-warmed so the Mark Done haptic doesn't cold-start the engine on the main thread.
    @State private var successHaptic = SuccessHaptic()

    private var rooms: [PhotoCheckRoom] { RoomVisionMapping.checkRooms(for: chores) }

    var body: some View {
        NavigationStack {
            Group {
                switch check.phase {
                case .pickRoom:          roomStep
                case .capture:           captureStep
                case .checking:          checkingStep
                case .results:           resultsStep
                case .failed(let error): failedStep(error)
                }
            }
            .navigationTitle("Photo Check-Off")
            .compatInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if check.phase == .results {
                    ToolbarItem(placement: .compatTrailing) {
                        Button("Retake") { check.retake() }
                            .accessibilityIdentifier("photocheck.retake")
                    }
                }
            }
        }
        .onAppear {
            successHaptic.prepare()
            // One room with open chores: skip straight to the photo.
            if check.phase == .pickRoom, rooms.count == 1, let only = rooms.first { select(only) }
        }
        .onDisappear { check.cancel() }
    }

    private func select(_ room: PhotoCheckRoom) {
        check.select(room)
        #if DEBUG
        if let photo = PhotoInput.testPhoto { check.start(with: photo) }
        #endif
    }

    // MARK: Room

    private var roomStep: some View {
        List {
            Section {
                ForEach(rooms) { room in
                    Button { select(room) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(room.title).foregroundStyle(.primary)
                                Text("\(room.chores.count) open chore\(room.chores.count == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("photocheck.room.\(room.title)")
                }
            } header: {
                Text("Which room?")
            } footer: {
                Text("Take a photo of the room and Choreganize checks which of its open chores look done. You confirm before anything is marked.")
            }
        }
    }

    // MARK: Capture

    private var captureStep: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tint)
            VStack(spacing: 8) {
                Text(check.roomTitle).font(.title2.bold())
                Text(check.roomAreaID == nil
                     ? "Take a photo of where these chores happen to see which look done."
                     : "Take a photo of the room to see which of its \(check.candidateCount) open chore\(check.candidateCount == 1 ? "" : "s") look done.")
                    .multilineTextAlignment(.center)
            }
            Label("Analyzed on this device. The photo isn't saved.", systemImage: "lock.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            PhotoSourceButtons { check.start(with: $0) }
            if rooms.count > 1 {
                Button("Choose a Different Room") { check.changeRoom() }
                    .font(.callout)
            }
        }
        .padding(24)
    }

    // MARK: Checking

    private var checkingStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            photoHeader
            HStack(spacing: 10) {
                ProgressView()
                Text("Checking \(check.candidateCount) chore\(check.candidateCount == 1 ? "" : "s")…")
                    .font(.headline)
            }
            Spacer()
        }
        .padding()
    }

    // MARK: Results

    private var resultsStep: some View {
        List {
            Section {
                photoHeader
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            } footer: {
                if !check.observations.isEmpty { Text(check.observations) }
            }
            ForEach(PhotoCheckModel.sectionOrder, id: \.self) { verdict in
                let items = check.items.filter { $0.verdict == verdict }
                if !items.isEmpty {
                    Section(Self.title(for: verdict)) {
                        ForEach(items) { item in row(item) }
                    }
                }
            }
            if !check.items.contains(where: { $0.verdict == .looksDone }) {
                Section {
                    Text("Nothing in the photo looks done yet. You can still check chores off yourself.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button(action: markDone) {
                Text(check.selected.isEmpty ? "Mark Done" : "Mark \(check.selected.count) Done")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(check.selected.isEmpty)
            .padding()
            .background(.bar)
            .accessibilityIdentifier("photocheck.markDone")
        }
    }

    private func row(_ item: PhotoCheckModel.Item) -> some View {
        let isOn = check.selected.contains(item.id)
        return Button { check.toggle(item.id) } label: {
            HStack(spacing: 12) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                Text(item.name).foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("photocheck.item.\(item.name)")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private static func title(for verdict: ChoreVerdict) -> String {
        switch verdict {
        case .looksDone: return "Looks done"
        case .cantTell:  return "Couldn't tell from the photo"
        case .notDone:   return "Still to do"
        }
    }

    // MARK: Failed

    private func failedStep(_ error: RoomVisionError) -> some View {
        ContentUnavailableView {
            Label("Couldn't Check the Photo", systemImage: "exclamationmark.triangle")
        } description: {
            Text(error.message)
        } actions: {
            if check.photo != nil && error != .unreadablePhoto && error != .unavailable {
                Button("Try Again") { check.check() }
                    .buttonStyle(.borderedProminent)
            }
            Button("Choose Another Photo") { check.retake() }
        }
    }

    // MARK: Shared

    @ViewBuilder private var photoHeader: some View {
        if let photo = check.photo {
            Image(decorative: photo, scale: 1)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity)
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .accessibilityHidden(true)
        }
    }

    private func markDone() {
        guard !check.selected.isEmpty else { return }
        BulkChoreOps.markAllDone(check.selected, on: date, in: context)
        Log.info("Photo check-off: marked \(check.selected.count) of \(check.items.count) chore(s) done")
        successHaptic.success()
        dismiss()
    }
}

/// State for one photo check: the chosen room, the photo, the model's verdicts, and
/// the user's picks. Engine calls are gated to iOS 27; the model itself is iOS 18-safe.
@MainActor
final class PhotoCheckModel: ObservableObject {
    enum Phase: Equatable {
        case pickRoom, capture, checking, results
        case failed(RoomVisionError)
    }

    struct Item: Identifiable, Equatable {
        let id: NSManagedObjectID
        let name: String
        let verdict: ChoreVerdict
    }

    /// Results are shown looks-done first, then can't-tell, then still-to-do.
    static let sectionOrder: [ChoreVerdict] = [.looksDone, .cantTell, .notDone]

    @Published private(set) var phase: Phase = .pickRoom
    @Published private(set) var roomTitle = ""
    @Published private(set) var roomAreaID: UUID?
    @Published private(set) var photo: CGImage?
    @Published private(set) var observations = ""
    @Published private(set) var items: [Item] = []
    @Published private(set) var selected: Set<NSManagedObjectID> = []

    private var candidates: [(id: NSManagedObjectID, name: String)] = []
    private var task: Task<Void, Never>?

    var candidateCount: Int { candidates.count }

    func select(_ room: PhotoCheckRoom) {
        roomTitle = room.title
        roomAreaID = room.areaID
        candidates = room.chores.map { (id: $0.objectID, name: $0.name ?? "Untitled") }
        phase = .capture
    }

    func start(with image: CGImage?) {
        guard let image else {
            photo = nil
            phase = .failed(.unreadablePhoto)
            return
        }
        photo = image
        check()
    }

    func check() {
        guard let photo, !candidates.isEmpty else { return }
        task?.cancel()
        observations = ""
        items = []
        phase = .checking
        guard #available(iOS 27.0, macOS 27.0, *) else {
            phase = .failed(.unavailable)
            return
        }
        let names = candidates.map(\.name)
        let room = roomAreaID == nil ? nil : roomTitle
        let started = Date()
        task = Task { [weak self] in
            do {
                let (result, usage) = try await RoomVisionEngine.check(names, roomName: room, in: photo)
                guard let self, !Task.isCancelled else { return }
                Log.info("Photo check-off: \(result.verdicts.filter { $0 == .looksDone }.count) of \(names.count) look done, "
                         + String(format: "%.1f s, ", Date().timeIntervalSince(started))
                         + "\(usage.inputTokens) in / \(usage.outputTokens) out tokens")
                self.observations = result.observations
                self.items = zip(self.candidates, result.verdicts).map { Item(id: $0.0.id, name: $0.0.name, verdict: $0.1) }
                self.selected = RoomVisionMapping.preselected(self.items.map(\.id), verdicts: self.items.map(\.verdict))
                self.phase = .results
            } catch is CancellationError {
                return
            } catch {
                Log.error("Photo check-off failed: \(error)")
                self?.phase = .failed(error as? RoomVisionError ?? .failed)
            }
        }
    }

    func toggle(_ id: NSManagedObjectID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    func retake() {
        task?.cancel()
        photo = nil
        observations = ""
        items = []
        selected = []
        phase = .capture
    }

    func changeRoom() {
        retake()
        phase = .pickRoom
    }

    func cancel() { task?.cancel() }
}
#endif
