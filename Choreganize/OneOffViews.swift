import SwiftUI
import CoreData

// CG-27 / #128 — the one-offs UI: the first section of each upcoming day's Work
// list (or, as a DEBUG A/B, a shelf pinned above the day pager), the round
// checkbox with its grace period and poof, the add/edit sheet, and the buried
// "Limit one-offs to 3" setting.

// MARK: - DEBUG A/B

/// Where one-offs live on the Work view. In the list is the default (the user's
/// picture); the pinned shelf is a DEBUG A/B (Hub ▸ Developer, `-oneOffPlacement`).
enum OneOffPlacement: String, CaseIterable, Identifiable {
    case inList, shelf
    var id: String { rawValue }
    var title: String {
        switch self {
        case .inList: "First section of each day (default)"
        case .shelf:  "Pinned shelf above the days"
        }
    }

    static var current: OneOffPlacement {
        #if DEBUG
        OneOffPlacement(rawValue: UserDefaults.standard.string(forKey: SettingsKeys.oneOffPlacement) ?? "") ?? .inList
        #else
        .inList
        #endif
    }
}

/// How one-offs set themselves apart from chores (DEBUG A/B, `-oneOffLook`).
enum OneOffLook: String, CaseIterable, Identifiable {
    case tint, note
    var id: String { rawValue }
    var title: String {
        switch self {
        case .tint: "Accent tint (default)"
        case .note: "Sticky note"
        }
    }

    /// The card fill behind one-off rows.
    var fill: Color {
        switch self {
        case .tint: Color.accentColor.opacity(0.10)
        case .note: Color(red: 1.0, green: 0.84, blue: 0.25).opacity(0.22)
        }
    }

    /// The header icon's color.
    var accent: Color {
        switch self {
        case .tint: .accentColor
        case .note: .orange
        }
    }
}

// MARK: - Row

/// A one-off: a round checkbox (chores use switches), the title and an assignee
/// chip. Checking it starts a short grace period (tap again to cancel, the
/// Reminders pattern), then it poofs away and is deleted.
struct OneOffRow: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var oneOff: CDOneOff
    var onEdit: () -> Void

    @ObservedObject private var completers = CompleterDirectory.shared
    @ObservedObject private var entitlements = EntitlementStore.shared
    @State private var pending = false
    @State private var poofing = false
    @State private var grace: Task<Void, Never>?

    static let graceDelay: Duration = .milliseconds(1500)

    private var title: String { oneOff.title ?? "Untitled" }

    /// "You" for the current user, otherwise the member's name (as on chores).
    private var assigneeTag: String? {
        guard let assignee = oneOff.assignee else { return nil }
        if oneOff.isAssignedToCurrentUser { return "You" }
        return completers.namesByID[assignee] ?? "Member"
    }

    private var canAssign: Bool {
        oneOff.household != nil && Entitlements.isPlus(for: oneOff.household)
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: toggle) {
                Image(systemName: pending ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(pending ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(pending ? "Undo completing \(title)" : "Complete \(title)")
            .accessibilityIdentifier("oneOff.check.\(title)")

            Text(title)
                .fontWeight(.medium)
                .strikethrough(pending)
                .foregroundStyle(pending ? Color.secondary : Color.primary)
                .lineLimit(2)
            Spacer(minLength: 8)
            if let tag = assigneeTag {
                Text(tag)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .scaleEffect(poofing && !reduceMotion ? 1.08 : 1, anchor: .leading)
        .blur(radius: poofing && !reduceMotion ? 5 : 0)
        .opacity(poofing ? 0 : 1)
        .overlay(alignment: .leading) {
            if poofing && !reduceMotion {
                PoofBurst()
                    .frame(width: 28, height: 28)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if !pending { onEdit() } }
        .sensoryFeedback(.success, trigger: poofing) { _, isPoofing in isPoofing }
        .contextMenu {
            Button("Edit…", systemImage: "pencil", action: onEdit)
            if canAssign {
                Menu("Assign To", systemImage: "person.crop.circle") {
                    Button("Anyone") { assign(nil) }
                    if let me = CompleterIdentity.cachedID {
                        Button("Me") { assign(me) }
                    }
                    ForEach(completers.namesByID.filter { $0.key != CompleterIdentity.cachedID }
                        .sorted { $0.value < $1.value }, id: \.key) { member in
                        Button(member.value) { assign(member.key) }
                    }
                }
            }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) {
                withAnimation { OneOffOps.complete(oneOff, in: context) }
            }
        }
    }

    private func toggle() {
        if pending {
            grace?.cancel()
            withAnimation(.snappy) { pending = false }
            return
        }
        withAnimation(.snappy) { pending = true }
        grace = Task { @MainActor in
            try? await Task.sleep(for: Self.graceDelay)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.4)) { poofing = true }
            try? await Task.sleep(for: .milliseconds(420))
            guard !Task.isCancelled, !oneOff.isDeleted, oneOff.managedObjectContext != nil else { return }
            withAnimation { OneOffOps.complete(oneOff, in: context) }
        }
    }

    private func assign(_ member: String?) {
        OneOffOps.update(oneOff, title: "", assignee: member, isPlus: canAssign, in: context)
    }
}

