import WidgetKit
import SwiftUI

/// Renders the published snapshot. Read-only for now — tapping opens the app.
/// (Interactive completion via App Intents is a deferred follow-up; it needs the
/// widget to write back into the shared store.)
struct TodayChoresView: View {
    var entry: TodayChoresEntry

    private var snapshot: ChoreWidgetSnapshot { entry.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if snapshot.items.isEmpty {
                Spacer(minLength: 0)
                Text("No chores today")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer(minLength: 0)
            } else {
                ForEach(snapshot.items.prefix(4)) { item in
                    Label {
                        Text(item.name)
                            .font(.caption)
                            .strikethrough(item.isDone)
                            .lineLimit(1)
                    } icon: {
                        Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(item.isDone ? .green : .secondary)
                    }
                }
                if snapshot.items.count > 4 {
                    Text("+\(snapshot.items.count - 4) more")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Today").font(.headline)
            Spacer()
            Text(snapshot.remaining == 0 ? "All done" : "\(snapshot.remaining) left")
                .font(.caption.bold())
                .foregroundStyle(snapshot.remaining == 0 ? .green : .secondary)
        }
    }
}
