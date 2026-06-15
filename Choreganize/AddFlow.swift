import Combine
import CoreData

// P0 scaffolding for the Edit-tab "add chores & areas" guided wizard. This file is
// the engine only — no UI yet (P1). Both modalities (room-by-room, day-by-day) are
// one engine over a shared `ChoreDraft` atom, switched by `AddFlowGrouping`.

/// How the add-flow groups chores while the user builds them up: the "swappable
/// grouping key" both modalities share. `.byArea` is room-by-room (area fixed per
/// group); `.byDay` is weekday-first (day fixed per group).
enum AddFlowGrouping: String, CaseIterable, Identifiable {
    case byArea
    case byDay

    var id: String { rawValue }

    var title: String {
        switch self {
        case .byArea: return "Room by Room"
        case .byDay:  return "Day by Day"
        }
    }

    var systemImage: String {
        switch self {
        case .byArea: return "house.fill"
        case .byDay:  return "calendar"
        }
    }
}

/// A reference to the area a draft chore belongs to. The area may not exist yet (the
/// user can name a new room mid-flow), so resolution is deferred to commit time.
enum AreaRef: Equatable {
    case none
    case existing(UUID)   // CDArea.id of an area already in the store
    case new(String)      // a room named in-flow; created once (deduped) on commit
}

/// An in-flight chore before it is written to Core Data. Mirrors the parameters of
/// `CDChore.make` so commit is a direct translation, not a transformation.
struct ChoreDraft: Identifiable, Equatable {
    let id: UUID
    var name: String
    var isDaily: Bool
    var frequency: Frequency
    var day: Weekday?
    var areaRef: AreaRef

    init(id: UUID = UUID(),
         name: String = "",
         isDaily: Bool = false,
         frequency: Frequency = .weekly,
         day: Weekday? = nil,
         areaRef: AreaRef = .none) {
        self.id = id
        self.name = name
        self.isDaily = isDaily
        self.frequency = frequency
        self.day = day
        self.areaRef = areaRef
    }
}

/// The pure commit engine shared by both modalities — translates drafts into
/// `CDChore`/`CDArea` via the existing factories. Modelled on `BulkChoreOps`: plain
/// static funcs over a context, no UI/MainActor dependency, so it is unit-testable.
enum AddFlowCommit {
    /// Writes `drafts` into `ctx` under `household`. New areas referenced by name are
    /// created once and reused (deduped case-insensitively); a name matching an
    /// existing in-scope area reuses that area instead of creating a duplicate.
    /// Mirrors `NewChoreView`'s save semantics (daily ⇒ `Weekday.all`, no frequency).
    /// Returns the created chores. Saves once.
    @discardableResult
    static func commit(_ drafts: [ChoreDraft],
                       in ctx: NSManagedObjectContext,
                       household: CDHousehold?) -> [CDChore] {
        guard !drafts.isEmpty else { return [] }

        // Existing areas in this scope, indexed for reuse (by id and by name key).
        let existing = ((try? ctx.fetch(NSFetchRequest<CDArea>(entityName: "CDArea"))) ?? [])
            .inScope(household)
        var byId: [UUID: CDArea] = [:]
        var byName: [String: CDArea] = [:]
        for area in existing {
            if let id = area.id { byId[id] = area }
            if let key = areaKey(area.name) { byName[key] = area }
        }

        func resolve(_ ref: AreaRef) -> CDArea? {
            switch ref {
            case .none:
                return nil
            case .existing(let id):
                return byId[id]
            case .new(let rawName):
                guard let key = areaKey(rawName) else { return nil }
                if let found = byName[key] { return found }
                let created = CDArea.make(in: ctx,
                                          name: rawName.trimmingCharacters(in: .whitespacesAndNewlines),
                                          household: household)
                byName[key] = created
                if let id = created.id { byId[id] = created }
                return created
            }
        }

        var made: [CDChore] = []
        for draft in drafts {
            let assigned = draft.isDaily ? Weekday.all : draft.day
            let chore = CDChore.make(in: ctx,
                                     name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
                                     isDaily: draft.isDaily,
                                     frequency: draft.isDaily ? nil : draft.frequency,
                                     assignedDay: assigned,
                                     household: household)
            chore.area = resolve(draft.areaRef)
            made.append(chore)
        }
        try? ctx.save()
        return made
    }

    /// Case-insensitive, whitespace-trimmed key for area-name dedup; nil when empty.
    private static func areaKey(_ name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed.lowercased()
    }
}

/// UI-facing state for the guided add-flow wizard (P1 builds the screens on this).
/// Holds the running list of drafts and the active grouping key, and delegates the
/// Core Data write to `AddFlowCommit`.
@MainActor
final class AddFlowModel: ObservableObject {
    @Published var grouping: AddFlowGrouping
    @Published private(set) var drafts: [ChoreDraft] = []

    init(grouping: AddFlowGrouping) {
        self.grouping = grouping
    }

    /// Count of staged drafts — feeds the contained "growing" progress indicator (P1).
    var draftCount: Int { drafts.count }

    func add(_ draft: ChoreDraft) { drafts.append(draft) }

    func remove(_ id: ChoreDraft.ID) { drafts.removeAll { $0.id == id } }

    /// Commits the staged drafts and clears them. Returns the created chores.
    @discardableResult
    func commit(in ctx: NSManagedObjectContext, household: CDHousehold?) -> [CDChore] {
        let made = AddFlowCommit.commit(drafts, in: ctx, household: household)
        drafts.removeAll()
        return made
    }
}
