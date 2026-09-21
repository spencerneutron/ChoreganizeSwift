import SwiftUI
import CoreData

/// The menu-bar extra: today's due chores as a one-click checklist, split into
/// Personal and Household sections — the Mac-native counterpart of the iOS
/// widget. Completing here goes through the same `recordCompletion` path as
/// every other surface, so sync, attribution, and the Dock badge all follow.
struct MenuBarTodayView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var model: AppModel
    @FetchRequest(fetchRequest: displayChoresFetchRequest()) private var chores: FetchedResults<CDChore>
    /// Redraw ticker: completions from this very list don't otherwise
    /// invalidate the fetch (completion state is derived, not fetched).
    @State private var refreshTick = 0

    private struct TodaySection: Identifiable {
        let id: String
        let title: String
        let chores: [CDChore]
    }

    private var sections: [TodaySection] {
        let today = Date()
        var out: [TodaySection] = []
        let personal = Scheduling.chores(Array(chores).inScope(nil), for: today)
        if !personal.isEmpty {
            out.append(TodaySection(id: "personal", title: AppScope.solo.title, chores: personal))
        }
        if let household = model.resolvedHousehold {
            let members = Scheduling.chores(Array(chores).inScope(household), for: today)
            if !members.isEmpty {
                out.append(TodaySection(id: "household", title: household.name ?? "Household", chores: members))
            }
        }
        return out
    }

    var body: some View {
        let allSections = sections
        let remaining = allSections.flatMap(\.chores).filter { !$0.isCompleted(on: Date()) }.count

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Today")
                    .font(.headline)
                Spacer()
                Text(Date().formatted(.dateTime.weekday(.wide).month().day()))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            if allSections.isEmpty || remaining == 0 {
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.title2)
                        .foregroundStyle(.green)
                    Text(allSections.isEmpty ? "Nothing due today" : "All done for today")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            }

            if !allSections.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(allSections) { section in
                            if allSections.count > 1 {
                                Text(section.title)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 14)
                                    .padding(.top, 8)
                            }
                            ForEach(section.chores, id: \.objectID) { chore in
                                choreRow(chore)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 340)
            }

            Divider()

            HStack {
                Button("Open Choreganize") {
                    openWindow(id: "main")
                    NSApplication.shared.activate()
                }
                .buttonStyle(.plain)
                .font(.subheadline)
                Spacer()
                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
                .help("Settings")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 320)
        .id(refreshTick)
    }

    @ViewBuilder
    private func choreRow(_ chore: CDChore) -> some View {
        let done = chore.isCompleted(on: Date())
        Button {
            if done {
                chore.removeCompletion(on: Date(), in: context)
            } else {
                chore.recordCompletion(on: Date(), in: context)
            }
            refreshTick += 1
            let badgeHousehold = model.resolvedHousehold
            Task { await NotificationManager.refreshBadge(using: context, household: badgeHousehold) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(done ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                VStack(alignment: .leading, spacing: 0) {
                    Text(chore.name ?? "Untitled")
                        .strikethrough(done, color: .secondary)
                        .foregroundStyle(done ? .secondary : .primary)
                        .lineLimit(1)
                    if let room = chore.area?.name, !room.isEmpty {
                        Text(room)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
