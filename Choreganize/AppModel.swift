import Foundation
import SwiftUI
import os

/// App-level coordinator. Since the Core Data + CloudKit re-platform, the data
/// itself lives in Core Data and is read by the views via `@FetchRequest`; this
/// object now only carries cross-cutting UI state (sync status, errors, banners).
@MainActor
final class AppModel: ObservableObject {
    static let schemaVersion: Int = 1

    // MARK: - Banner messaging
    enum BannerStyle {
        case info, success, warning, error
    }

    struct BannerMessage: Identifiable, Equatable {
        let id = UUID()
        let title: String?
        let message: String
        let style: BannerStyle
        let actionTitle: String?
        let action: (() -> Void)?
        let duration: TimeInterval

        init(title: String? = nil, message: String, style: BannerStyle = .info, actionTitle: String? = nil, action: (() -> Void)? = nil, duration: TimeInterval = 4.0) {
            self.title = title
            self.message = message
            self.style = style
            self.actionTitle = actionTitle
            self.action = action
            self.duration = duration
        }

        static func == (lhs: BannerMessage, rhs: BannerMessage) -> Bool { lhs.id == rhs.id }
    }

    @Published var isSyncing: Bool = false
    @Published var lastError: String?
    @Published var currentBanner: BannerMessage?

    private var bannerQueue: [BannerMessage] = []
    private var bannerTask: Task<Void, Never>?

    init() {}

    // MARK: - Banner controls
    func showBanner(title: String? = nil,
                    message: String,
                    style: BannerStyle = .info,
                    actionTitle: String? = nil,
                    action: (() -> Void)? = nil,
                    duration: TimeInterval = 4.0) {
        let banner = BannerMessage(title: title, message: message, style: style, actionTitle: actionTitle, action: action, duration: duration)
        if currentBanner == nil {
            present(banner)
        } else {
            bannerQueue.append(banner)
        }
    }

    func dismissBanner(triggerAction: Bool = false) {
        if triggerAction { currentBanner?.action?() }
        currentBanner = nil
        bannerTask?.cancel()
        bannerTask = nil
        if let next = bannerQueue.first {
            bannerQueue.removeFirst()
            present(next)
        }
    }

    private func present(_ banner: BannerMessage) {
        currentBanner = banner
        bannerTask?.cancel()
        bannerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: UInt64((banner.duration) * 1_000_000_000))
                self.dismissBanner()
            } catch { /* cancelled */ }
        }
    }

    // MARK: - Legacy persistence shape
    /// The JSON shape written by pre-Core-Data versions. Retained only so
    /// `JSONImporter` (and the dormant `SharedCloudKitController`, pending its
    /// Phase 3 replacement) can decode legacy data. Not used as a live store.
    struct SavedState: Codable {
        var chores: [Chore]
        var areas: [Area]
        var completions: [Completion]
        var lockedDays: Set<Date> = []
        var schemaVersion: Int?

        enum CodingKeys: String, CodingKey {
            case chores, areas, completions, lockedDays, schemaVersion
        }

        init(chores: [Chore], areas: [Area], completions: [Completion], lockedDays: Set<Date> = [], schemaVersion: Int? = AppModel.schemaVersion) {
            self.chores = chores
            self.areas = areas
            self.completions = completions
            self.lockedDays = lockedDays
            self.schemaVersion = schemaVersion
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            chores = try container.decodeIfPresent([Chore].self, forKey: .chores) ?? []
            areas = try container.decodeIfPresent([Area].self, forKey: .areas) ?? []
            completions = try container.decodeIfPresent([Completion].self, forKey: .completions) ?? []
            lockedDays = try container.decodeIfPresent(Set<Date>.self, forKey: .lockedDays) ?? []
            schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(chores, forKey: .chores)
            try container.encode(areas, forKey: .areas)
            try container.encode(completions, forKey: .completions)
            try container.encode(lockedDays, forKey: .lockedDays)
            try container.encode(schemaVersion ?? AppModel.schemaVersion, forKey: .schemaVersion)
        }
    }
}
