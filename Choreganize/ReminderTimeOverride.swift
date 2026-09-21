import CoreData
import Foundation

/// CG-19 / #101 — pure helpers for per-chore / per-area custom reminder times
/// (Plus).
///
/// Overrides live as "HH:mm" 24-hour strings on `CDChore.reminderTime` and
/// `CDArea.reminderTime` (`nil` = no override) — a String survives lightweight
/// migration and CloudKit sync without a schema redeploy. The fallback chain
/// is chore → its area → the global reminder time; only the first two live
/// here (`effectiveOverride` returns `nil` for "use the global time"), so the
/// helpers stay pure and the global hour/minute stays where it always was
/// (`NotificationManager` prefs).
///
/// No actor isolation: `NotificationManager`'s `nonisolated` planning core
/// calls these, so they must be callable off the main actor.
enum ReminderTimeOverride {

    /// Parses a stored "HH:mm" override. Strict on shape (exactly two `:`
    /// separated integer fields) and range (0–23 / 0–59) so a malformed synced
    /// value degrades to "no override" instead of scheduling at a bogus time.
    /// Lenient on zero-padding ("7:5" parses); `format` re-canonicalizes.
    static func parse(_ string: String?) -> (hour: Int, minute: Int)? {
        guard let string else { return nil }
        let parts = string.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return (hour, minute)
    }

    /// Canonical storage form: zero-padded "HH:mm".
    static func format(hour: Int, minute: Int) -> String {
        String(format: "%02d:%02d", hour, minute)
    }

    /// The chore's effective override: its own time beats its area's; `nil`
    /// means "no override — use the global reminder time". An unparseable
    /// chore string falls through to the area (then global) rather than
    /// silencing the chore's reminders.
    static func effectiveOverride(chore: CDChore) -> (hour: Int, minute: Int)? {
        parse(chore.reminderTime) ?? parse(chore.area?.reminderTime)
    }
}
