import Testing
import Foundation
@testable import Choreganize

/// The debug/production data fence (DataIsolation): release builds keep today's
/// locations and keys; debug builds never touch them.
struct DataIsolationTests {

    @Test func releaseBuildsAreAlwaysProduction() {
        for env in [[:], ["CHOREGANIZE_ISOLATED_DATA": "1"], ["CHOREGANIZE_LOCAL_ONLY": "1"]] {
            #expect(DataIsolation.resolveMode(isDebugBuild: false, environment: env, isolatedDataArgument: true) == .production)
        }
    }

    @Test func debugBuildsAreDevelopmentUnlessIsolated() {
        #expect(DataIsolation.resolveMode(isDebugBuild: true, environment: [:], isolatedDataArgument: false) == .development)
        #expect(DataIsolation.resolveMode(isDebugBuild: true, environment: [:], isolatedDataArgument: true) == .isolated)
        #expect(DataIsolation.resolveMode(isDebugBuild: true, environment: ["CHOREGANIZE_ISOLATED_DATA": "1"], isolatedDataArgument: false) == .isolated)
        #expect(DataIsolation.resolveMode(isDebugBuild: true, environment: ["CHOREGANIZE_LOCAL_ONLY": "1"], isolatedDataArgument: false) == .isolated)
        #expect(DataIsolation.resolveMode(isDebugBuild: true, environment: ["CHOREGANIZE_ISOLATED_DATA": "0"], isolatedDataArgument: false) == .development)
    }

    @Test func productionPathsAndKeysAreUnchanged() {
        let base = URL(fileURLWithPath: "/tmp/Application Support", isDirectory: true)
        #expect(DataIsolation.storeDirectory(base, mode: .production) == base)
        #expect(DataIsolation.key("autoBackup.lastDate", mode: .production) == "autoBackup.lastDate")
        #expect(DataIsolation.key("completerIdentity.userRecordName", mode: .production) == "completerIdentity.userRecordName")
    }

    @Test func otherModesGetTheirOwnFolderAndKeys() {
        let base = URL(fileURLWithPath: "/tmp/Application Support", isDirectory: true)
        #expect(DataIsolation.storeDirectory(base, mode: .development).lastPathComponent == "Development")
        #expect(DataIsolation.storeDirectory(base, mode: .isolated).lastPathComponent == "Isolated")
        #expect(DataIsolation.key("autoBackup.lastDate", mode: .development) == "autoBackup.lastDate.development")
        #expect(DataIsolation.key("autoBackup.lastDate", mode: .isolated) == "autoBackup.lastDate.isolated")
    }

    /// This test binary is a debug build, so the fence must be up: the running
    /// app's store, backups and keys are all away from the production ones.
    @Test func thisDebugRunNeverUsesProductionLocations() throws {
        #expect(DataIsolation.mode != .production)
        #expect(DataIsolation.label != nil)
        #expect(AutoBackup.backupsDirectory.lastPathComponent != "Backups")
        #expect(AutoBackup.Keys.lastBackupDate != "autoBackup.lastDate")
        let path = try #require(CoreDataStack.shared.privateStore?.url?.path)
        #expect(path.contains("/Development/") || path.contains("/Isolated/"))
    }
}
