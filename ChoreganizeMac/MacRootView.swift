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
    #if DEBUG
    @Environment(\.openSettings) private var openSettings
    #endif

    var body: some View {
        shell
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
        // #121: the photo flows (⌥⌘N / ⇧⌘K, the Edit row, the Work toolbar, or a drop).
        .sheet(item: $ui.roomSnap) { request in
            MacRoomSnapSheet(initialPhoto: request.photo)
                .environmentObject(model)
        }
        .sheet(item: $ui.photoCheck) { request in
            MacPhotoCheckSheet(initialPhoto: request.photo)
                .environmentObject(model)
        }
        // #106: Describe Chores (the Edit row or File ▸ New Chores ▸ From a Description…).
        .sheet(item: $ui.describeChores) { request in
            MacDescribeChoresSheet(initialText: request.text)
                .environmentObject(model)
        }
        #if DEBUG
        .onAppear { MacDebugSnapshots.openSettings = { openSettings() } }
        #endif
    }

    @ViewBuilder private var shell: some View {
        #if DEBUG
        if MacDebugSnapshots.isStoreCapture {
            storeCaptureShell
        } else {
            splitView
        }
        #else
        splitView
        #endif
    }

    private var splitView: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 210, ideal: 240)
        } detail: {
            detail
        }
    }

    #if DEBUG
    /// App Store capture only (MacDebugSnapshots): the same sidebar and detail side by
    /// side, without the split view's sidebar material and vibrancy — both composited
    /// by the window server, so an in-process render draws them blank.
    private var storeCaptureShell: some View {
        HStack(spacing: 0) {
            sidebar
                .scrollContentBackground(.hidden)
                .frame(width: 240)
                .background(Color(nsColor: NSColor(name: nil) { appearance in
                    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                        ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.945, alpha: 1)
                }))
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    #endif

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: surfaceSelection) {
            Section {
                TodayHeroCard()
            }
            .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 8, trailing: 8))
            .listRowSeparator(.hidden)

            Section("Views") {
                ForEach(AppMode.allCases) { mode in
                    Label(mode.rawValue, systemImage: mode.systemImage)
                        .tag(mode)
                }
            }
            .listRowSeparator(.hidden)

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
            .listRowSeparator(.hidden)
        }
        .safeAreaInset(edge: .bottom) { sidebarFooter }
    }

    /// Sidebar selection drives the detail surface; deselection is ignored so
    /// a surface is always showing. macOS Lists re-assert their selection
    /// DURING view updates — writing the @Published surface synchronously (or
    /// redundantly) from here triggers "Publishing changes from within view
    /// updates", so only real changes go through, deferred past the update pass.
    private var surfaceSelection: Binding<AppMode?> {
        Binding(
            get: { ui.surface },
            set: { newValue in
                guard let newValue, newValue != ui.surface else { return }
                Task { @MainActor in
                    withAnimation(.snappy) { ui.surface = newValue }
                }
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
        VStack(alignment: .leading, spacing: 6) {
            // Debug builds only (DataIsolation): never mistake a dev run for the real app.
            if let dataLabel = DataIsolation.label, !Self.isStoreCapture {
                Label(dataLabel, systemImage: "hammer.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
                    .help("A debug build: its data is kept apart from the App Store app's.")
            }
            syncStatusRow
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private static var isStoreCapture: Bool {
        #if DEBUG
        MacDebugSnapshots.isStoreCapture
        #else
        false
        #endif
    }

    private var syncStatusRow: some View {
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
    }

    // MARK: Detail

    private var detail: some View {
        NavigationStack {
            Group {
                switch ui.surface {
                case .work:
                    // Mac-specific: one day + explicit navigation (MacWorkHomeView);
                    // the iOS WeekView's paged scrolling can't be made to snap on
                    // macOS trackpads without fighting the scroll system.
                    MacWorkHomeView()
                case .edit:
                    EditHomeView()
                case .calendar:
                    CalendarHomeView()
                case .insights:
                    InsightsHomeView()
                }
            }
            .animation(.easeInOut, value: ui.surface)
            .modifier(SurfacePhotoDrop(surface: ui.surface) { surface, photo in
                if surface == .edit {
                    ui.roomSnap = MacPhotoRequest(photo: photo)
                } else {
                    ui.photoCheck = MacPhotoRequest(photo: photo)
                }
            })
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
        .modifier(HeroCardBackground())
    }
}

/// Liquid Glass, except while capturing App Store screenshots: glass is composited by
/// the window server, which an in-process render can't reproduce, so the card gets a
/// plain fill instead (DEBUG capture only).
private struct HeroCardBackground: ViewModifier {
    func body(content: Content) -> some View {
        #if DEBUG
        if MacDebugSnapshots.isStoreCapture {
            content.background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else {
            content.glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
        }
        #else
        content.glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
        #endif
    }
}

/// #121: drop a photo on the Edit surface to Snap a Room, or on Work to check off
/// chores. Only while the on-device model can read photos; the surface shows what
/// the drop will do while a photo hovers over it.
private struct SurfacePhotoDrop: ViewModifier {
    let surface: AppMode
    var onPhoto: (AppMode, CGImage?) -> Void

    @State private var isTargeted = false

    private var prompt: String? {
        guard RoomVisionAvailability.current.isAvailable else { return nil }
        switch surface {
        case .edit: return "Drop to get chore ideas for this room"
        case .work: return "Drop to check off today's chores"
        default:    return nil
        }
    }

    func body(content: Content) -> some View {
        if let prompt {
            content
                .onDrop(of: MacPhotoLoader.acceptedTypes, isTargeted: $isTargeted) { providers in
                    let surface = surface
                    Task { onPhoto(surface, await MacPhotoLoader.load(providers)) }
                    return true
                }
                .overlay {
                    if isTargeted {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.accentColor.opacity(0.10))
                            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                            .overlay {
                                Label(prompt, systemImage: "photo.badge.plus")
                                    .font(.title3.weight(.semibold))
                                    .padding(.horizontal, 18)
                                    .padding(.vertical, 12)
                                    .background(.regularMaterial, in: Capsule())
                            }
                            .padding(12)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: isTargeted)
        } else {
            content
        }
    }
}
