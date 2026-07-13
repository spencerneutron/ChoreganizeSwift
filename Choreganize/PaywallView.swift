import SwiftUI
import StoreKit

/// CG-12 / #95 — the Choreganize Plus paywall.
///
/// Sells whatever Plus products App Store Connect actually offers (see
/// `PlusProduct`): subscriptions and/or the lifetime unlock render from the
/// same product list, so the pricing-model decision lives entirely in ASC.
/// Review compliance: localized price on every buy button, Restore Purchases,
/// and Terms/Privacy links are always visible.
struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = EntitlementStore.shared
    @State private var purchasing = false
    @State private var errorMessage: String?
    /// Products still empty after the grace period — offer a retry rather
    /// than an endless spinner.
    @State private var loadTimedOut = false

    private static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    private static let privacyURL = URL(string: "https://github.com/spencerneutron/ChoreganizeSwift/blob/main/PRIVACY.md")!

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    header
                    if store.isPlus {
                        plusActiveCard
                    } else {
                        featureList
                        productButtons
                    }
                    legalFooter
                }
                .padding()
            }
            .navigationTitle("Choreganize Plus")
            .compatInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Purchase Failed", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "Unknown error")
            }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 44))
                .foregroundStyle(.yellow.gradient)
            Text("Unlock the full household")
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
            Text("Plus keeps the lights on — CloudKit sync and push traffic aren't free — and unlocks everything below for you. One member's Plus can light up the whole household.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var plusActiveCard: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 36))
                .foregroundStyle(.green)
            Text("You have Choreganize Plus")
                .font(.headline)
            Text("Thanks for supporting the app! Manage or cancel from Settings ▸ Apple Account ▸ Subscriptions.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 12) {
            featureRow("bell.badge", "Member notifications",
                       "Know the moment someone else checks off a chore.")
            featureRow("person.2.badge.gearshape", "Chore assignment",
                       "Give every chore an owner.")
            featureRow("house.and.flag", "Multiple households",
                       "Home, the cabin, the office — switch freely.")
            featureRow("chart.bar.xaxis", "Insights & heatmap",
                       "Trends, streak history, and a yearly heatmap.")
            featureRow("clock.badge", "Custom reminders & recurrence",
                       "Per-room reminder times and flexible schedules.")
            featureRow("person.3", "Family Sharing",
                       "Your purchase shares with your Apple Family at no extra cost.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func featureRow(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var productButtons: some View {
        if store.products.isEmpty {
            if store.productsLoadFailed || loadTimedOut {
                VStack(spacing: 8) {
                    Text("Couldn't load plans.")
                        .font(.subheadline.weight(.semibold))
                    Text("Check your connection and try again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Retry") {
                        loadTimedOut = false
                        store.reloadProducts()
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.vertical, 8)
            } else {
                VStack(spacing: 6) {
                    ProgressView()
                    Text("Loading plans…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
                .task {
                    try? await Task.sleep(for: .seconds(12))
                    if store.products.isEmpty { loadTimedOut = true }
                }
            }
        } else {
            VStack(spacing: 10) {
                ForEach(store.products, id: \.id) { product in
                    Button {
                        purchase(product)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(product.displayName.isEmpty ? fallbackName(for: product) : product.displayName)
                                    .font(.subheadline.weight(.semibold))
                                if let subscription = product.subscription {
                                    Text("per \(subscription.subscriptionPeriod.localizedUnit)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("One-time purchase")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(product.displayPrice)
                                .font(.headline)
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(purchasing)
                }
            }
        }
    }

    private var legalFooter: some View {
        VStack(spacing: 8) {
            if !store.isPlus {
                Button("Restore Purchases") {
                    Task {
                        purchasing = true
                        await store.restore()
                        purchasing = false
                    }
                }
                .font(.footnote)
                .disabled(purchasing)
            }
            Text("Subscriptions renew automatically until cancelled. Payment is charged to your Apple Account; manage or cancel any time in Settings.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            HStack(spacing: 16) {
                Link("Terms of Use", destination: Self.termsURL)
                Link("Privacy Policy", destination: Self.privacyURL)
            }
            .font(.caption2)
        }
        .padding(.top, 8)
    }

    private func fallbackName(for product: Product) -> String {
        switch product.id {
        case PlusProduct.yearly: "Plus Yearly"
        case PlusProduct.lifetime: "Plus Lifetime"
        default: "Choreganize Plus"
        }
    }

    private func purchase(_ product: Product) {
        purchasing = true
        Task {
            do {
                _ = try await store.purchase(product)
            } catch {
                errorMessage = error.localizedDescription
            }
            purchasing = false
        }
    }
}

private extension Product.SubscriptionPeriod {
    /// "month" / "year" / "3 months" for the price caption.
    var localizedUnit: String {
        let unitName: String
        switch unit {
        case .day: unitName = "day"
        case .week: unitName = "week"
        case .month: unitName = "month"
        case .year: unitName = "year"
        @unknown default: unitName = "period"
        }
        return value == 1 ? unitName : "\(value) \(unitName)s"
    }
}
