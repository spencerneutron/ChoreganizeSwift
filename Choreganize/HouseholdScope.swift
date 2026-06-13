import CoreData

/// The two data scopes a user switches between. "Solo" is personal data
/// (`household == nil`); "Household" is the shared bucket (becomes the CloudKit
/// share root in Phase 3).
enum AppScope: String, CaseIterable, Identifiable {
    case solo, household
    var id: String { rawValue }
    var title: String { self == .solo ? "Solo" : "Household" }
    var systemImage: String { self == .solo ? "person" : "house" }
}

/// Managed objects that belong to an optional household (`nil` == Solo scope).
protocol HouseholdScoped {
    var household: CDHousehold? { get }
}

extension CDChore: HouseholdScoped {}
extension CDArea: HouseholdScoped {}
extension CDCompletion: HouseholdScoped {}
extension CDLockedDay: HouseholdScoped {}

extension Sequence where Element: HouseholdScoped {
    /// The items in the given scope (`nil` household == Solo).
    func inScope(_ household: CDHousehold?) -> [Element] {
        filter { $0.household == household }
    }
}
