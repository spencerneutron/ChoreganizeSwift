import Foundation

/// Single gate point for paid ("Plus") features.
///
/// Monetization is **deferred** (see PLAN.md): this returns `true` so every
/// feature in the current wave is fully usable today. When the StoreKit 2
/// paywall lands, this becomes the one place that reflects the user's
/// entitlement — make it observable then and flip the source. Route every
/// Plus-gated affordance through `Entitlements.isPlus` so nothing has to be
/// rewired when the paywall ships.
enum Entitlements {
    /// Whether the user has unlocked Plus features. Hardcoded `true` while
    /// monetization is deferred.
    static var isPlus: Bool { true }
}
