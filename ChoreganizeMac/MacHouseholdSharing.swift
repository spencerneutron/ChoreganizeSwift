import AppKit
import CloudKit
import CoreData

/// macOS presentation half of `HouseholdSharing` (state/rename live in the
/// shared HouseholdShareState.swift). `UICloudSharingController` doesn't exist
/// on macOS — the AppKit path is `NSSharingService(named: .cloudSharing)` fed
/// an `NSItemProvider` that registers the CKShare. Share creation/lookup is
/// identical to iOS: off-main (the container share APIs block their calling
/// thread on the request executor — v1.6.1 lesson), title persisted via
/// `persistUpdatedShare` before the panel can send a link.
extension HouseholdSharing {

    /// Presents the collaboration panel for the given household (share or
    /// manage members/stop, depending on state).
    @MainActor
    static func share(_ household: CDHousehold, stack: CoreDataStack = .shared) {
        guard stack.cloudKitEnabled else {
            Log.warning("Sharing unavailable: CloudKit disabled for this run", category: .cloud)
            return
        }

        let container = stack.container
        let ckContainer = CKContainer(identifier: CoreDataStack.cloudContainerIdentifier)
        let title = household.name ?? "Household"
        let thumbnail = thumbnailPNG   // main thread: reads the app icon
        let householdID = household.objectID

        Task.detached(priority: .userInitiated) {
            if let existing = (try? container.fetchShares(matching: [householdID]))?[householdID] {
                Log.info("Presenting existing household share", category: .cloud)
                // Heal shares created before the title/thumbnail were persisted
                // (their invitation links read "cloudkit.zoneshare" and the
                // collaboration panel's header rendered empty); only the owner
                // may edit the share.
                let missingTitle = existing[CKShare.SystemFieldKey.title] == nil
                let missingThumbnail = existing[CKShare.SystemFieldKey.thumbnailImageData] == nil
                if missingTitle || missingThumbnail,
                   existing.currentUserParticipant?.role == .owner,
                   let store = stack.privateStore {
                    if missingTitle { existing[CKShare.SystemFieldKey.title] = title as CKRecordValue }
                    if missingThumbnail, let thumbnail { existing[CKShare.SystemFieldKey.thumbnailImageData] = thumbnail as CKRecordValue }
                    existing[CKShare.SystemFieldKey.shareType] = Self.shareType as CKRecordValue
                    container.persistUpdatedShare(existing, in: store) { _, error in
                        if let error { Log.error("Backfilling share title/thumbnail failed: \(error.localizedDescription)", category: .cloud) }
                    }
                }
                await MainActor.run {
                    present(existing, in: ckContainer)
                }
                return
            }

            Log.info("Creating new household share", category: .cloud)
            container.share([household], to: nil) { _, share, sharedContainer, error in
                guard let share, let sharedContainer, error == nil else {
                    Log.error("Failed to create household share: \(error?.localizedDescription ?? "unknown")", category: .cloud)
                    return
                }
                share[CKShare.SystemFieldKey.title] = title as CKRecordValue
                if let thumbnail { share[CKShare.SystemFieldKey.thumbnailImageData] = thumbnail as CKRecordValue }
                share[CKShare.SystemFieldKey.shareType] = Self.shareType as CKRecordValue
                // Persist the title before the panel can send a link (same as iOS).
                guard let store = stack.privateStore else {
                    Task { @MainActor in
                        present(share, in: sharedContainer)
                    }
                    return
                }
                container.persistUpdatedShare(share, in: store) { persisted, error in
                    if let error { Log.error("Persisting share title failed: \(error.localizedDescription)", category: .cloud) }
                    Task { @MainActor in
                        present(persisted ?? share, in: sharedContainer)
                    }
                }
            }
        }
    }

    /// Uniform type identifier recorded on the share so the panel and
    /// invitations can describe what is being shared.
    static let shareType = "com.svk.Choreganize.household"

    /// PNG of the app icon for the collaboration panel header and invitation
    /// previews. Without a thumbnail the macOS panel renders an empty header
    /// (seen at the 2-sim gate), title or not.
    @MainActor
    private static var thumbnailPNG: Data? {
        let icon: NSImage? = NSApp.applicationIconImage
        guard let icon, let tiff = icon.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    @MainActor
    private static func present(_ share: CKShare, in container: CKContainer) {
        guard let service = NSSharingService(named: .cloudSharing) else {
            Log.error("Cloud-sharing service unavailable", category: .cloud)
            return
        }
        let itemProvider = NSItemProvider()
        itemProvider.registerCloudKitShare(share, container: container)
        itemProvider.suggestedName = share[CKShare.SystemFieldKey.title] as? String
        service.delegate = MacSharingDelegate.shared
        // The panel attaches to the key window; bring the app forward first
        // so it doesn't sit behind another app bouncing the Dock icon.
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: [itemProvider])
    }
}

/// Logs sharing outcomes and notifies the UI to refresh its share state —
/// the AppKit twin of the iOS `SharingDelegate`.
final class MacSharingDelegate: NSObject, NSCloudSharingServiceDelegate {
    static let shared = MacSharingDelegate()

    /// Read-write only (households are collaborative), both access modes —
    /// mirrors the iOS controller's `availablePermissions` (see the
    /// "Item Unavailable" copied-link rationale there).
    func options(for sharingService: NSSharingService,
                 share provider: NSItemProvider) -> NSSharingService.CloudKitOptions {
        [.allowReadWrite, .allowPrivate, .allowPublic]
    }

    /// Anchor the collaboration panel to our window instead of a detached
    /// panel that demands activation from the Dock.
    func sharingService(_ sharingService: NSSharingService,
                        sourceWindowForShareItems items: [Any],
                        sharingContentScope: UnsafeMutablePointer<NSSharingService.SharingContentScope>) -> NSWindow? {
        NSApp.keyWindow ?? NSApp.mainWindow
    }

    func sharingService(_ sharingService: NSSharingService, didSave share: CKShare) {
        Log.info("Household share saved", category: .cloud)
        NotificationCenter.default.post(name: .householdShareDidChange, object: nil)
    }

    func sharingService(_ sharingService: NSSharingService, didStopSharing share: CKShare) {
        Log.info("Household sharing stopped", category: .cloud)
        NotificationCenter.default.post(name: .householdShareDidChange, object: nil)
    }

    func sharingService(_ sharingService: NSSharingService,
                        didFailToShareItems items: [Any], error: Error) {
        Log.error("Share save failed: \(error.localizedDescription)", category: .cloud)
    }
}
