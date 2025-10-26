import Foundation
import os

public enum LogLevel: Int, CaseIterable {
    case error = 0
    case warning = 1
    case info = 2
    case debug = 3
    case trace = 4
}

public actor LogBuffer {
    public struct Entry {
        public let date: Date
        public let level: LogLevel
        public let category: String
        public let message: String
    }

    private var maxEntries: Int
    private var entries: [Entry] = []

    public init(maxEntries: Int = 500) {
        self.maxEntries = maxEntries
    }

    public func append(date: Date = Date(), level: LogLevel, category: String, message: String) {
        entries.append(Entry(date: date, level: level, category: category, message: message))
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    public func snapshot() -> [String] {
        let formatter = ISO8601DateFormatter()
        return entries.map {
            "\(formatter.string(from: $0.date)) [\($0.level)] [\($0.category)] \($0.message)"
        }
    }
}

public struct Log {
    public static var currentLevel: LogLevel = .info
    public static let buffer = LogBuffer(maxEntries: 500)

    public static func setLevel(_ level: LogLevel) {
        currentLevel = level
    }

    public struct Category {
        public static let app = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app", category: "app")
        public static let model = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app", category: "model")
        public static let cloud = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app", category: "cloud")
        public static let persistence = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app", category: "persistence")
        public static let push = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app", category: "push")
    }

    // MARK: - Core logging

    public static func log(category: Logger, categoryName: String, level: LogLevel, _ message: @autoclosure () -> String) {
        guard level.rawValue <= currentLevel.rawValue else { return }
        let msg = message()

        switch level {
        case .error:
            category.error("\(msg, privacy: .public)")
        case .warning:
            category.warning("\(msg, privacy: .public)")
        case .info:
            category.info("\(msg, privacy: .public)")
        case .debug, .trace:
            // os.Logger has no trace method, use debug for both
            category.debug("\(msg, privacy: .public)")
        }

        Task {
            await buffer.append(level: level, category: categoryName, message: msg)
        }
    }

    // MARK: - Convenience overloads per category

    // app
    public static func error(_ category: Logger = Category.app, _ message: @autoclosure () -> String) {
        log(category: category, categoryName: "app", level: .error, message())
    }
    public static func warning(_ category: Logger = Category.app, _ message: @autoclosure () -> String) {
        log(category: category, categoryName: "app", level: .warning, message())
    }
    public static func info(_ category: Logger = Category.app, _ message: @autoclosure () -> String) {
        log(category: category, categoryName: "app", level: .info, message())
    }
    public static func debug(_ category: Logger = Category.app, _ message: @autoclosure () -> String) {
        log(category: category, categoryName: "app", level: .debug, message())
    }
    public static func trace(_ category: Logger = Category.app, _ message: @autoclosure () -> String) {
        log(category: category, categoryName: "app", level: .trace, message())
    }

    // model
    public static func error(_ category: Logger = Category.model, _ message: @autoclosure () -> String) {
        log(category: category, categoryName: "model", level: .error, message())
    }
    public static func warning(_ category: Logger = Category.model, _ message: @autoclosure () -> String) {
        log(category: category, categoryName: "model", level: .warning, message())
    }
    public static func info(_ category: Logger = Category.model, _ message: @autoclosure () -> String) {
        log(category: category, categoryName: "model", level: .info, message())
    }
    public static func debug(_ category: Logger = Category.model, _ message: @autoclosure () -> String) {
        log(category: category, categoryName: "model", level: .debug, message())
    }
    public static func trace(_ category: Logger = Category.model, _ message: @autoclosure () -> String) {
        log(category: category, categoryName: "model", level: .trace, message())
    }

    // cloud
    public static func error(_ category: Logger = Category.cloud, _ message: @autoclosure () -> String) {
        log(category: category, categoryName: "cloud", level: .error, message())
    }
    public static func warning(_ category: Logger = Category.cloud, _ message: @autoclosure () -> String) {
        log(category: category, categoryName: "cloud", level: .warning, message())
    }
    public static func info(_ category: Logger = Category.cloud, _ message: @autoclosure () -> String) {
        log(category: category, categoryName: "cloud", level: .info, message())
    }
    public static func debug(_ category: Logger = Category.cloud, _ message: @autoclosure () -> String) {
        log(category: category, categoryName: "cloud", level: .debug, message())
    }
    public static func trace(_ category: Logger = Category.cloud, _ message: @autoclosure () -> String) {
        log(category: category, categoryName: "cloud", level: .trace, message())
    }

    // persistence
    public static func error(_ category: Logger = Category.persistence, _ message: @autoclosure () -> String) {
        log(category: category, categoryName: "persistence", level: .error, message())
    }
    public static func warning(_ category: Logger = Category.persistence, _ message: @autoclosure () -> String) {
        log(category: category, categoryName: "persistence", level: .warning, message())
    }
    public static func info(_ category: Logger = Category.persistence, _ message: @autoclosure () -> String) {
        log(category: category, categoryName: "persistence", level: .info, message())
    }
    public static func debug(_ category: Logger = Category.persistence, _ message: @autoclosure () -> String) {
        log(category: category, categoryName: "persistence", level: .debug, message())
    }
    public static func trace(_ category: Logger = Category.persistence, _ message: @autoclosure () -> String) {
        log(category: category, categoryName: "persistence", level: .trace, message())
    }

    // push
    public static func error(_ category: Logger = Category.push, _ message: @autoclosure () -> String) {
        log(category: category, categoryName: "push", level: .error, message())
    }
    public static func warning(_ category: Logger = Category.push, _ message: @autoclosure () -> String) {
        log(category: category, categoryName: "push", level: .warning, message())
    }
    public static func info(_ category: Logger = Category.push, _ message: @autoclosure () -> String) {
        log(category: category, categoryName: "push", level: .info, message())
    }
    public static func debug(_ category: Logger = Category.push, _ message: @autoclosure () -> String) {
        log(category: category, categoryName: "push", level: .debug, message())
    }
    public static func trace(_ category: Logger = Category.push, _ message: @autoclosure () -> String) {
        log(category: category, categoryName: "push", level: .trace, message())
    }

    // MARK: - Retrieve buffer snapshot

    public static func bufferSnapshot() async -> [String] {
        await buffer.snapshot()
    }
}