/// A small puff of particles thrown out from the checkbox as a one-off disappears.
struct PoofBurst: View {
    @State private var spread = false
    private let sizes: [CGFloat] = [7, 5, 8, 4, 6, 5, 7, 4, 6, 5]

    var body: some View {
        ZStack {
            ForEach(sizes.indices, id: \.self) { index in
                let angle = Double(index) / Double(sizes.count) * 2 * .pi + 0.35
                let reach: CGFloat = index.isMultiple(of: 2) ? 26 : 18
                Circle()
                    .fill(index.isMultiple(of: 3) ? Color.secondary.opacity(0.45) : Color.accentColor.opacity(0.6))
                    .frame(width: sizes[index], height: sizes[index])
                    .offset(x: spread ? cos(angle) * reach : cos(angle) * 4,
                            y: spread ? sin(angle) * reach : sin(angle) * 4)
                    .scaleEffect(spread ? 0.3 : 1)
                    .opacity(spread ? 0 : 1)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.45)) { spread = true }
        }
    }
}

// MARK: - Section (in the day list)

/// The one-offs section at the top of an upcoming day's list. Carries the day's
/// date header when it's the first section.
struct OneOffsSection: View {
    let oneOffs: [CDOneOff]
    var dateHeader: String?
    let canAdd: Bool
    let onAdd: () -> Void
    let onEdit: (CDOneOff) -> Void

    @AppStorage(SettingsKeys.oneOffsExpanded) private var expanded = false
    #if DEBUG
    @AppStorage(SettingsKeys.oneOffLook) private var lookRaw = OneOffLook.tint.rawValue
    private var look: OneOffLook { OneOffLook(rawValue: lookRaw) ?? .tint }
    #else
    private let look = OneOffLook.tint
    #endif

    var body: some View {
        let (shown, hidden) = OneOffLimit.collapsed(oneOffs, expanded: expanded)
        Section {
            ForEach(shown, id: \.objectID) { oneOff in
                OneOffRow(oneOff: oneOff) { onEdit(oneOff) }
                    .listRowBackground(RowFill(look: look))
            }
            if hidden > 0 || (expanded && oneOffs.count > OneOffLimit.count) {
                Button(hidden > 0 ? "Show all (\(oneOffs.count))" : "Show fewer") {
                    withAnimation { expanded.toggle() }
                }
                .font(.subheadline)
                .listRowBackground(RowFill(look: look))
            }
        } header: {
            VStack(alignment: .leading, spacing: 4) {
                if let dateHeader {
                    Text(dateHeader).font(.headline).textCase(nil).foregroundStyle(Color.primary)
                }
                OneOffsHeader(look: look, canAdd: canAdd, onAdd: onAdd)
            }
        } footer: {
            // The Work list sets no section spacing of its own on upcoming days (the
            // Quick Add slots make the gaps); keep the chores card off this one.
            Color.clear.frame(height: 6)
        }
    }

