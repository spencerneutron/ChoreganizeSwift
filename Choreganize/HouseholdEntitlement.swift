import CoreData
import Foundation

/// CG-15 / #97 — scope-aware household entitlement: one member pays, the
/// whole household benefits.
///
/// The synced `CDHousehold.plusEnabled` flag is the propagation vehicle
/// (additive attribute → lightweight migration; joins `completedBy` in the
/// Production schema-deploy batch). Any locally-entitled member's device
/// stamps it `true`; members read it through `Entitlements.isPlus(for:)`,
/// which is own-entitlement OR household flag.
///
/// Un-stamping uses an honor-system single-owner model (v1 trust model — the
/// flag is spoofable by anyone with write access to the share; acceptable for
/// a chores app): each device remembers whether *it* lit the flag, and only
/// clears it when its own entitlement lapses. If two members were both
/// entitled, the second-to-lapse clears it and the still-entitled member's
/// next sync pass re-lights it — the flag converges to the truth.
@MainActor
enum HouseholdEntitlement {

    /// The effective Plus gate for features that act on household data.
    static func effectiveIsPlus(ownPlus: Bool, household: CDHousehold?) -> Bool {
        ownPlus || (household?.plusEnabled ?? false)
    }

    /// Reconciles the household flag with this device's own entitlement.
    /// Call whenever either side may have changed: launch, foreground,
    /// entitlement refresh, share changes. Cheap and idempotent.
    static func syncStamp(household: CDHousehold?,
                          isPlus: Bool,
                          defaults: UserDefaults = .standard) {
        guard let household, let householdID = household.id,
              let ctx = household.managedObjectContext else { return }
        let setByUsKey = "householdPlus.setBy.\(householdID.uuidString)"
        let weSetIt = defaults.bool(forKey: setByUsKey)

        if isPlus && !household.plusEnabled {
            household.plusEnabled = true
            defaults.set(true, forKey: setByUsKey)
            try? ctx.save()
            Log.info("Household Plus flag lit by this member", category: .cloud)
        } else if !isPlus && household.plusEnabled && weSetIt {
            household.plusEnabled = false
            defaults.set(false, forKey: setByUsKey)
            try? ctx.save()
            Log.info("Household Plus flag cleared (this member's entitlement lapsed)", category: .cloud)
        }
        // Someone else's flag while we're unentitled, or already-lit while
        // we're entitled: nothing to reconcile.
    }
}

extension Notification.Name {
    /// Posted by `EntitlementStore` when `isPlus` flips, so household stamping
    /// and gated UI outside SwiftUI observation can react.
    static let plusEntitlementDidChange = Notification.Name("plusEntitlementDidChange")
}
