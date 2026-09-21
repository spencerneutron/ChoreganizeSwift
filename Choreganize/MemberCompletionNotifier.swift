import CoreData
import UserNotifications

/// CG-14 / #62 — FLAGSHIP (Plus): notify this user when *another* household
/// member completes a chore.
///
/// Architecture note: participants read the household via CloudKit's shared
/// database, which only supports silent database subscriptions — a visible
/// CKQuerySubscription push isn't available there. So the pipeline rides the
/// existing NSPersistentCloudKitContainer machinery: the silent push wakes the
/// app, mirroring imports the new records, and we turn just-imported
/// completions by other members into *local* notifications. No new CloudKit
/// subscriptions, no schema change.
///
/// Detection is persistent-history based: on every remote-change notification
/// we read history transactions since the last seen token, consider only
/// mirroring-import transactions (author-filtered — our own writes are
/// authored "app"), and collect inserted `CDCompletion` rows. The history
/// token always advances — even while the feature is gated off — so buying
/// Plus later doesn't replay a backlog, and the first run baselines without
/// notifying about pre-existing history.
@MainActor
final class MemberCompletionNotifier {
    static let shared = MemberCompletionNotifier()

    enum Keys {
        /// User toggle (Notification settings ▸ Household Activity). Default on;
        /// the Plus gate does the real gating.
        static let enabled = "notif.memberCompletions"
        static let historyToken = "notif.memberCompletions.token"
    }

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Keys.enabled) as? Bool ?? true
    }

    private var remoteChangeObserver: NSObjectProtocol?
    private var processing = false
    private var pendingRerun = false

    /// Begins watching for imported completions. No-op without CloudKit
    /// (no sharing → no other members).
    func start(stack: CoreDataStack = .shared) {
        guard stack.cloudKitEnabled, remoteChangeObserver == nil else { return }
        // Remote-change posts on background queues; hop, don't block the poster.
        remoteChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.processNewHistory(stack: stack) }
        }
        // Catch up on anything imported while we weren't observing.
        processNewHistory(stack: stack)
    }

    // MARK: - History processing

    private func processNewHistory(stack: CoreDataStack) {
        guard !processing else { pendingRerun = true; return }
        processing = true

        let container = stack.container
        let ctx = stack.newBackgroundContext()
        Task {
            let insertedIDs: [NSManagedObjectID] = await withCheckedContinuation { cont in
                ctx.perform {
                    cont.resume(returning: Self.drainHistory(container: container, in: ctx))
                }
            }
            deliverNotifications(for: insertedIDs, stack: stack)
            processing = false
            if pendingRerun {
                pendingRerun = false
                processNewHistory(stack: stack)
            }
        }
    }

    /// Reads history after the stored token, advances the token, and returns
    /// object IDs of completions inserted by CloudKit mirroring imports.
    /// First run (no stored token) just baselines: record where history ends
    /// now, notify about nothing that came before.
    private static func drainHistory(container: NSPersistentCloudKitContainer,
                                     in ctx: NSManagedObjectContext) -> [NSManagedObjectID] {
        let coordinator = container.persistentStoreCoordinator
        guard let stored = storedToken() else {
            if tokenDefaults.data(forKey: Keys.historyToken) != nil {
                Log.warning("Member-completion history token failed to decode; re-baselining", category: .push)
            }
            if let current = coordinator.currentPersistentHistoryToken(fromStores: nil) {
                storeToken(current)
                Log.info("Member-completion history baselined", category: .push)
            }
            return []
        }

        let request = NSPersistentHistoryChangeRequest.fetchHistory(after: stored)
        request.resultType = .transactionsAndChanges
        let transactions: [NSPersistentHistoryTransaction]
        do {
            guard let result = try ctx.execute(request) as? NSPersistentHistoryResult,
                  let list = result.result as? [NSPersistentHistoryTransaction] else {
                Log.warning("Member-completion history fetch returned no result", category: .push)
                return []
            }
            transactions = list
        } catch {
            // A token the store no longer recognises (expired, or minted against
            // a store set that has since been recreated — seen on the Mac at the
            // sim gate) would fail on every remote change forever, because the
            // token only advances on success. Re-baseline to now: the backlog
            // is dropped, but the feature works again from the next import.
            Log.error("Member-completion history fetch failed (\(error.localizedDescription)); re-baselining", category: .push)
            if let current = coordinator.currentPersistentHistoryToken(fromStores: nil) {
                storeToken(current)
            }
            return []
        }
        if let newest = transactions.last?.token { storeToken(newest) }

        var inserted: [NSManagedObjectID] = []
        var mirrored = 0
        for transaction in transactions {
            // Only CloudKit mirroring imports — a completion that arrived from
            // another device. Everything this process writes is authored "app".
            guard transaction.author?.contains("Mirroring") == true else { continue }
            mirrored += 1
            for change in transaction.changes ?? [] where change.changeType == .insert
                && change.changedObjectID.entity.name == "CDCompletion" {
                inserted.append(change.changedObjectID)
            }
        }
        if !transactions.isEmpty {
            Log.info("Member-completion history drain: \(transactions.count) transaction(s), \(mirrored) mirrored, \(inserted.count) completion insert(s)", category: .push)
        }
        return inserted
    }

    // MARK: - Delivery

    private func deliverNotifications(for objectIDs: [NSManagedObjectID], stack: CoreDataStack) {
        guard !objectIDs.isEmpty else { return }
        let ctx = stack.viewContext
        for objectID in objectIDs {
            guard let completion = try? ctx.existingObject(with: objectID) as? CDCompletion else { continue }
            let event = MemberCompletionPolicy.Event(
                completedBy: completion.completedBy,
                date: completion.date,
                isHousehold: completion.household != nil
            )
            let verdict = MemberCompletionPolicy.evaluate(
                event: event,
                currentUserID: CompleterIdentity.cachedID,
                // CG-15 / #97: household-scoped — one member's Plus lights up
                // member notifications for everyone in the household.
                isPlus: Entitlements.isPlus(for: completion.household),
                isEnabled: Self.isEnabled
            )
            guard verdict == .notify else {
                Log.info("Member-completion skipped (\(verdict)): \(completion.chore?.name ?? "chore")", category: .push)
                continue
            }

            // Directory hides self and falls back to "A household member".
            guard let completerName = CompleterDirectory.shared.name(for: completion.completedBy) else {
                Log.info("Member-completion skipped (no completer name): \(completion.chore?.name ?? "chore")", category: .push)
                continue
            }
            let content = UNMutableNotificationContent()
            content.title = completion.household?.name ?? "Household"
            content.body = MemberCompletionPolicy.body(choreName: completion.chore?.name,
                                                       completerName: completerName)
            content.sound = .default
            content.threadIdentifier = "member-completions"
            let identifier = "member-completion-\(completion.id?.uuidString ?? UUID().uuidString)"
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
            Log.info("Member-completion notification scheduled", category: .push)
        }
    }

    // MARK: - Token persistence

    private static var tokenDefaults: UserDefaults {
        UserDefaults(suiteName: WidgetShared.appGroupIdentifier) ?? .standard
    }

    private static func storedToken() -> NSPersistentHistoryToken? {
        guard let data = tokenDefaults.data(forKey: Keys.historyToken) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSPersistentHistoryToken.self, from: data)
    }

    private static func storeToken(_ token: NSPersistentHistoryToken) {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) else { return }
        tokenDefaults.set(data, forKey: Keys.historyToken)
    }
}

