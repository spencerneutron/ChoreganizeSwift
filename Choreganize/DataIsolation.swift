import Foundation

/// Keeps a debug run from ever sharing data with the App Store build.
///
/// An Xcode-run build talks to CloudKit's **Development** environment; the App Store
/// build talks to **Production**. On the Mac both are the same sandboxed app (same
/// bundle ID and team), so without a fence they share one container: one store file
/// and one set of preferences. Records a debug run imports from Development (or makes
/// while offline) then sit in the file the App Store build later exports to
/// Production, which is how test data ends up in real data. On iPhone the same thing
/// happens when an Xcode build replaces the App Store build on a device and back.
///
/// - **Production** (release builds): the normal locations, exactly as before.
/// - **Development** (debug builds): the store files and the few preferences that can
///   leak into data (the completer identity, auto-backup bookkeeping) get their own
///   names, so CloudKit Development data never touches the production store.
/// - **Isolated** (debug builds launched with `-isolatedData YES`, or with
///   `CHOREGANIZE_ISOLATED_DATA=1` or `CHOREGANIZE_LOCAL_ONLY=1`): a scratch store with
///   CloudKit off and no automatic backups. Nothing from the run can reach iCloud or
///   the real app's files. The "(Isolated Data)" schemes launch this way.
enum DataIsolation {
    enum Mode: String, CaseIterable {
        case production, development, isolated
    }

    /// This run's mode, decided once at launch.
    static let mode: Mode = resolveMode(
        isDebugBuild: isDebugBuild,
        environment: ProcessInfo.processInfo.environment,
        isolatedDataArgument: UserDefaults.standard.bool(forKey: "isolatedData"))

    static var isIsolated: Bool { mode == .isolated }

    private static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    static func resolveMode(isDebugBuild: Bool, environment: [String: String],
                            isolatedDataArgument: Bool) -> Mode {
        guard isDebugBuild else { return .production }
        if isolatedDataArgument
            || environment["CHOREGANIZE_ISOLATED_DATA"] == "1"
            || environment["CHOREGANIZE_LOCAL_ONLY"] == "1" {
            return .isolated
        }
        return .development
    }

    /// Where `mode` keeps its Core Data files, given the default store directory.
    static func storeDirectory(_ base: URL, mode: Mode = mode) -> URL {
        switch mode {
        case .production:  return base
        case .development: return base.appendingPathComponent("Development", isDirectory: true)
        case .isolated:    return base.appendingPathComponent("Isolated", isDirectory: true)
        }
    }

    /// A preferences key for `mode`: unchanged in production, suffixed otherwise.
    static func key(_ base: String, mode: Mode = mode) -> String {
        mode == .production ? base : "\(base).\(mode.rawValue)"
    }

    /// Shown in the app outside production, so a debug run is never mistaken for
    /// the real one.
    static var label: String? {
        // The Mac's App Store screenshot capture (a debug build) mustn't show it.
        if ProcessInfo.processInfo.environment["CHOREGANIZE_MAC_STORE_SHOTS"]?.isEmpty == false { return nil }
        switch mode {
        case .production:  return nil
        case .development: return "Development data"
        case .isolated:    return "Isolated data · not synced"
        }
    }
}
