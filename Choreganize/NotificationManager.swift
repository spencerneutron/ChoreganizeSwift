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

        let planned = plannedReminders(chores: chores, days: enabledDays,
                                       hour: hour, minute: minute, from: Date(), calendar: cal)
        for reminder in planned {
            let content = UNMutableNotificationContent()
            content.title = "Chores to finish"
            content.body = reminder.unresolvedCount == 1
                ? "1 chore still needs attention."
                : "\(reminder.unresolvedCount) chores still need attention."
            content.sound = .default
            content.badge = NSNumber(value: reminder.unresolvedCount)

            let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: reminder.fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            let id = "\(reminderPrefix)\(comps.year ?? 0)-\(comps.month ?? 0)-\(comps.day ?? 0)"
            do {
                try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            } catch {
                Log.error("Failed to schedule reminder \(id): \(error.localizedDescription)", category: .app)
            }
        }
        Log.info("Scheduled \(planned.count) chore reminder(s)", category: .app)
    }

    // MARK: - Planning (pure, testable)

    /// One reminder we intend to schedule: when it fires and how many chores were
    /// unresolved at planning time (drives the body + badge).
    struct PlannedReminder: Equatable {
        let fireDate: Date
        let unresolvedCount: Int
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
            let count = unresolvedCount(in: chores, on: day)
            guard count > 0 else { continue }
            result.append(PlannedReminder(fireDate: fireDate, unresolvedCount: count))
        }
        return result
    }

    // MARK: - Helpers

    /// Chores still needing attention on `date` (the live unfinished set today;
    /// a prediction for future dates, where no completions exist yet).
    nonisolated static func unresolvedCount(in chores: [CDChore], on date: Date) -> Int {
        Scheduling.chores(chores, for: date)
            .filter { $0.needsAttention(on: date) && !$0.isCompleted(on: date) }
            .count
    }

    nonisolated static func weekday(for date: Date, cal: Calendar) -> Weekday {
        let index = cal.component(.weekday, from: date) - 1
        return Weekday.standardCases[index]
    }
}