/// The pure notify-or-not decision and message formatting, testable without
/// Core Data or StoreKit.
enum MemberCompletionPolicy {
    struct Event {
        let completedBy: String?
        let date: Date?
        let isHousehold: Bool
    }

    /// Don't announce stale completions (a device off overnight shouldn't
    /// bulldoze the user with yesterday's checkmarks when it syncs).
    static let recencyWindow: TimeInterval = 8 * 60 * 60
    /// Small allowance for cross-device clock skew on "future" dates.
    static let futureTolerance: TimeInterval = 5 * 60

    /// Why a completion did or didn't notify — logged at the release gate so a
    /// silent skip is diagnosable from the device log.
    enum Verdict: Equatable {
        case notify, gated, notHousehold, unattributed, ownCompletion, undated, stale, future
    }

    static func shouldNotify(event: Event,
                             currentUserID: String?,
                             isPlus: Bool,
                             isEnabled: Bool,
                             now: Date = Date(),
                             calendar: Calendar = .current) -> Bool {
        evaluate(event: event, currentUserID: currentUserID, isPlus: isPlus,
                 isEnabled: isEnabled, now: now, calendar: calendar) == .notify
    }

    static func evaluate(event: Event,
                         currentUserID: String?,
                         isPlus: Bool,
                         isEnabled: Bool,
                         now: Date = Date(),
                         calendar: Calendar = .current) -> Verdict {
        guard isPlus, isEnabled else { return .gated }
        guard event.isHousehold else { return .notHousehold }
        guard let completedBy = event.completedBy else { return .unattributed }
        // Our own completions never notify. (An unknown local identity can't
        // match, which is correct: everything *we* stamp carries our cached id,
        // so a stamped import while we're id-less is someone else's.)
        if let currentUserID, completedBy == currentUserID { return .ownCompletion }
        guard let date = event.date else { return .undated }
        // Completion dates are day-granular: the Work view records against the
        // day being viewed, so they land on local midnight. A wall-clock window
        // measured from midnight calls anything done after 8 AM "stale" —
        // found at the 2-sim gate, where a 20:55 completion never notified. A
        // completion is recent when it belongs to today, or when a real
        // timestamp (backups and imports can carry one) falls inside the window.
        let isToday = calendar.isDate(date, inSameDayAs: now)
        let withinWindow = now.timeIntervalSince(date) <= recencyWindow
        guard isToday || withinWindow else { return .stale }
        guard date.timeIntervalSince(now) <= futureTolerance else { return .future }
        return .notify
    }

    static func body(choreName: String?, completerName: String) -> String {
        "\(completerName) completed \(choreName ?? "a chore")."
    }
}
