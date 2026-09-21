//
//  InsightsMathTests.swift
//  ChoreganizeTests
//
//  CG-21 / #103 + CG-22 / #104 — Insights aggregation: completion-rate math
//  over seeded in-memory Core Data, heatmap bucketing boundaries, per-room /
//  per-frequency grouping, and streak-reuse sanity (Insights must score
//  streaks exactly as the calendar's own machinery does).
//

import Testing
import CoreData
import Foundation
@testable import Choreganize

struct InsightsMathTests {

    private let cal = Calendar.current
    private func day(_ offset: Int) -> Date {
        cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: Date()))!
    }

    // MARK: - Completion rate (CG-21 / #103)

    @Test func completionRateCountsCompletedVsDue() throws {
        let stack = CoreDataStack(inMemory: true)
        let ctx = stack.newBackgroundContext()
        try ctx.performAndWait {
            // Daily chore, well older than the window: due every one of the 7 days.
            let chore = CDChore.make(in: ctx, name: "Dishes", isDaily: true, createdDate: day(-10))
            try ctx.save()
            chore.recordCompletion(on: day(0), by: nil, in: ctx)
            chore.recordCompletion(on: day(-1), by: nil, in: ctx)
            chore.recordCompletion(on: day(-3), by: nil, in: ctx)

            let stats = InsightsMath.completionStats(chores: [chore], lastDays: 7)
            #expect(stats.due == 7)
            #expect(stats.completed == 3)
            #expect(stats.percent == 43)   // 3/7 rounded
        }
    }

    @Test func creationDateBoundsDueDays() throws {
        // The calendar's #85 rule via Scheduling/CalendarMarks reuse: a chore
        // created mid-window only counts from its creation day.
        let stack = CoreDataStack(inMemory: true)
        let ctx = stack.newBackgroundContext()
        try ctx.performAndWait {
            let chore = CDChore.make(in: ctx, name: "Vacuum", isDaily: true, createdDate: day(-2))
            try ctx.save()
            let stats = InsightsMath.completionStats(chores: [chore], lastDays: 7)
            #expect(stats.due == 3)   // day -2, -1, 0
            #expect(stats.completed == 0)
        }
    }

    @Test func emptyWindowIsZeroNotNaN() {
        let stats = InsightsMath.completionStats(chores: [], lastDays: 7)
        #expect(stats.due == 0)
        #expect(stats.completed == 0)
        #expect(stats.ratio == 0)
        #expect(stats.percent == 0)
    }

    // MARK: - Heatmap bucketing (CG-22 / #104)

    @Test func heatmapBucketBoundaries() {
        // Nothing due (incl. days before any chore existed) → empty cell.
        #expect(InsightsMath.heatmapBucket(completed: 0, total: 0) == nil)
        // Due but nothing done → 0.
        #expect(InsightsMath.heatmapBucket(completed: 0, total: 3) == 0)
        // Partials split at 1/3 and 2/3.
        #expect(InsightsMath.heatmapBucket(completed: 1, total: 4) == 1)   // 0.25
        #expect(InsightsMath.heatmapBucket(completed: 1, total: 3) == 1)   // exactly 1/3
        #expect(InsightsMath.heatmapBucket(completed: 2, total: 4) == 2)   // 0.5
        #expect(InsightsMath.heatmapBucket(completed: 2, total: 3) == 2)   // exactly 2/3
        #expect(InsightsMath.heatmapBucket(completed: 3, total: 4) == 3)   // 0.75
        // 100% → 4, even for a single chore.
        #expect(InsightsMath.heatmapBucket(completed: 4, total: 4) == 4)
        #expect(InsightsMath.heatmapBucket(completed: 1, total: 1) == 4)
    }

    @Test func yearHeatmapEmptyBeforeChoresExisted() throws {
        let stack = CoreDataStack(inMemory: true)
        let ctx = stack.newBackgroundContext()
        try ctx.performAndWait {
            let chore = CDChore.make(in: ctx, name: "Trash", isDaily: true, createdDate: day(-2))
            try ctx.save()
            chore.recordCompletion(on: day(-1), by: nil, in: ctx)

            let map = InsightsMath.yearHeatmap(chores: [chore], days: 5)
            #expect(map.count == 5)
            #expect(map.map(\.date) == [day(-4), day(-3), day(-2), day(-1), day(0)])
            #expect(map[0].bucket == nil)   // before the chore existed
            #expect(map[1].bucket == nil)
            #expect(map[2].bucket == 0)     // due, nothing done
            #expect(map[3].bucket == 4)     // fully done
            #expect(map[4].bucket == 0)     // today, not done yet
        }
    }

    // MARK: - Per-room grouping (CG-21 / #103)

    @Test func roomBreakdownGroupsByArea() throws {
        let stack = CoreDataStack(inMemory: true)
        let ctx = stack.newBackgroundContext()
        try ctx.performAndWait {
            let kitchen = CDArea.make(in: ctx, name: "Kitchen")
            let bath = CDArea.make(in: ctx, name: "Bathroom")
            let dishes = CDChore.make(in: ctx, name: "Dishes", isDaily: true, createdDate: day(-3))
            dishes.area = kitchen
            let scrub = CDChore.make(in: ctx, name: "Scrub tub", isDaily: true, createdDate: day(-3))
            scrub.area = bath
            let homeless = CDChore.make(in: ctx, name: "Water plants", isDaily: true, createdDate: day(-3))
            try ctx.save()
            dishes.recordCompletion(on: day(-1), by: nil, in: ctx)
            dishes.recordCompletion(on: day(-2), by: nil, in: ctx)

            let rooms = InsightsMath.roomBreakdown(chores: [dishes, scrub, homeless], lastDays: 30)
            #expect(rooms.count == 3)

            let byName = Dictionary(uniqueKeysWithValues: rooms.map { ($0.name, $0) })
            #expect(byName["Kitchen"]?.due == 4)        // days -3...0
            #expect(byName["Kitchen"]?.completed == 2)
            #expect(byName["Bathroom"]?.due == 4)
            #expect(byName["Bathroom"]?.completed == 0)
            // A chore with no CDArea lands in the fallback bucket.
            #expect(byName[InsightsMath.noRoomLabel]?.due == 4)
        }
    }

    // MARK: - Per-frequency grouping (CG-21 / #103)

    @Test func frequencyBreakdownBucketsDailyAndScheduled() throws {
        let stack = CoreDataStack(inMemory: true)
        let ctx = stack.newBackgroundContext()
        try ctx.performAndWait {
            let daily = CDChore.make(in: ctx, name: "Dishes", isDaily: true, createdDate: day(-7))
            // Weekly on today's weekday, created a week ago → due on day -7 and day 0.
            let weekly = CDChore.make(in: ctx, name: "Mop", isDaily: false,
                                      frequency: .weekly, assignedDay: .today, createdDate: day(-7))
            try ctx.save()
            weekly.recordCompletion(on: day(0), by: nil, in: ctx)

            let buckets = InsightsMath.frequencyBreakdown(chores: [daily, weekly], lastDays: 30)
            #expect(buckets.map(\.name) == ["Daily", "Weekly"])   // fixed schedule order

            let byName = Dictionary(uniqueKeysWithValues: buckets.map { ($0.name, $0) })
            #expect(byName["Daily"]?.due == 8)          // days -7...0
            #expect(byName["Daily"]?.completed == 0)
            #expect(byName["Weekly"]?.due == 2)
            #expect(byName["Weekly"]?.completed == 1)
        }
    }

    // MARK: - Streak reuse sanity (CG-21 / #103)

    @Test func streakSummaryMatchesCalendarMachinery() throws {
        let stack = CoreDataStack(inMemory: true)
        let ctx = stack.newBackgroundContext()
        try ctx.performAndWait {
            let chore = CDChore.make(in: ctx, name: "Dishes", isDaily: true, createdDate: day(-5))
            try ctx.save()
            // Perfect on the last two *past* days; today incomplete (the streak
            // must survive an in-progress today — anchored to yesterday).
            chore.recordCompletion(on: day(-2), by: nil, in: ctx)
            chore.recordCompletion(on: day(-1), by: nil, in: ctx)

            let summary = InsightsMath.streakSummary(scopedChores: [chore], scopedLocks: [])
            #expect(summary.current == 2)
            #expect(summary.longest == 2)

            // Reuse sanity: identical to composing the calendar's own pieces.
            let direct = CalendarStreaks.summary(
                for: CalendarStreaks.perfectDays(scopedChores: [chore], scopedLocks: []))
            #expect(summary == direct)
        }
    }

    // MARK: - Month summary (CG-22 / #104)

    @Test func monthSummaryCoversElapsedDaysAndPicksTopRoom() throws {
        let stack = CoreDataStack(inMemory: true)
        let ctx = stack.newBackgroundContext()
        try ctx.performAndWait {
            // Created today so the numbers are month-boundary-proof: exactly
            // one due day (today) no matter what date the suite runs on.
            let kitchen = CDArea.make(in: ctx, name: "Kitchen")
            let chore = CDChore.make(in: ctx, name: "Dishes", isDaily: true, createdDate: day(0))
            chore.area = kitchen
            try ctx.save()
            chore.recordCompletion(on: day(0), by: nil, in: ctx)

            let summary = InsightsMath.monthSummary(chores: [chore], locks: [])
            #expect(summary.stats.due == 1)
            #expect(summary.stats.completed == 1)
            #expect(summary.stats.percent == 100)
            #expect(summary.topRoom == "Kitchen")
            // One bucket per elapsed day of the month, today last and fully green.
            let dayOfMonth = cal.component(.day, from: day(0))
            #expect(summary.dayBuckets.count == dayOfMonth)
            #expect(summary.dayBuckets.last == 4)
            // Days before the chore existed are empty cells.
            if dayOfMonth > 1 {
                #expect(summary.dayBuckets[0] == nil)
            }
        }
    }
}