    /// The card fill behind one-off rows: the look's tint over the normal card. The
    /// Mac's inset list has no cards, so the band lines up with the row separators.
    private struct RowFill: View {
        let look: OneOffLook
        var body: some View {
            ZStack {
                Color.compatCardBackground
                look.fill
            }
            #if os(macOS)
            .padding(.horizontal, 12)
            #endif
        }
    }
}

/// "One-offs" with its pin, and ＋ while the scope is under its limit.
struct OneOffsHeader: View {
    let look: OneOffLook
    let canAdd: Bool
    let onAdd: () -> Void

    var body: some View {
        HStack {
            Label {
                Text("One-offs")
            } icon: {
                Image(systemName: "pin.fill").foregroundStyle(look.accent)
            }
            Spacer()
            if canAdd {
                Button(action: onAdd) {
                    Image(systemName: "plus.circle.fill")
                        .font(.body)
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("New one-off")
                .accessibilityIdentifier("oneOff.add")
            }
        }
    }
}

// MARK: - Shelf (DEBUG A/B: pinned above the day pager)

/// The same rows as a floating card pinned above the day pager. Hidden when empty.
struct OneOffShelf: View {
    @EnvironmentObject private var model: AppModel
    @FetchRequest(fetchRequest: oneOffsFetchRequest()) private var oneOffs: FetchedResults<CDOneOff>
    @FetchRequest(sortDescriptors: []) private var households: FetchedResults<CDHousehold>
    @AppStorage(SettingsKeys.oneOffsUnlimitedPersonal) private var personalUnlimited = false
    @AppStorage(SettingsKeys.oneOffsExpanded) private var expanded = false
    @State private var sheet: OneOffEditor.Mode?
    #if DEBUG
    @AppStorage(SettingsKeys.oneOffLook) private var lookRaw = OneOffLook.tint.rawValue
    private var look: OneOffLook { OneOffLook(rawValue: lookRaw) ?? .tint }
    #else
    private let look = OneOffLook.tint
    #endif

    var body: some View {
        let scoped = Array(oneOffs).inScope(model.activeHousehold)
        let unlimited = OneOffLimit.isUnlimited(household: model.activeHousehold, personalUnlimited: personalUnlimited)
        let (shown, hidden) = OneOffLimit.collapsed(scoped, expanded: expanded)
        if !scoped.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                OneOffsHeader(look: look, canAdd: OneOffLimit.canAdd(existing: scoped.count, unlimited: unlimited)) {
                    sheet = .new
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)
                ForEach(Array(shown.enumerated()), id: \.element.objectID) { index, oneOff in
                    if index > 0 { Divider().padding(.leading, 40) }
                    OneOffRow(oneOff: oneOff) { sheet = .edit(oneOff) }
                }
                if hidden > 0 || (expanded && scoped.count > OneOffLimit.count) {
                    Divider().padding(.leading, 40)
                    Button(hidden > 0 ? "Show all (\(scoped.count))" : "Show fewer") {
                        withAnimation { expanded.toggle() }
                    }
                    .font(.subheadline)
                    .buttonStyle(.borderless)
                    .padding(.vertical, 8)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(look.fill, in: .rect(cornerRadius: 22, style: .continuous))
            .shelfGlass()
            .padding(.horizontal, 32)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .transition(.move(edge: .top).combined(with: .opacity))
            .sheet(item: $sheet) { mode in
                OneOffEditor(mode: mode)
            }
        }
    }
}

private extension View {
    /// Liquid Glass on 26+, a material card on 18.
    @ViewBuilder
    func shelfGlass() -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: 22, style: .continuous))
        } else {
            self.background(.regularMaterial, in: .rect(cornerRadius: 22, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        }
    }
}

// MARK: - Editor

/// The title (and, in a household, the assignee) of a one-off. Shared by the
/// one-off editor and New Chore's One-off mode.
struct OneOffFormFields: View {
    @Binding var title: String
    @Binding var assignee: String?
    var household: CDHousehold?
    /// Adding would pass the scope's limit.
    var atLimit = false
    var titleFocus: FocusState<Bool>.Binding?

