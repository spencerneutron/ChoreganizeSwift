#if os(iOS)
import BackgroundTasks
#endif
import CoreData
import Foundation

// MARK: - Policy (pure)

/// CG-20 / #102 — the pure planning half of automatic backups: cadence math,
/// filename encoding, and prune selection. No I/O, no clocks, no defaults —
/// everything takes its inputs explicitly so it's directly unit-testable.
enum AutoBackupPolicy {

    /// How often an automatic backup should be taken.
    enum Cadence: String, CaseIterable, Identifiable {
        case daily
        case weekly

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .daily: return "Daily"
            case .weekly: return "Weekly"
            }
        }

        /// Minimum time between backups. Interval-based (not calendar-day)
        /// so "due" doesn't flip at midnight right after a late-night backup.
        var minimumInterval: TimeInterval {
            switch self {
            case .daily: return 24 * 60 * 60
            case .weekly: return 7 * 24 * 60 * 60
            }
        }
    }

    /// Keep this many newest backup files; older ones are pruned.
    static let keepCount = 7

    static let filePrefix = "choreganize-backup-"
    static let fileSuffix = ".json"

    /// Whether a backup is due: never backed up, or the last one is at least
    /// a full cadence interval old (the boundary itself counts as due).
    static func isDue(last: Date?, cadence: Cadence, now: Date = Date()) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= cadence.minimumInterval
    }

    /// `choreganize-backup-YYYY-MM-DD.json` — zero-padded so lexicographic
    /// order equals chronological order (which `filesToPrune` relies on).
    static func filename(for date: Date) -> String {
        filePrefix + dayFormatter.string(from: date) + fileSuffix
    }

    /// Inverse of `filename(for:)`: the backup's calendar day (local start of
    /// day), or nil for names that aren't auto-backup files.
    static func date(fromFilename name: String) -> Date? {
        guard name.hasPrefix(filePrefix), name.hasSuffix(fileSuffix) else { return nil }
        return dayFormatter.date(from: String(name.dropFirst(filePrefix.count).dropLast(fileSuffix.count)))
    }

    /// Given directory entries, the auto-backup filenames to delete so only
    /// the newest `keep` remain. Names that don't match the backup pattern are
    /// never selected — pruning must not touch the user's other documents.
    static func filesToPrune(_ names: [String], keep: Int = keepCount) -> [String] {
        let backups = names
            .filter { $0.hasPrefix(filePrefix) && $0.hasSuffix(fileSuffix) }
            .sorted(by: >)   // newest first (dates are zero-padded)
        guard backups.count > keep else { return [] }
        return Array(backups.dropFirst(keep))
    }

    /// Fixed-format day stamp for filenames. POSIX locale so device locale /
    /// 12-hour settings can't change the format; local time zone so the day
    /// in the name matches the day the user saw the backup happen.
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

// MARK: - Manager (side effects)

/// CG-20 / #102 — automatic scheduled backups (Plus). Writes the same
/// Personal-scope JSON as the manual exporter (`BackupCodec`) into
/// `Documents/Backups/` on a daily/weekly cadence, keeping the newest
/// `AutoBackupPolicy.keepCount` files. Documents is exposed to the Files app
/// (`UIFileSharingEnabled`), so backups survive even if the app is deleted
/// after an iCloud device backup, and can be retrieved without the app.
///
/// Two triggers, one worker:
/// - a `BGProcessingTaskRequest` (best-effort; iOS may defer or skip it), and
/// - `runCatchUpIfDue()` on launch as the reliability backstop.
/// Both funnel through `AutoBackupPolicy.isDue`, so whichever fires first
/// takes the backup and the other becomes a no-op until the next interval.
enum AutoBackup {

    /// Must match `BGTaskSchedulerPermittedIdentifiers` in Info.plist.
    static let taskIdentifier = "com.svk.Choreganize.autobackup"

