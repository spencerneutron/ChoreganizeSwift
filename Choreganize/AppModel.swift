import Foundation
import SwiftUI
import CoreData
import CloudKit
import os

/// App-level coordinator. Since the Core Data + CloudKit re-platform, the data
/// itself lives in Core Data and is read by the views via `@FetchRequest`; this
/// object now only carries cross-cutting UI state (sync status, errors, banners).
@MainActor
final class AppModel: ObservableObject {
    static let schemaVersion: Int = 1

    // MARK: - Banner messaging
    enum BannerStyle {
        case info, success, warning, error
    }

    struct BannerMessage: Identifiable, Equatable {
        let id = UUID()
        let title: String?
        let message: String
        let style: BannerStyle
        let actionTitle: String?
        let action: (() -> Void)?
        let duration: TimeInterval

        init(title: String? = nil, message: String, style: BannerStyle = .info, actionTitle: String? = nil, action: (() -> Void)? = nil, duration: TimeInterval = 4.0) {
            self.title = title
            self.message = message
            self.style = style
            self.actionTitle = actionTitle
            self.action = action
            self.duration = duration
        }

        static func == (lhs: BannerMessage, rhs: BannerMessage) -> Bool { lhs.id == rhs.id }
    }

    // MARK: - Sync status (CG-06)
    /// High-level CloudKit sync state surfaced to the UI. Replaces the old, never-set
    /// `isSyncing` Bool (GH #82): these values are driven by real
    /// `NSPersistentCloudKitContainer` events and the stack's account state.
    enum SyncState: Equatable {
        /// CloudKit mirroring is off for this run (tests / local-only / no entitlement).
        case disabled
        /// CloudKit was intended but no iCloud account is available — sync is paused.
        case notSignedIn
        /// CloudKit is on and currently idle (caught up).
        case idle
        /// A CloudKit import/export/setup event is in progress.
        case syncing
        /// The most recent CloudKit event failed (transient or otherwise).
        case error
    }

    @Published private(set) var syncState: SyncState = .disabled
    /// Convenience for the status spinner. Real now (CG-06): true only while a
    /// CloudKit event is actually running.
    var isSyncing: Bool { syncState == .syncing }

    @Published var lastError: String?
    @Published var currentBanner: BannerMessage?

    // MARK: - Deep linking (CG-05)
    /// Set by a widget deep-link to request the Work view scroll to + briefly highlight
    /// a chore. `ContentView` switches to Work mode when this becomes non-nil, `WeekView`
    /// snaps back to today, and today's `DayPage` consumes it (scrolls/flashes the row)
    /// and resets it to `nil`. Driving this through observed state — rather than a
    /// one-shot `Notification` — means it survives the mode switch: the Work view can be
    /// mounted *in response* to the link and still see the pending target.
    @Published var deepLinkChore: UUID?

    /// True once we've shown the "not signed in" cue this session, so the banner
    /// isn't re-queued on every CloudKit event.
    private var didAnnounceNotSignedIn = false
    private var cloudKitEventObserver: NSObjectProtocol?

    // MARK: - Scope (Solo vs Household)
    @Published private(set) var scope: AppScope = .solo
    /// Display name of the active household (mirrors `activeHousehold?.name`).
    @Published private(set) var householdName: String = "Household"
    private let scopeKey = "activeScope"

    private var bannerQueue: [BannerMessage] = []
    private var bannerTask: Task<Void, Never>?

    init() {
        let restored = AppScope(rawValue: UserDefaults.standard.string(forKey: scopeKey) ?? "") ?? .solo
        scope = restored
        if restored == .household { ensureHousehold() }
        refreshHouseholdName()
        startSyncMonitoring()
    }

    deinit {
        if let cloudKitEventObserver {
            NotificationCenter.default.removeObserver(cloudKitEventObserver)
        }
    }

    // MARK: - Sync monitoring (CG-06)

