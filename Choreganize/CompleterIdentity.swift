import CloudKit
import CoreData
import Foundation

/// Who completed a chore (#59).
///
/// Identity = the user's **stable CloudKit user-record name** (decided 2026-06-19:
/// authoritative share-participant identity, not the per-device display-name
/// string). It's fetched once per launch and cached in the App Group defaults so
/// the widget's CompleteChoreIntent process stamps the same id as the app.
/// Completions are stamped only for Household chores — Solo has no attribution.
enum CompleterIdentity {
    private static let cacheKey = "completerIdentity.userRecordName"

    /// App Group defaults, shared with the widget extension; falls back to
    /// standard for contexts without the group entitlement (unit tests).
    static var defaults: UserDefaults {
        UserDefaults(suiteName: WidgetShared.appGroupIdentifier) ?? .standard
    }

    /// Synchronous read for stamping. `nil` until the first successful fetch —
    /// early completions on a fresh install go unattributed, which the display
    /// layer treats the same as legacy rows.
    static var cachedID: String? {
        defaults.string(forKey: cacheKey)
    }

    /// Fetches and caches the stable user-record id. Cheap; called at app launch.
    /// No-ops when CloudKit is off (tests / local-only / previews).
    static func refresh(stack: CoreDataStack = .shared) {
        guard stack.cloudKitEnabled else { return }
        CKContainer(identifier: CoreDataStack.cloudContainerIdentifier).fetchUserRecordID { recordID, error in
            if let recordID {
                defaults.set(recordID.recordName, forKey: cacheKey)
                Log.info("Completer identity cached", category: .cloud)
            } else if let error {
                Log.warning("Completer identity fetch failed: \(error.localizedDescription)", category: .cloud)
            }
        }
    }
}

/// Pure id → display-name resolution (#59), testable without CloudKit.
enum CompleterNameResolver {
    /// One share participant, reduced to what display needs.
    struct Participant {
        let userRecordName: String?
        let nameComponents: PersonNameComponents?
    }

    /// CloudKit reports the *current user's own* share participant under the
    /// placeholder `CKCurrentUserDefaultName` ("__defaultOwner__") rather than
    /// the real user-record name. Everything else in the app (completion
    /// stamps, the assignment picker's self-filter) keys on the real name, so
    /// canonicalise the placeholder to it. Found at the 2-sim gate: the owner
    /// appeared twice in "Assigned to", and picking the placeholder wrote an id
    /// no other device can resolve.
    static func canonicalRecordName(_ recordName: String, currentUserID: String?) -> String {
        if recordName == CKCurrentUserDefaultName, let currentUserID { return currentUserID }
        return recordName
    }

    /// Resolves a completion's `completedBy` for display.
    /// - Returns: `nil` when the row should show no attribution (no id recorded,
    ///   or it's the current user's own completion — seeing "by You" on every row
    ///   you just checked is noise); otherwise a human-readable name.
    static func displayName(for completedBy: String?,
                            currentUserID: String?,
                            participants: [Participant]) -> String? {
        guard let completedBy else { return nil }
        if let currentUserID, completedBy == currentUserID { return nil }
        if let match = participants.first(where: { $0.userRecordName == completedBy }),
           let components = match.nameComponents {
            let formatted = PersonNameComponentsFormatter.localizedString(from: components, style: .short)
            if !formatted.isEmpty { return formatted }
        }
        return "A household member"
    }
}

/// Main-actor cache of participant names for the active household's share,
/// refreshed off the main thread (fetchShares blocks its calling thread — the
/// v1.6.1 lesson). Rows read `name(for:)` synchronously.
@MainActor
final class CompleterDirectory: ObservableObject {
    static let shared = CompleterDirectory()

    @Published private(set) var namesByID: [String: String] = [:]
    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: .householdShareDidChange, object: nil, queue: nil
        ) { _ in
            Task { @MainActor in CompleterDirectory.shared.refresh() }
        }
        refresh()
    }

    /// Display name for a completion's `completedBy`, or `nil` to hide the line.
    func name(for completedBy: String?) -> String? {
        guard let completedBy else { return nil }
        if completedBy == CompleterIdentity.cachedID { return nil }
        return namesByID[completedBy] ?? "A household member"
    }

    /// Rebuilds the id → name map from the active household's share participants.
    func refresh(stack: CoreDataStack = .shared) {
        guard stack.cloudKitEnabled else { return }
        Task.detached(priority: .utility) {
            // Find the household the app resolves for the Household scope
            // (CG-16 / #98: the explicit selection first, then shared-store,
            // then owned) and read its share's participants.
            let ctx = stack.newBackgroundContext()
            var householdID: NSManagedObjectID?
            ctx.performAndWait {
                if let raw = UserDefaults.standard.string(forKey: AppModel.activeHouseholdKey),
                   let id = UUID(uuidString: raw) {
                    let selected = NSFetchRequest<CDHousehold>(entityName: "CDHousehold")
                    selected.fetchLimit = 1
                    selected.predicate = NSPredicate(format: "id == %@", id as CVarArg)
                    if let h = try? ctx.fetch(selected).first { householdID = h.objectID }
                }
                let request = NSFetchRequest<CDHousehold>(entityName: "CDHousehold")
                request.fetchLimit = 1
                request.sortDescriptors = [NSSortDescriptor(key: "createdDate", ascending: true)]
                if householdID == nil, let shared = stack.sharedStore {
                    request.affectedStores = [shared]
                    if let h = try? ctx.fetch(request).first { householdID = h.objectID }
                }
                if householdID == nil, let priv = stack.privateStore {
                    request.affectedStores = [priv]
                    if let h = try? ctx.fetch(request).first { householdID = h.objectID }
                }
            }
            guard let householdID,
                  let share = (try? stack.container.fetchShares(matching: [householdID]))?[householdID] else { return }
            var names: [String: String] = [:]
            let me = CompleterIdentity.cachedID
            for participant in share.participants {
                guard let raw = participant.userIdentity.userRecordID?.recordName else { continue }
                let id = CompleterNameResolver.canonicalRecordName(raw, currentUserID: me)
                let resolved = CompleterNameResolver.displayName(
                    for: id,
                    currentUserID: nil,   // keep the raw name; self-hiding happens in name(for:)
                    participants: [.init(userRecordName: id,
                                         nameComponents: participant.userIdentity.nameComponents)]
                )
                if let resolved { names[id] = resolved }
            }
            let final = names
            await MainActor.run { CompleterDirectory.shared.namesByID = final }
        }
    }
}
