import CoreData
import SwiftUI

// Shared by the iPhone (RoomSnapView) and Mac (MacRoomSnapSheet) Snap a Room UIs.

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

#if DEBUG
extension RoomPhoto {
    /// UI tests and snapshots: a photo path handed in through the environment
    /// (`CHOREGANIZE_ROOM_PHOTO`), used in place of the camera, picker, or a drop.
    static var testPhotoFromEnvironment: CGImage? {
        guard let path = ProcessInfo.processInfo.environment["CHOREGANIZE_ROOM_PHOTO"], !path.isEmpty else { return nil }
        return prepare(contentsOf: URL(fileURLWithPath: path))
    }
}
#endif