    /// Establishes the initial sync state from the stack and begins observing real
    /// CloudKit mirroring events. When CloudKit is off (tests/local-only) or the
    /// stack degraded for a missing account (CG-07), reflect that immediately and
    /// surface a one-time "not signed in" cue so the user knows sync is paused.
    private func startSyncMonitoring() {
        let stack = CoreDataStack.shared
        guard stack.cloudKitEnabled else {
            syncState = stack.degradedToLocalOnly ? .notSignedIn : .disabled
            if stack.degradedToLocalOnly { announceNotSignedInIfNeeded() }
            return
        }
        syncState = .idle
        // queue: nil, NOT .main — queue-based delivery makes the *posting* thread
        // wait for the block (NSOperation waitUntilFinished inside the post), so the
        // CloudKit mirroring queue stalls whenever the main thread is busy, and
        // deadlocks outright if main is blocked on the mirroring machinery (e.g.
        // inside container.share()). Take the event on the posting thread and hop
        // to the main actor asynchronously ourselves.
        cloudKitEventObserver = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: stack.container,
            queue: nil
        ) { [weak self] note in
            guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event else { return }
            Task { @MainActor in self?.handleCloudKitEvent(event) }
        }
    }

    /// Maps a CloudKit mirroring event to `syncState` and surfaces account/error cues.
    private func handleCloudKitEvent(_ event: NSPersistentCloudKitContainer.Event) {
        // endDate == nil means the event just started.
        if event.endDate == nil {
            syncState = .syncing
            return
        }
        if let error = event.error as NSError? {
            syncState = .error
            Log.warning("CloudKit \(event.type) failed: \(error.code) \(error.localizedDescription)", category: .cloud)
            if CoreDataStack.isMissingAccountError(error) {
                syncState = .notSignedIn
                announceNotSignedInIfNeeded()
            }
        } else {
            syncState = .idle
        }
    }

    /// Surfaces the "sync paused / not signed in" banner exactly once per session.
    private func announceNotSignedInIfNeeded() {
        guard !didAnnounceNotSignedIn else { return }
        didAnnounceNotSignedIn = true
        showBanner(title: "Sync paused",
                   message: "You're not signed in to iCloud. Your chores stay on this device until you sign in.",
                   style: .warning,
                   duration: 6.0)
    }

    private var context: NSManagedObjectContext { CoreDataStack.shared.viewContext }

    /// The household backing the active scope (`nil` while in Solo). Prefers a
    /// household shared *with* us (participant) over one we own, so a participant
    /// who happens to also have a stale empty local household still sees the
    /// shared one after accepting an invite.
    var activeHousehold: CDHousehold? {
        guard scope == .household else { return nil }
        return resolvedHousehold
    }

    /// The household backing Household-scoped data, *regardless* of the active scope.
    /// `activeHousehold` is nil while in Solo, but the badge counts Household chores
    /// even from Solo, so it resolves the household through this instead.
    var resolvedHousehold: CDHousehold? {
        household(in: CoreDataStack.shared.sharedStore) ?? household(in: nil)
    }

    /// The first household in the given store (or across all stores when `nil`).
    private func household(in store: NSPersistentStore?) -> CDHousehold? {
        let request = NSFetchRequest<CDHousehold>(entityName: "CDHousehold")
        request.fetchLimit = 1
        request.sortDescriptors = [NSSortDescriptor(key: "createdDate", ascending: true)]
        if let store { request.affectedStores = [store] }
        return try? context.fetch(request).first
    }

    /// Returns the household (one we own or one shared with us), creating a local
    /// one only when none exists anywhere.
    @discardableResult
    func ensureHousehold() -> CDHousehold {
        if let existing = household(in: nil) { return existing }
        let created = CDHousehold(context: context)
        created.id = UUID()
        created.name = "Household"
        created.createdDate = Date()
        try? context.save()
        Log.info("Created local household", category: .model)
        return created
    }

    /// Switches the active scope, creating the household if needed, and persists it.
    func setScope(_ newScope: AppScope) {
        if newScope == .household { ensureHousehold() }
        scope = newScope
        UserDefaults.standard.set(newScope.rawValue, forKey: scopeKey)
        refreshHouseholdName()
    }

    /// Updates the published household display name from the active household.
    func refreshHouseholdName() {
        householdName = activeHousehold?.name ?? "Household"
    }

    // MARK: - Banner controls
    func showBanner(title: String? = nil,
                    message: String,
                    style: BannerStyle = .info,
                    actionTitle: String? = nil,
                    action: (() -> Void)? = nil,
                    duration: TimeInterval = 4.0) {
        let banner = BannerMessage(title: title, message: message, style: style, actionTitle: actionTitle, action: action, duration: duration)
        if currentBanner == nil {
            present(banner)
        } else {
            bannerQueue.append(banner)
        }
    }

    func dismissBanner(triggerAction: Bool = false) {
        if triggerAction { currentBanner?.action?() }
        currentBanner = nil
        bannerTask?.cancel()
        bannerTask = nil
        if let next = bannerQueue.first {
            bannerQueue.removeFirst()
            present(next)
        }
    }

    private func present(_ banner: BannerMessage) {
        currentBanner = banner
        bannerTask?.cancel()
        bannerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: UInt64((banner.duration) * 1_000_000_000))
                self.dismissBanner()
            } catch { /* cancelled */ }
        }
    }

    // MARK: - Legacy persistence shape
    /// The JSON shape written by pre-Core-Data versions. Retained only so
    /// `JSONImporter` can decode the legacy `chore_data.json` when migrating to
    /// Core Data. Not used as a live store.
    struct SavedState: Codable {
        var chores: [Chore]
        var areas: [Area]
        var completions: [Completion]
        var lockedDays: Set<Date> = []
        var schemaVersion: Int?

        enum CodingKeys: String, CodingKey {
            case chores, areas, completions, lockedDays, schemaVersion
        }

        init(chores: [Chore], areas: [Area], completions: [Completion], lockedDays: Set<Date> = [], schemaVersion: Int? = AppModel.schemaVersion) {
            self.chores = chores
            self.areas = areas
            self.completions = completions
            self.lockedDays = lockedDays
            self.schemaVersion = schemaVersion
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            chores = try container.decodeIfPresent([Chore].self, forKey: .chores) ?? []
            areas = try container.decodeIfPresent([Area].self, forKey: .areas) ?? []
            completions = try container.decodeIfPresent([Completion].self, forKey: .completions) ?? []
            lockedDays = try container.decodeIfPresent(Set<Date>.self, forKey: .lockedDays) ?? []
            schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(chores, forKey: .chores)
            try container.encode(areas, forKey: .areas)
            try container.encode(completions, forKey: .completions)
            try container.encode(lockedDays, forKey: .lockedDays)
            try container.encode(schemaVersion ?? AppModel.schemaVersion, forKey: .schemaVersion)
        }
    }
}
