import Foundation
import StoreKit

/// CG-12 / #95 — the Plus product catalog.
///
/// BOTH models are defined — auto-renewable subscriptions and a one-time
/// lifetime unlock — so the subscription-vs-one-time decision stays an App
/// Store Connect configuration choice, not a code change: the paywall sells
/// whatever subset of these IDs actually exists in ASC, and entitlement checks
/// accept any of them.
enum PlusProduct {
    static let monthly = "com.svk.Choreganize.plus.monthly"
    static let yearly = "com.svk.Choreganize.plus.yearly"
    static let lifetime = "com.svk.Choreganize.plus.lifetime"
    static let all: Set<String> = [monthly, yearly, lifetime]

    /// The one entitlement decision, pure for testing: any current transaction
    /// on any Plus product unlocks Plus.
    static func isEntitled<S: Sequence>(activeProductIDs: S) -> Bool where S.Element == String {
        activeProductIDs.contains { all.contains($0) }
    }
}

/// CG-12 / #95 — observable source of truth for the user's Plus entitlement,
/// driven by StoreKit 2.
///
/// `isPlus` seeds from a cached value at launch (so gated UI doesn't flicker
/// while StoreKit wakes up, and Plus survives brief offline launches), then
/// tracks `Transaction.currentEntitlements`. A long-lived `Transaction.updates`
/// listener catches purchases, renewals, revocations, refunds, and Family
/// Sharing changes made outside the app; `syncOnForeground()` (CG-13 / #96)
/// re-checks on every scene activation and finishes stragglers.
@MainActor
final class EntitlementStore: ObservableObject {
    static let shared = EntitlementStore()

    /// Whether the user has unlocked Plus. The only gate every Plus-gated
    /// affordance should read (directly or via `Entitlements.isPlus`).
    @Published private(set) var isPlus: Bool
    /// Live Plus products, cheapest first, for the paywall. Empty until loaded
    /// (or when the store is unreachable / products aren't configured yet).
    @Published private(set) var products: [Product] = []

    #if DEBUG
    /// Developer override for exercising gated UI in the simulator without a
    /// StoreKit configuration: "on" / "off" / anything else = follow StoreKit.
    static let debugOverrideKey = "debug.plusOverride"
    #endif

    private static let cacheKey = "entitlement.isPlus"
    private static var cacheDefaults: UserDefaults {
        UserDefaults(suiteName: WidgetShared.appGroupIdentifier) ?? .standard
    }

    /// StoreKit has no store to talk to under unit tests; don't spin listeners.
    private static var storeKitDisabled: Bool { CoreDataStack.isRunningTests }

    private var updatesTask: Task<Void, Never>?
    private var started = false

    init() {
        isPlus = Self.cacheDefaults.bool(forKey: Self.cacheKey)
    }

    deinit {
        updatesTask?.cancel()
    }

    /// Starts the transaction listener and the initial entitlement/product
    /// load. Call once at launch; safe to call again.
    func start() {
        guard !started, !Self.storeKitDisabled else { return }
        started = true

        updatesTask = Task(priority: .background) { [weak self] in
            for await update in Transaction.updates {
                if case .verified(let transaction) = update {
                    await transaction.finish()
                }
                await self?.refreshEntitlement()
            }
        }
        Task { [weak self] in
            await self?.refreshEntitlement()
            await self?.loadProducts()
        }
    }

    /// CG-13 / #96: re-sync on scene activation — finishes any unfinished
    /// transactions (interrupted purchases, Ask to Buy approvals, Family
    /// Sharing joins) and re-evaluates the entitlement.
    func syncOnForeground() {
        guard !Self.storeKitDisabled else { return }
        Task { [weak self] in
            for await unfinished in Transaction.unfinished {
                if case .verified(let transaction) = unfinished {
                    await transaction.finish()
                }
            }
            await self?.refreshEntitlement()
        }
    }

    /// Purchases a product and returns whether Plus is now unlocked. Pending
    /// (Ask to Buy) and user-cancelled purchases return false without error;
    /// the updates listener picks pending ones up when they resolve.
    func purchase(_ product: Product) async throws -> Bool {
        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            if case .verified(let transaction) = verification {
                await transaction.finish()
            }
            await refreshEntitlement()
            return isPlus
        case .pending, .userCancelled:
            return false
        @unknown default:
            return false
        }
    }

    /// Restores purchases (also how a Family Sharing member first syncs the
    /// shared entitlement on a fresh device).
    func restore() async {
        try? await AppStore.sync()
        await refreshEntitlement()
    }

    /// Recomputes `isPlus` from StoreKit's current entitlements and caches it.
    func refreshEntitlement() async {
        var activeIDs: [String] = []
        for await entitlement in Transaction.currentEntitlements {
            if case .verified(let transaction) = entitlement {
                activeIDs.append(transaction.productID)
            }
        }
        var entitled = PlusProduct.isEntitled(activeProductIDs: activeIDs)
        #if DEBUG
        switch UserDefaults.standard.string(forKey: Self.debugOverrideKey) {
        case "on": entitled = true
        case "off": entitled = false
        default: break
        }
        #endif
        setPlus(entitled)
    }

    private func loadProducts() async {
        guard let loaded = try? await Product.products(for: PlusProduct.all) else { return }
        products = loaded.sorted { $0.price < $1.price }
    }

    private func setPlus(_ newValue: Bool) {
        if isPlus != newValue { isPlus = newValue }
        Self.cacheDefaults.set(newValue, forKey: Self.cacheKey)
    }

    #if DEBUG
    /// Re-evaluate after the Developer override changes.
    func applyDebugOverride() {
        Task { await refreshEntitlement() }
    }
    #endif
}

/// Compatibility seam kept from the pre-paywall era: every Plus-gated
/// affordance routes through here (or observes `EntitlementStore` directly
/// when it needs re-render on change).
@MainActor
enum Entitlements {
    /// Whether the user has unlocked Plus features.
    static var isPlus: Bool { EntitlementStore.shared.isPlus }
}
