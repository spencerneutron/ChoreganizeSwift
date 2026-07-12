import Foundation
import CoreData
import UserNotifications

/// Schedules local "unfinished chores" reminders.
///
/// Local notifications carry **static** content fixed at schedule time — we
/// can't run code at fire time to check whether chores are still unresolved.
/// So instead of one repeating reminder, we schedule concrete dated reminders
/// only for upcoming enabled weekdays where chores are predicted to still need
/// attention, and we re-evaluate from scratch whenever the app backgrounds or
/// launches (see `ChoreganizeApp`). That keeps "only when there are unresolved
/// chores" accurate for today and self-correcting going forward.
///
/// Preferences are per-device (UserDefaults); the chore set is whatever the
/// active scope currently shows.
@MainActor
enum NotificationManager {

    // MARK: - Preferences (per-device)

    enum Keys {
        static let enabled = "notif.enabled"
        static let days = "notif.days"      // [String] of Weekday rawValues
        static let hour = "notif.hour"
        static let minute = "notif.minute"
        static let badgeScopes = "badge.scopes"  // [String] of AppScope rawValues; unset == both
    }

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Keys.enabled)
    }

    /// Enabled weekdays; defaults to all seven when unset.
    static var days: Set<Weekday> {
        get {
            guard let raw = UserDefaults.standard.array(forKey: Keys.days) as? [String] else {
                return Set(Weekday.standardCases)
            }
            return Set(raw.compactMap(Weekday.init(rawValue:)))
        }
        set {
            UserDefaults.standard.set(newValue.map(\.rawValue), forKey: Keys.days)
        }
    }

    /// Hour of day to remind (24h). Defaults to 18:00.
    static var hour: Int { UserDefaults.standard.object(forKey: Keys.hour) as? Int ?? 18 }
    static var minute: Int { UserDefaults.standard.object(forKey: Keys.minute) as? Int ?? 0 }

    /// Scopes whose unfinished chores feed the app-icon badge. *Unset* defaults to
    /// both; an explicit empty set means "no badge". (Distinguishing unset from empty
    /// is why this reads the raw array directly rather than going through a default.)
    static var badgeScopes: Set<AppScope> {
        get {
            guard let raw = UserDefaults.standard.array(forKey: Keys.badgeScopes) as? [String] else {
                return Set(AppScope.allCases)
            }
            return Set(raw.compactMap(AppScope.init(rawValue:)))
        }
        set { UserDefaults.standard.set(newValue.map(\.rawValue), forKey: Keys.badgeScopes) }
    }

    // MARK: - Authorization

    @discardableResult
    static func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            Log.error("Notification auth request failed: \(error.localizedDescription)", category: .app)
            return false
        }
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    // MARK: - Actionable notifications

    /// Category + action identifiers for the "Mark done" reminder action. The
    /// category must be registered with the notification center before any
    /// reminder carrying it is delivered (see `registerCategories`).
    enum Action {
        static let category = "CHORE_REMINDER"
        static let markDone = "MARK_DONE"
        static let choreIDsKey = "choreIDs"   // userInfo: [String] of CDChore.id UUIDs
    }

    /// Registers the reminder category so delivered reminders show a "Mark done"
    /// action. Called once at launch from the app delegate, before any reminder
    /// fires. The action runs in the background (no foreground bring-up), so it
    /// completes the chore without opening the app.
    static func registerCategories() {
        let markDone = UNNotificationAction(
            identifier: Action.markDone,
            title: "Mark done",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: Action.category,
            actions: [markDone],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    /// Handles the "Mark done" action: re-resolves the chores carried in the
    /// reminder's `userInfo` against the live store *now* (their state may have
    /// changed since schedule time) and records a completion for any still open
    /// today. Reuses the same id-based resolution + `recordCompletion` path as
    /// `CompleteChoreIntent`, so completion logic isn't duplicated.
    @discardableResult
    static func completeChores(fromUserInfo userInfo: [AnyHashable: Any]) -> Int {
        guard let raw = userInfo[Action.choreIDsKey] as? [String] else { return 0 }
        let ids = raw.compactMap(UUID.init(uuidString:))
        guard !ids.isEmpty else { return 0 }

        let context = CoreDataStack.shared.viewContext
        let request = NSFetchRequest<CDChore>(entityName: "CDChore")
        request.predicate = NSPredicate(format: "id IN %@", ids)
        let chores = (try? context.fetch(request)) ?? []

        var completed = 0
        let today = Date()
        for chore in chores where !chore.isCompleted(on: today) {
            chore.recordCompletion(on: today, in: context)
            completed += 1
        }
        Log.info("Reminder 'Mark done' completed \(completed) chore(s)", category: .app)
        return completed
    }

    // MARK: - Scheduling

    private static let reminderPrefix = "chore-reminder-"

    /// Clears all chore reminders and re-schedules upcoming ones from the current
    /// store + prefs. Safe (and intended) to call often — on background, on
    /// launch, and whenever prefs change.
    static func reschedule(using context: NSManagedObjectContext, activeHousehold: CDHousehold?) async {
        let center = UNUserNotificationCenter.current()

        // Always clear our previously-scheduled reminders first.
        let pending = await center.pendingNotificationRequests()
        let staleIDs = pending.map(\.identifier).filter { $0.hasPrefix(reminderPrefix) }
        if !staleIDs.isEmpty { center.removePendingNotificationRequests(withIdentifiers: staleIDs) }

        guard isEnabled else { return }
        let status = await authorizationStatus()
        guard status == .authorized || status == .provisional else { return }

        let enabledDays = days
        guard !enabledDays.isEmpty else { return }

        let cal = Calendar.current
        let request = NSFetchRequest<CDChore>(entityName: "CDChore")
        let chores = ((try? context.fetch(request)) ?? []).inScope(activeHousehold)

        // CG-19 / #101: per-chore/per-area custom times are Plus-gated. The gate
        // mirrors the settings UI's `effectivePlus` — own entitlement OR the
        // household-propagated flag (CG-15 / #97) — checking every household
        // rather than just `activeHousehold` (nil while viewing Solo), so a
        // household member's Plus keeps custom times working from either scope.
        let households = ((try? context.fetch(NSFetchRequest<CDHousehold>(entityName: "CDHousehold"))) ?? [])
        let overridesEnabled = Entitlements.isPlus || households.contains { $0.plusEnabled }

        let planned = plannedGroupedReminders(chores: chores, days: enabledDays,
                                              globalHour: hour, globalMinute: minute,
                                              overridesEnabled: overridesEnabled,
                                              from: Date(), calendar: cal)
        // Resolve names once for single-chore reminders so the body can name the
        // chore the "Mark done" action will complete.
        let nameByID = Dictionary(uniqueKeysWithValues: chores.compactMap { chore -> (UUID, String)? in
            guard let id = chore.id else { return nil }
            return (id, chore.name ?? "a chore")
        })

        for reminder in planned {
            let content = UNMutableNotificationContent()
            content.title = "Chores to finish"
            if reminder.unresolvedCount == 1, let id = reminder.choreIDs.first, let name = nameByID[id] {
                content.body = "“\(name)” still needs attention."
            } else {
                content.body = "\(reminder.unresolvedCount) chores still need attention."
            }
            content.sound = .default
            // Make the reminder actionable: "Mark done" resolves these ids live and
            // completes any still open today (see `completeChores`). The category is
            // registered at launch in the app delegate.
            content.categoryIdentifier = Action.category
            content.userInfo[Action.choreIDsKey] = reminder.choreIDs.map(\.uuidString)

            let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: reminder.fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            // CG-19 / #101: the id carries the time so grouped reminders can share
            // a day without colliding; prefix-based clearing above still matches.
            let id = "\(reminderPrefix)\(comps.year ?? 0)-\(comps.month ?? 0)-\(comps.day ?? 0)-\(comps.hour ?? 0):\(comps.minute ?? 0)"
            do {
                try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            } catch {
                Log.error("Failed to schedule reminder \(id): \(error.localizedDescription)", category: .app)
            }
        }
        Log.info("Scheduled \(planned.count) chore reminder(s)", category: .app)
    }

    // MARK: - Badge (decoupled from reminders)

    /// Recomputes and applies the app-icon badge: today's unfinished chores summed
    /// across the user's selected scopes. Silently no-ops without badge authorization,
    /// so it never prompts when called on foreground/background.
    static func refreshBadge(using context: NSManagedObjectContext, household: CDHousehold?) async {
        let count = badgeCount(using: context, household: household)
        try? await UNUserNotificationCenter.current().setBadgeCount(count)
        let scopeLabel = badgeScopes.isEmpty ? "none" : badgeScopes.map(\.rawValue).sorted().joined(separator: "+")
        Log.info("Badge refresh → \(count) unfinished today (scopes: \(scopeLabel))", category: .app)
    }

    /// Today's badge count from the live store + current prefs. Fetches once and
    /// defers the decision to the pure core below.
    static func badgeCount(using context: NSManagedObjectContext, household: CDHousehold?) -> Int {
        let all = ((try? context.fetch(NSFetchRequest<CDChore>(entityName: "CDChore"))) ?? [])
        return badgeCount(in: all, household: household, scopes: badgeScopes, from: Date())
    }

    /// Pure core: today's unfinished-chore count over the selected scopes, partitioning
    /// `chores` by household itself. Counts each scope independent of the *active* scope
    /// (Solo == no household; Household uses the resolved household even when the user is
    /// viewing Solo). Strictly today (`from`), so a locked, uncloseable past-day miss can
    /// never keep the badge lit. `nonisolated` + deterministic, so it unit-tests without
    /// touching UserDefaults or the notification center.
    nonisolated static func badgeCount(
        in chores: [CDChore],
        household: CDHousehold?,
        scopes: Set<AppScope>,
        from now: Date
    ) -> Int {
        guard !scopes.isEmpty else { return 0 }
        var total = 0
        if scopes.contains(.solo) {
            total += unresolvedCount(in: chores.inScope(nil), on: now)
        }
        if scopes.contains(.household), let household {
            total += unresolvedCount(in: chores.inScope(household), on: now)
        }
        return total
    }

    /// Removes already-delivered chore reminders from Notification Center (called on
    /// foreground). Mirrors the `reminderPrefix` filtering used for pending requests.
    static func clearDeliveredReminders() async {
        let center = UNUserNotificationCenter.current()
        let ids = (await center.deliveredNotifications())
            .map(\.request.identifier)
            .filter { $0.hasPrefix(reminderPrefix) }
        if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
    }

    // MARK: - Planning (pure, testable)

    /// One reminder we intend to schedule: when it fires, how many chores were
    /// unresolved at planning time (drives the body text), and the stable ids of
    /// those chores (carried in `userInfo` so the "Mark done" action can resolve
    /// and complete them at fire time). `unresolvedCount` stays redundant with
    /// `choreIDs.count` so the existing planning tests/body logic are unchanged.
    struct PlannedReminder: Equatable {
        let fireDate: Date
        let unresolvedCount: Int
        var choreIDs: [UUID] = []
    }

    /// The core scheduling decision — only on enabled weekdays, only when chores
    /// are unresolved, skip today if its time has already passed, capped at
    /// `maxOccurrences`. Pure (no notification-center or store side effects) so it
    /// can be unit-tested with a fixed `now`.
    nonisolated static func plannedReminders(
        chores: [CDChore],
        days: Set<Weekday>,
        hour: Int,
        minute: Int,
        from now: Date,
        calendar: Calendar = .current,
        maxOccurrences: Int = 7,
        lookaheadDays: Int = 21
    ) -> [PlannedReminder] {
        guard !days.isEmpty, !chores.isEmpty else { return [] }
        var result: [PlannedReminder] = []
        for offset in 0...lookaheadDays where result.count < maxOccurrences {
            guard let day = calendar.date(byAdding: .day, value: offset, to: now) else { continue }
            guard days.contains(weekday(for: day, cal: calendar)) else { continue }
            guard let fireDate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
                  fireDate > now else { continue }   // skip today's slot if already passed
            let unresolved = unresolvedChores(in: chores, on: day)
            guard !unresolved.isEmpty else { continue }
            result.append(PlannedReminder(fireDate: fireDate,
                                          unresolvedCount: unresolved.count,
                                          choreIDs: unresolved.compactMap(\.id)))
        }
        return result
    }

    /// CG-19 / #101: planning with per-chore/per-area time overrides (Plus).
    ///
    /// Chores are partitioned by their *effective* reminder time — the chore's
    /// own override, else its area's, else the global hour/minute (see
    /// `ReminderTimeOverride`) — and each partition runs through the same pure
    /// core above, so every group keeps the enabled-weekday, "only when chores
    /// are predicted unresolved", and skip-passed-slot rules. A chore whose
    /// override equals the global time merges back into the global group: one
    /// notification, not two. `maxOccurrences` caps each group independently
    /// (iOS itself keeps only the ~64 soonest pending requests, which a
    /// handful of distinct times can't realistically exceed).
    ///
    /// `overridesEnabled` is the Plus gate: when false, overrides are ignored
    /// and this is exactly the single-time `plannedReminders` plan — so a
    /// lapsed entitlement quietly folds everything back into the global
    /// reminder without touching the stored override strings.
    nonisolated static func plannedGroupedReminders(
        chores: [CDChore],
        days: Set<Weekday>,
        globalHour: Int,
        globalMinute: Int,
        overridesEnabled: Bool,
        from now: Date,
        calendar: Calendar = .current,
        maxOccurrences: Int = 7,
        lookaheadDays: Int = 21
    ) -> [PlannedReminder] {
        guard overridesEnabled else {
            return plannedReminders(chores: chores, days: days, hour: globalHour, minute: globalMinute,
                                    from: now, calendar: calendar,
                                    maxOccurrences: maxOccurrences, lookaheadDays: lookaheadDays)
        }
        // Key by minutes-since-midnight so identical times collapse to one group.
        let groups = Dictionary(grouping: chores) { chore -> Int in
            let time = ReminderTimeOverride.effectiveOverride(chore: chore)
            return (time?.hour ?? globalHour) * 60 + (time?.minute ?? globalMinute)
        }
        return groups
            .flatMap { minutes, group in
                plannedReminders(chores: group, days: days, hour: minutes / 60, minute: minutes % 60,
                                 from: now, calendar: calendar,
                                 maxOccurrences: maxOccurrences, lookaheadDays: lookaheadDays)
            }
            .sorted { $0.fireDate < $1.fireDate }
    }

    // MARK: - Helpers

    /// Chores still needing attention on `date` (the live unfinished set today;
    /// a prediction for future dates, where no completions exist yet).
    nonisolated static func unresolvedChores(in chores: [CDChore], on date: Date) -> [CDChore] {
        Scheduling.chores(chores, for: date)
            .filter { $0.needsAttention(on: date) && !$0.isCompleted(on: date) }
    }

    nonisolated static func unresolvedCount(in chores: [CDChore], on date: Date) -> Int {
        unresolvedChores(in: chores, on: date).count
    }

    nonisolated static func weekday(for date: Date, cal: Calendar) -> Weekday {
        let index = cal.component(.weekday, from: date) - 1
        return Weekday.standardCases[index]
    }
}
