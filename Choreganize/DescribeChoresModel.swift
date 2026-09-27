import CoreData
import SwiftUI

// Shared by the iPhone (DescribeChoresView) and Mac (MacDescribeChoresSheet) UIs.

/// State for one Describe Chores pass: the text, the chores streaming out of it, and
/// the user's picks. Engine calls are gated to iOS/macOS 27; the model itself is
/// iOS 18-safe.
@MainActor
final class DescribeChoresModel: ObservableObject {
    enum Phase: Equatable {
        case compose, reading, review, nothingFound
        case failed(RoomVisionError)
    }

    /// The household facts the mapping needs, snapshotted when reading starts.
    struct Household {
        var areas: [(id: UUID, name: String)] = []
        var weekdayLoad: [Weekday: Int] = [:]
        var isPlus = false
        /// Names of the chores already in a room; for `.none`, every chore's name.
        var existingNames: (AreaRef) -> [String] = { _ in [] }

        /// From the active scope's areas and chores.
        @MainActor static func make(areas: [CDArea], chores: [CDChore], household: CDHousehold?) -> Household {
            let allNames = chores.compactMap(\.name)
            return Household(
                areas: areas.compactMap { area in area.id.map { (id: $0, name: area.name ?? "") } },
                weekdayLoad: RoomVisionMapping.weekdayLoad(of: chores),
                isPlus: Entitlements.isPlus(for: household),
                existingNames: { ref in
                    ref == .none ? allNames : RoomVisionMapping.existingChoreNames(in: ref, chores: chores)
                })
        }
    }

    @Published var text = ""
    @Published private(set) var phase: Phase = .compose
    @Published private(set) var live: [DescribedChore] = []
    @Published private(set) var drafts: [ChoreDraft] = []
    @Published private(set) var plusNotes: [ChoreDraft.ID: String] = [:]
    @Published private(set) var selected: Set<ChoreDraft.ID> = []
    @Published private(set) var duplicateIDs: Set<ChoreDraft.ID> = []

    private var household = Household()
    private var task: Task<Void, Never>?

    var canRead: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The kept chores, in the order they were described.
    var chosenDrafts: [ChoreDraft] {
        drafts.filter { selected.contains($0.id) && !duplicateIDs.contains($0.id) }
    }

    var chosenCount: Int { chosenDrafts.count }

    func read(household: Household) {
        guard canRead else { return }
        self.household = household
        task?.cancel()
        live = []
        phase = .reading
        guard #available(iOS 27.0, macOS 27.0, *) else {
            phase = .failed(.unavailable)
            return
        }
        let text = self.text
        let rooms = household.areas.map(\.name)
        let started = Date()
        task = Task { [weak self] in
            do {
                for try await snapshot in DescribeChoresEngine.streamChores(from: text, rooms: rooms) {
                    guard let self else { return }
                    if snapshot.count != self.live.count {
                        withAnimation(.snappy) { self.live = snapshot }
                    } else {
                        self.live = snapshot
                    }
                }
                guard let self, !Task.isCancelled else { return }
                Log.info("Describe Chores: \(self.live.count) chore(s) from \(text.count) characters in "
                         + String(format: "%.1f s", Date().timeIntervalSince(started)))
                self.finish()
            } catch is CancellationError {
                return
            } catch {
                Log.error("Describe Chores failed: \(error)")
                self?.phase = .failed(error as? RoomVisionError ?? .failed)
            }
        }
    }

    private func finish() {
        let result = DescribeChoresMapping.drafts(from: live, areas: household.areas,
                                                  weekdayLoad: household.weekdayLoad, isPlus: household.isPlus)
        guard !result.drafts.isEmpty else {
            phase = .nothingFound
            return
        }
        drafts = result.drafts
        plusNotes = result.plusNotes
        duplicateIDs = DescribeChoresMapping.duplicates(in: drafts, existingNames: household.existingNames)
        selected = Set(drafts.map(\.id)).subtracting(duplicateIDs)
        phase = .review
    }

    /// A draft's room for its summary line: "Kitchen", "Garage (new room)", or nil.
    func roomLabel(for ref: AreaRef) -> String? {
        switch ref {
        case .none:             return nil
        case .existing(let id): return household.areas.first { $0.id == id }?.name
        case .new(let name):    return "\(name) (new room)"
        }
    }

    /// The row's second line: schedule and room, or why it's left out.
    func detail(for draft: ChoreDraft) -> String {
        if duplicateIDs.contains(draft.id) { return "You already have this chore" }
        return [draft.scheduleSummary, roomLabel(for: draft.areaRef)].compactMap { $0 }.joined(separator: " · ")
    }

    func toggle(_ id: ChoreDraft.ID) {
        guard !duplicateIDs.contains(id) else { return }
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    /// Applies an edit from a draft editor (same id, same position). An edited schedule
    /// is the user's own, so its Plus note goes.
    func update(_ draft: ChoreDraft) {
        guard let index = drafts.firstIndex(where: { $0.id == draft.id }) else { return }
        if drafts[index].isDaily != draft.isDaily || drafts[index].frequency != draft.frequency
            || drafts[index].day != draft.day {
            plusNotes[draft.id] = nil
        }
        drafts[index] = draft
        let previous = duplicateIDs
        duplicateIDs = DescribeChoresMapping.duplicates(in: drafts, existingNames: household.existingNames)
        selected.subtract(duplicateIDs)
        selected.formUnion(previous.subtracting(duplicateIDs))
    }

    /// Back to the text, kept as written.
    func edit() {
        task?.cancel()
        live = []
        drafts = []
        plusNotes = [:]
        selected = []
        duplicateIDs = []
        phase = .compose
    }

    func cancel() { task?.cancel() }
}

#if DEBUG
extension DescribeChoresModel {
    /// UI tests and snapshots: text handed in through the environment
    /// (`CHOREGANIZE_DESCRIBE_TEXT`), read as soon as the flow opens.
    static var testTextFromEnvironment: String? {
        guard let text = ProcessInfo.processInfo.environment["CHOREGANIZE_DESCRIBE_TEXT"], !text.isEmpty else { return nil }
        return text
    }
}
#endif
