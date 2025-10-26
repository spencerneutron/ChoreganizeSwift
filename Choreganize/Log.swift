import Foundation
import os

public enum LogLevel: Int, CaseIterable {
    case error = 0
    case warning = 1
    case info = 2
    case debug = 3
    case trace = 4
}

public enum LogCategory: String, CaseIterable {
    case app, model, cloud, persistence, push
}

public actor LogBuffer {
    public struct Entry {
        public let date: Date
        public let level: LogLevel
        public let category: LogCategory
        public let message: String
    }

    private var maxEntries: Int
    private var entries: [Entry] = []

    public init(maxEntries: Int = 500) {
        self.maxEntries = maxEntries
    }

    public func append(date: Date = Date(), level: LogLevel, category: LogCategory, message: String) {
        entries.append(Entry(date: date, level: level, category: category, message: message))
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    public func snapshot() -> [String] {
        let formatter = ISO8601DateFormatter()
        return entries.map {
            "\(formatter.string(from: $0.date)) [\($0.level)] [\($0.category.rawValue)] \($0.message)"
        }
    }
}

public struct Log {
    public static var currentLevel: LogLevel = .info
    public static let buffer = LogBuffer(maxEntries: 500)

    private static let appLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app", category: "app")
    private static let modelLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app", category: "model")
    private static let cloudLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app", category: "cloud")
    private static let persistenceLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app", category: "persistence")
    private static let pushLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app", category: "push")

    public static func setLevel(_ level: LogLevel) { currentLevel = level }

    private static func logger(for category: LogCategory) -> Logger {
        switch category {
        case .app: return appLogger
        case .model: return modelLogger
        case .cloud: return cloudLogger
        case .persistence: return persistenceLogger
        case .push: return pushLogger
        }
    }

    // Core logging
    public static func log(_ level: LogLevel, _ message: @autoclosure () -> String, category: LogCategory = .app) {
        guard level.rawValue <= currentLevel.rawValue else { return }
        let msg = message()
        let logger = logger(for: category)

        switch level {
        case .error:
            logger.error("\(msg, privacy: .public)")
        case .warning:
            logger.warning("\(msg, privacy: .public)")
        case .info:
            logger.info("\(msg, privacy: .public)")
        case .debug, .trace:
            logger.debug("\(msg, privacy: .public)")
        }

        Task { await buffer.append(level: level, category: category, message: msg) }
    }

    // Convenience helpers
    public static func error(_ message: @autoclosure () -> String, category: LogCategory = .app) { log(.error, message(), category: category) }
    public static func warning(_ message: @autoclosure () -> String, category: LogCategory = .app) { log(.warning, message(), category: category) }
    public static func info(_ message: @autoclosure () -> String, category: LogCategory = .app) { log(.info, message(), category: category) }
    public static func debug(_ message: @autoclosure () -> String, category: LogCategory = .app) { log(.debug, message(), category: category) }
    public static func trace(_ message: @autoclosure () -> String, category: LogCategory = .app) { log(.trace, message(), category: category) }

    // Retrieve buffer snapshot
    public static func bufferSnapshot() async -> [String] { await buffer.snapshot() }
}
