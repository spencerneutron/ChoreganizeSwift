import CoreData
import SwiftUI

// Shared by the iPhone (PhotoCheckView) and Mac (MacPhotoCheckSheet) check-off UIs.

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

    /// Switches rooms; with a photo already in hand, re-checks it against the new
    /// room (the Mac sheet's room pop-up). No photo: back to capture.
    func switchRoom(to room: PhotoCheckRoom) {
        select(room)
        if photo != nil { check() }
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
