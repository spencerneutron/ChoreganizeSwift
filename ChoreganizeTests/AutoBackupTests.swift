import Foundation
import Testing
@testable import Choreganize

/// CG-20 / #102 — covers the pure planning half of automatic backups
/// (`AutoBackupPolicy`): due-date math, newest-N prune selection, and the
/// filename encoding. Fixed reference dates keep everything deterministic.
struct AutoBackupTests {

    private let now = Date(timeIntervalSince1970: 1_752_300_000)   // fixed "now"
    private let hour: TimeInterval = 60 * 60
    private let day: TimeInterval = 24 * 60 * 60

    // MARK: isDue

    @Test func neverBackedUpIsAlwaysDue() {
        #expect(AutoBackupPolicy.isDue(last: nil, cadence: .daily, now: now))
        #expect(AutoBackupPolicy.isDue(last: nil, cadence: .weekly, now: now))
    }

    @Test func freshBackupIsNotDue() {
        #expect(!AutoBackupPolicy.isDue(last: now, cadence: .daily, now: now))
        #expect(!AutoBackupPolicy.isDue(last: now.addingTimeInterval(-hour), cadence: .daily, now: now))
        #expect(!AutoBackupPolicy.isDue(last: now.addingTimeInterval(-day), cadence: .weekly, now: now))
    }

    @Test func dailyCadenceBoundary() {
        #expect(!AutoBackupPolicy.isDue(last: now.addingTimeInterval(-23 * hour), cadence: .daily, now: now))
        #expect(AutoBackupPolicy.isDue(last: now.addingTimeInterval(-24 * hour), cadence: .daily, now: now))   // boundary counts
        #expect(AutoBackupPolicy.isDue(last: now.addingTimeInterval(-25 * hour), cadence: .daily, now: now))
    }

    @Test func weeklyCadenceBoundary() {
        #expect(!AutoBackupPolicy.isDue(last: now.addingTimeInterval(-6 * day), cadence: .weekly, now: now))
        #expect(AutoBackupPolicy.isDue(last: now.addingTimeInterval(-7 * day), cadence: .weekly, now: now))    // boundary counts
        #expect(AutoBackupPolicy.isDue(last: now.addingTimeInterval(-8 * day), cadence: .weekly, now: now))
    }

    // MARK: Pruning

    private func name(_ day: String) -> String { "choreganize-backup-\(day).json" }

    @Test func pruningKeepsNewestSevenByName() {
        // Deliberately shuffled input, including a year/month rollover — the
        // zero-padded format must sort chronologically regardless of order given.
        let files = [
            name("2026-01-03"), name("2025-12-30"), name("2026-01-07"),
            name("2026-01-01"), name("2026-01-05"), name("2025-12-29"),
            name("2026-01-06"), name("2026-01-02"), name("2026-01-04"),
            name("2025-12-31"),
        ]
        let pruned = AutoBackupPolicy.filesToPrune(files)
        #expect(Set(pruned) == [name("2025-12-31"), name("2025-12-30"), name("2025-12-29")])
    }

    @Test func pruningIsANoOpAtOrUnderTheLimit() {
        let seven = (1...7).map { name(String(format: "2026-01-%02d", $0)) }
        #expect(AutoBackupPolicy.filesToPrune(seven).isEmpty)
        #expect(AutoBackupPolicy.filesToPrune([]).isEmpty)
    }

    @Test func pruningNeverSelectsForeignFiles() {
        // Other documents living next to the backups must never be deleted,
        // no matter how many backups exceed the limit.
        let foreign = ["notes.txt", "Choreganize-Backup-2026-01-01", "backup.json"]
        let backups = (1...9).map { name(String(format: "2026-01-%02d", $0)) }
        let pruned = AutoBackupPolicy.filesToPrune(foreign + backups)
        #expect(pruned.count == 2)
        #expect(pruned.allSatisfy { $0.hasPrefix(AutoBackupPolicy.filePrefix) })
    }

    // MARK: Filename format

    @Test func filenameMatchesExpectedFormat() {
        let generated = AutoBackupPolicy.filename(for: now)
        #expect(generated.hasPrefix("choreganize-backup-"))
        #expect(generated.hasSuffix(".json"))
        // choreganize-backup-YYYY-MM-DD.json is exactly 34 characters.
        #expect(generated.count == 34)
    }

    @Test func filenameRoundTripsToSameCalendarDay() throws {
        let parsed = try #require(AutoBackupPolicy.date(fromFilename: AutoBackupPolicy.filename(for: now)))
        #expect(Calendar.current.isDate(parsed, inSameDayAs: now))
    }

    @Test func foreignFilenamesDoNotParse() {
        #expect(AutoBackupPolicy.date(fromFilename: "notes.txt") == nil)
        #expect(AutoBackupPolicy.date(fromFilename: "choreganize-backup-.json") == nil)
        #expect(AutoBackupPolicy.date(fromFilename: "choreganize-backup-not-a-date.json") == nil)
    }
}