    enum Keys {
        static let enabled = "autoBackup.enabled"          // Bool, default false
        static let cadence = "autoBackup.cadence"          // Cadence.rawValue, default weekly
        static let lastBackupDate = "autoBackup.lastDate"  // Date
    }

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: Keys.enabled) }

    static var cadence: AutoBackupPolicy.Cadence {
        UserDefaults.standard.string(forKey: Keys.cadence)
            .flatMap(AutoBackupPolicy.Cadence.init(rawValue:)) ?? .weekly
    }

    static var lastBackupDate: Date? {
        UserDefaults.standard.object(forKey: Keys.lastBackupDate) as? Date
    }

    /// `Documents/Backups` — inside the file-sharing-visible container
    /// (Files ▸ On My iPhone ▸ Choreganize ▸ Backups).
    static var backupsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Backups", isDirectory: true)
    }

    // MARK: BGTask lifecycle

    #if os(iOS)
    /// Registers the processing-task handler. Must run before the app
    /// finishes launching (BGTaskScheduler requirement) — called from
    /// `AppDelegate.application(_:didFinishLaunchingWithOptions:)`.
    /// Skipped under unit tests, like the other launch-time services.
    static func register() {
        guard !CoreDataStack.isRunningTests else { return }
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let task = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(task)
        }
        if !registered {
            // Only happens when the identifier is missing from Info.plist's
            // BGTaskSchedulerPermittedIdentifiers — a build misconfiguration.
            Log.error("Auto-backup BGTask registration refused for \(taskIdentifier)", category: .persistence)
        }
    }

    /// Submits (or cancels) the next processing request to match the current
    /// preferences. Submitting with the same identifier replaces any pending
    /// request, so this is safe to call on every preference change. No
    /// network/power requirements: the export is a small local file write.
    static func scheduleNextIfEnabled() {
        guard !CoreDataStack.isRunningTests else { return }
        guard isEnabled else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
            return
        }
        let request = BGProcessingTaskRequest(identifier: taskIdentifier)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        if let last = lastBackupDate {
            request.earliestBeginDate = last.addingTimeInterval(cadence.minimumInterval)
        }
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Non-fatal: the launch catch-up still covers the cadence.
            Log.warning("Auto-backup BGTask submit failed: \(error.localizedDescription)", category: .persistence)
        }
    }

    /// The BGTask run: back up if enabled + due, prune, reschedule, complete.
    private static func handle(_ task: BGProcessingTask) {
        guard isEnabled, AutoBackupPolicy.isDue(last: lastBackupDate, cadence: cadence) else {
            scheduleNextIfEnabled()
            task.setTaskCompleted(success: true)
            return
        }
        // The export is a small local snapshot, but the expiration handler can
        // still race its completion — guard so the task completes exactly once.
        let completion = OnceCompletion { success in task.setTaskCompleted(success: success) }
        task.expirationHandler = { completion.finish(success: false) }

        let ctx = CoreDataStack.shared.newBackgroundContext()
        ctx.perform {
            let ok = performBackup(in: ctx)
            scheduleNextIfEnabled()
            completion.finish(success: ok)
        }
    }
    #else
    /// macOS has no BGTaskScheduler; a repeating `NSBackgroundActivityScheduler`
    /// covers the cadence while the app runs (Mac apps stay open), and the
    /// launch catch-up below remains the reliability backstop. Same funnel
    /// through `AutoBackupPolicy.isDue`, so whichever fires first takes the
    /// backup and the other no-ops until the next interval.
    private static var activityScheduler: NSBackgroundActivityScheduler?

    /// Launch hook, kept name-compatible with the iOS BGTask path.
    static func register() {
        scheduleNextIfEnabled()
    }

    /// (Re)arms the repeating background activity to match the current
    /// preferences; safe to call on every preference change.
    static func scheduleNextIfEnabled() {
        guard !CoreDataStack.isRunningTests else { return }
        activityScheduler?.invalidate()
        activityScheduler = nil
        guard isEnabled else { return }
        let scheduler = NSBackgroundActivityScheduler(identifier: taskIdentifier)
        scheduler.repeats = true
        scheduler.interval = cadence.minimumInterval
        scheduler.tolerance = cadence.minimumInterval / 8
        scheduler.qualityOfService = .background
        scheduler.schedule { activityCompletion in
            runCatchUpIfDue { _ in activityCompletion(.finished) }
        }
        activityScheduler = scheduler
    }
    #endif

    // MARK: Catch-up (launch backstop)

    /// Opportunistic catch-up: BGTask scheduling is best-effort (iOS may
    /// never run a processing task for an infrequently used app), so the
    /// launch path takes the backup itself whenever one is overdue. Called
    /// from `AppDelegate.application(_:didFinishLaunchingWithOptions:)`.
    /// `completion` (main queue) reports whether a backup was attempted, so
    /// UI callers can refresh their file list.
    static func runCatchUpIfDue(completion: ((Bool) -> Void)? = nil) {
        guard !CoreDataStack.isRunningTests,
              isEnabled,
              AutoBackupPolicy.isDue(last: lastBackupDate, cadence: cadence) else {
            if let completion { DispatchQueue.main.async { completion(false) } }
            return
        }
        let ctx = CoreDataStack.shared.newBackgroundContext()
        ctx.perform {
            let ok = performBackup(in: ctx)
            if let completion { DispatchQueue.main.async { completion(ok) } }
        }
    }

    // MARK: Worker

    /// Snapshot → write → prune → stamp. Must be called on `ctx`'s queue
    /// (inside `perform`) — `BackupCodec.snapshot` fetches on that context;
    /// never run this on main.
    private static func performBackup(in ctx: NSManagedObjectContext) -> Bool {
        let fm = FileManager.default
        let dir = backupsDirectory
        do {
            let data = try BackupCodec.exportData(in: ctx)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let name = AutoBackupPolicy.filename(for: Date())
            try data.write(to: dir.appendingPathComponent(name), options: .atomic)

            // Prune to the newest `keepCount` — by filename, which encodes the date.
            let entries = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            for stale in AutoBackupPolicy.filesToPrune(entries) {
                try? fm.removeItem(at: dir.appendingPathComponent(stale))
            }

            UserDefaults.standard.set(Date(), forKey: Keys.lastBackupDate)
            Log.info("Auto-backup written: \(name)", category: .persistence)
            return true
        } catch {
            Log.error("Auto-backup failed: \(error.localizedDescription)", category: .persistence)
            return false
        }
    }

    // MARK: File access (for the Backup & Restore UI)

    /// Existing auto-backup files, newest first.
    static func listBackupFiles() -> [URL] {
        let dir = backupsDirectory
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return entries
            .filter { AutoBackupPolicy.date(fromFilename: $0) != nil }
            .sorted(by: >)   // newest first, same ordering rule as pruning
            .map { dir.appendingPathComponent($0) }
    }

    /// Deletes one auto-backup file (swipe-to-delete in the UI).
    static func deleteBackupFile(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Calls its handler exactly once, whichever of the racing callers (work
/// completion vs. BGTask expiration) gets there first.
private final class OnceCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((Bool) -> Void)?

    init(_ handler: @escaping (Bool) -> Void) {
        self.handler = handler
    }

    func finish(success: Bool) {
        lock.lock()
        let handler = self.handler
        self.handler = nil
        lock.unlock()
        handler?(success)
    }
}
