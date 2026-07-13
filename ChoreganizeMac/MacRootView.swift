import SwiftUI
import CoreData

/// The Mac window shell: a NavigationSplitView with the four surfaces in the
/// sidebar (Work / Calendar / Insights / Edit — same `AppMode` cases as the
/// iPhone's floating switcher), the scope/household picker below them, and the
/// shared surface views in the detail column. Banners ride a top inset, sync
/// state lives in the sidebar footer, and the Today hero card gives the
/// at-a-glance progress the widget provides on iOS.
struct MacRootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var ui: MacUIState
    @ObservedObject private var entitlements = EntitlementStore.shared
    @State private var showNewHousehold = false
    @State private var newHouseholdName = ""
    @State private var showingError = false
    @State private var householdPendingDelete: CDHousehold?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 210, ideal: 240)
        } detail: {
            detail
        }
        // Transient app banners (sync paused, migration offer, errors) — the
        // same queue AppModel drives on iOS, surfaced above the split view.
        .safeAreaInset(edge: .top) {
            if let banner = model.currentBanner {
                AppBannerView(banner: banner) { model.dismissBanner() }
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.currentBanner)
        .alert("Error", isPresented: $showingError, actions: {
            Button("OK", role: .cancel) { model.lastError = nil }
        }, message: {
            Text(model.lastError ?? "Unknown error")
        })
        .onChange(of: model.lastError) { _, newValue in
            showingError = newValue != nil
        }
        // A deep link targets a chore on the Work surface.
        .onChange(of: model.deepLinkChore) { _, target in
            if target != nil { ui.surface = .work }
        }
        .alert("Delete \u{201C}\(householdPendingDelete?.name ?? "Household")\u{201D}?",
               isPresented: Binding(
                   get: { householdPendingDelete != nil },
                   set: { if !$0 { householdPendingDelete = nil } }
               )) {
            Button("Delete", role: .destructive) {
                if let household = householdPendingDelete { deleteHousehold(household) }
                householdPendingDelete = nil
            }
            Button("Cancel", role: .cancel) { householdPendingDelete = nil }
        } message: {
            Text("This household is empty. Deleting removes it everywhere it syncs.")
        }
        .alert("New Household", isPresented: $showNewHousehold) {
            TextField("Name", text: $newHouseholdName)
            Button("Create") { model.createHousehold(named: newHouseholdName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Creates a separate household you can share independently.")
        }
        // CG-11 / #64: Personal→Household migration picker; the offer banner's
        // action presents it from anywhere, same as iOS.
        .sheet(isPresented: $model.showMigrationPicker) {
            MigrationPickerView()
                .environmentObject(model)
                .frame(minWidth: 440, minHeight: 420)
        }
        .sheet(isPresented: $ui.showPaywall) {
            PaywallView()
                .frame(minWidth: 440, minHeight: 560)
        }
        // ⌘N — the guided add wizard, one sheet per lens.
        .sheet(item: $ui.addFlowLens) { lens in
            NavigationStack { AddFlowFlowView(grouping: lens) }
                .environmentObject(model)
                .frame(minWidth: 480, minHeight: 520)
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: surfaceSelection) {
            Section {
                TodayHeroCard()
            }
            .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 8, trailing: 8))

            Section("Views") {
                ForEach(AppMode.allCases) { mode in
                    Label(mode.rawValue, systemImage: mode.systemImage)
                        .tag(mode)
                }
            }

            Section("Scope") {
                scopeRow(title: AppScope.solo.title, systemImage: AppScope.solo.systemImage,
                         checked: model.scope == .solo) {
                    model.setScope(.solo)
                }
                ForEach(model.allHouseholds, id: \.objectID) { household in
                    scopeRow(title: household.name ?? "Household",
                             systemImage: "person.2.fill",
                             checked: model.scope == .household && household == model.resolvedHousehold) {
                        model.setActiveHousehold(household)
                        model.setScope(.household)
                    }
                    // Cleanup affordance for stray EMPTY households (they
                    // accumulate in the CloudKit dev environment from
                    // fresh-install test runs, and became visible once #98's
                    // picker listed every household). Never offered for a
                    // household with content or one shared *with* us.
                    .contextMenu {
                        if isDeletableStray(household) {
                            Button("Delete Household…", role: .destructive) {
                                householdPendingDelete = household
                            }
                        }
                    }
                }
                if entitlements.isPlus {
                    Button {
                        newHouseholdName = ""
                        showNewHousehold = true
                    } label: {
                        Label("New Household…", systemImage: "plus")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .safeAreaInset(edge: .bottom) { sidebarFooter }
    }

    /// Sidebar selection drives the detail surface; deselection is ignored so
    /// a surface is always showing.
    private var surfaceSelection: Binding<AppMode?> {
        Binding(
            get: { ui.surface },
            set: { newValue in
                if let newValue { withAnimation(.snappy) { ui.surface = newValue } }
            }
        )
    }

    /// True only for a household the user OWNS (private store) with no chores
    /// and no areas — a stray. Shared-with-us households are never deletable
    /// here (leaving a share is a different flow), nor is anything with content.
    private func isDeletableStray(_ household: CDHousehold) -> Bool {
        let stack = CoreDataStack.shared
        if let shared = stack.sharedStore, household.objectID.persistentStore === shared {
            return false
        }
        let context = stack.viewContext
        let chores = NSFetchRequest<CDChore>(entityName: "CDChore")
        chores.predicate = NSPredicate(format: "household == %@", household)
        let areas = NSFetchRequest<CDArea>(entityName: "CDArea")
        areas.predicate = NSPredicate(format: "household == %@", household)
        return ((try? context.count(for: chores)) ?? 1) == 0
            && ((try? context.count(for: areas)) ?? 1) == 0
    }

    private func deleteHousehold(_ household: CDHousehold) {
        let context = CoreDataStack.shared.viewContext
        let wasActive = model.resolvedHousehold == household
        context.delete(household)
        try? context.save()
        if wasActive { model.setScope(.solo) }
        Log.info("Deleted empty household", category: .model)
    }

    private func scopeRow(title: String, systemImage: String, checked: Bool,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: systemImage)
                    .lineLimit(1)
                Spacer()
                if checked {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var sidebarFooter: some View {
        HStack(spacing: 8) {
            switch model.syncState {
            case .syncing:
                ProgressView().controlSize(.small)
                Text("Syncing…").font(.caption).foregroundStyle(.secondary)
            case .notSignedIn:
                Image(systemName: "exclamationmark.icloud").foregroundStyle(.secondary)
                Text("Sync paused").font(.caption).foregroundStyle(.secondary)
            case .idle:
                Image(systemName: "checkmark.icloud").foregroundStyle(.secondary)
                Text("Synced").font(.caption).foregroundStyle(.secondary)
            case .disabled, .error:
                EmptyView()
            }
            Spacer()
            if !entitlements.isPlus {
                Button {
                    ui.showPaywall = true
                } label: {
                    Label("Plus", systemImage: "sparkles")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .help("Get Choreganize Plus")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: Detail

    private var detail: some View {
        NavigationStack {
            Group {
                switch ui.surface {
                case .work:
                    WorkHomeView()
                case .edit:
                    EditHomeView()
                case .calendar:
                    CalendarHomeView()
                case .insights:
                    InsightsHomeView()
                }
            }
            .animation(.easeInOut, value: ui.surface)
            .navigationTitle(ui.surface.rawValue)
            .toolbar {
                if model.scope == .household {
                    ToolbarItem(placement: .compatTrailing) {
                        HouseholdShareControl()
                    }
                }
            }
        }
        .environmentObject(model)
    }
}

/// The sidebar's Liquid Glass hero: today's remaining chores as a ring +
/// count, always current via the same fetch the Work surface uses.
private struct TodayHeroCard: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var ui: MacUIState
    @FetchRequest(fetchRequest: displayChoresFetchRequest()) private var chores: FetchedResults<CDChore>

    private var today: [CDChore] {
        Scheduling.chores(Array(chores).inScope(model.activeHousehold), for: Date())
    }

    var body: some View {
        let all = today
        let done = all.filter { $0.isCompleted(on: Date()) }.count
        let total = all.count
        let progress = total == 0 ? 1.0 : Double(done) / Double(total)

        Button {
            withAnimation(.snappy) { ui.surface = .work }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .stroke(.quaternary, lineWidth: 4)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(progress >= 1 ? Color.green : Color.accentColor,
                                style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.snappy, value: progress)
                    if progress >= 1 {
                        Image(systemName: "checkmark")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.green)
                    }
                }
                .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Today")
                        .font(.subheadline.weight(.semibold))
                    Text(total == 0 ? "Nothing due" :
                            (done == total ? "All \(total) done" : "\(total - done) of \(total) left"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
    }
}
