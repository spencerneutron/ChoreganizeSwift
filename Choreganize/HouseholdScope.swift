import CoreData

/// The two data scopes a user switches between. "Personal" is personal data
/// (`household == nil`); "Household" is the shared bucket (becomes the CloudKit
/// share root in Phase 3). The `solo` case name / rawValue is retained internally
/// (persisted defaults + launch args depend on it); only the label reads "Personal".
enum AppScope: String, CaseIterable, Identifiable {
    case solo, household
    var id: String { rawValue }
    var title: String { self == .solo ? "Personal" : "Household" }
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