    var body: some View {
        Section {
            if let titleFocus {
                TextField("Title", text: $title)
                    .focused(titleFocus)
                    .submitLabel(.done)
                    .accessibilityIdentifier("oneOff.title")
            } else {
                TextField("Title", text: $title)
                    .accessibilityIdentifier("oneOff.title")
            }
        } footer: {
            if atLimit {
                Text(OneOffLimit.refusal)
                    .foregroundStyle(.orange)
            } else {
                Text("Stays at the top of the Work view until you check it off. One-offs don't repeat, have no reminders and aren't counted in your stats.")
            }
        }
        if household != nil {
            AssigneeSection(assignee: $assignee, household: household, noun: "one-off")
        }
    }
}

/// New or edit one-off sheet: the shelf's ＋, a row tap, and the Mac's
/// File ▸ New One-Off….
struct OneOffEditor: View {
    enum Mode: Identifiable {
        case new
        case edit(CDOneOff)
        var id: String {
            switch self {
            case .new: "new"
            case .edit(let oneOff): oneOff.objectID.uriRepresentation().absoluteString
            }
        }
    }

    let mode: Mode

    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @FetchRequest(fetchRequest: oneOffsFetchRequest()) private var oneOffs: FetchedResults<CDOneOff>
    @AppStorage(SettingsKeys.oneOffsUnlimitedPersonal) private var personalUnlimited = false
    @State private var title = ""
    @State private var assignee: String?
    @State private var loaded = false
    @FocusState private var titleFocused: Bool

    private var editing: CDOneOff? {
        if case .edit(let oneOff) = mode { return oneOff }
        return nil
    }

    private var household: CDHousehold? { editing?.household ?? model.activeHousehold }

    private var atLimit: Bool {
        guard editing == nil else { return false }
        let existing = Array(oneOffs).inScope(model.activeHousehold).count
        let unlimited = OneOffLimit.isUnlimited(household: model.activeHousehold, personalUnlimited: personalUnlimited)
        return !OneOffLimit.canAdd(existing: existing, unlimited: unlimited)
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !atLimit
    }

    var body: some View {
        NavigationStack {
            Form {
                OneOffFormFields(title: $title, assignee: $assignee, household: household,
                                 atLimit: atLimit, titleFocus: $titleFocused)
            }
            .formStyle(.grouped)
            .onSubmit { if canSave { save() } }
            .navigationTitle(editing == nil ? "New One-off" : "Edit One-off")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                title = editing?.title ?? ""
                assignee = editing?.assignee
            }
            .task {
                guard editing == nil else { return }
                try? await Task.sleep(for: .milliseconds(350))
                titleFocused = true
            }
        }
        .compatMediumLargeDetents()
    }

    private func save() {
        let isPlus = Entitlements.isPlus(for: household)
        if let editing {
            OneOffOps.update(editing, title: title, assignee: assignee, isPlus: isPlus, in: context)
        } else {
            let existing = Array(oneOffs).inScope(model.activeHousehold).count
            let unlimited = OneOffLimit.isUnlimited(household: model.activeHousehold, personalUnlimited: personalUnlimited)
            OneOffOps.add(title: title, assignee: assignee, household: model.activeHousehold,
                          existing: existing, unlimited: unlimited, isPlus: isPlus, in: context)
        }
        dismiss()
    }
}

// MARK: - Setting

/// Hub ▸ Work View and Mac Settings ▸ General ▸ Work View. In a household the
/// setting is synced for everyone; in Personal it's this device's.
struct OneOffLimitToggle: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(SettingsKeys.oneOffsUnlimitedPersonal) private var personalUnlimited = false

    var body: some View {
        if let household = model.activeHousehold {
            HouseholdToggle(household: household)
        } else {
            Toggle("Limit one-offs to 3", isOn: Binding(
                get: { !personalUnlimited },
                set: { personalUnlimited = !$0 }))
            .accessibilityIdentifier("oneOff.limitToggle")
        }
    }

    private struct HouseholdToggle: View {
        @ObservedObject var household: CDHousehold

        var body: some View {
            Toggle("Limit one-offs to 3", isOn: Binding(
                get: { !household.oneOffsUnlimited },
                set: { limited in
                    household.oneOffsUnlimited = !limited
                    try? household.managedObjectContext?.save()
                }))
            .accessibilityIdentifier("oneOff.limitToggle")
        }
    }
}
