import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var mode: AppMode = .work
    @State private var showingHub: Bool = false
    /// Which switcher style to use (#65). Settled on the Liquid Glass morph; the
    /// Menu-backed pill stays available via the Hub's Developer toggle (DEBUG).
    @AppStorage(SettingsKeys.switcherStyle) private var switcherStyleRaw = SwitcherStyle.morph.rawValue
    @State private var showingError: Bool = false
    @State private var showingLogs: Bool = false
    @StateObject private var onboarding = OnboardingCoordinator()
    /// CG-16 / #98: multiple households — creation is the Plus affordance.
    @ObservedObject private var entitlements = EntitlementStore.shared
    @State private var showNewHousehold = false
    /// Chores staged in an Edit flow and not yet saved (see `EditFlowGuard`).
    @State private var editGuard = EditFlowGuard()
    /// Where the user asked to go while leaving Edit would drop unsaved chores, and how many
    /// (kept for the question's wording while it closes).
    @State private var pendingExit: EditExit?
    @State private var pendingChores = 0

    /// Edit's container for this visit, picked on the way in: the split where the modes are in
    /// the system tab bar, the stack with the pill. Picked per render, an iPad window crossing
    /// compact/regular mid-visit (Split View, Stage Manager) swapped it and dropped an open
    /// flow without asking. Held, the split just collapses to one column, and the stack just
    /// widens; the next visit picks again.
    @State private var editUsesSplit: Bool?

    /// Ways of leaving Edit that the guard asks about first.
    private enum EditExit: Equatable {
        case mode(AppMode)
        case chore(UUID)   // a widget link: switches the scope and shows the chore on Work
    }

    /// The mode, through the Edit guard: leaving Edit with unsaved chores asks first, as the
    /// add-flow's own Cancel does (#53). The tab bar and the pill switch through here; a
    /// widget link goes through `leave(for:)` too.
    private var guardedMode: Binding<AppMode> {
        Binding(get: { mode }, set: { newMode in if newMode != mode { leave(for: .mode(newMode)) } })
    }

    private func leave(for exit: EditExit) {
        if mode == .edit, editGuard.unsavedChores > 0 {
            pendingChores = editGuard.unsavedChores
            pendingExit = exit
        } else {
            perform(exit)
        }
    }

    private func perform(_ exit: EditExit) {
        switch exit {
        case .mode(let newMode):
            mode = newMode
        case .chore(let choreID):
            model.openDeepLinkChore(choreID)
            mode = .work
        }
    }
    @State private var newHouseholdName = ""

    /// Card steps present as a sheet; spotlight steps use the overlay instead.
    private var cardStep: Binding<OnboardingStep?> {
        Binding(
            get: { onboarding.current?.spotlight == nil ? onboarding.current : nil },
            set: { _ in }   // dismissal is driven by the card's own buttons
        )
    }

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// Whether the modes live in a system `TabView` rather than the floating glass
    /// switcher (#65). Decided by what the system reports, never by device model (Apple:
    /// "Don't use userInterfaceIdiom … for layout decisions"):
    /// - a regular × regular size (iPad, iPhone Duo's inner display), where the tab bar
    ///   can adapt into a sidebar;
    /// - or a context where the system lays bars out vertically (iPhone Duo's outer
    ///   display, and its inner display in landscape), so the modes join that side bar.
    /// Everywhere else (iPhone in either orientation, a narrow iPad window) keeps the pill.
    private func usesSystemTabs(barsAreVertical: Bool) -> Bool {
        (horizontalSizeClass == .regular && verticalSizeClass == .regular) || barsAreVertical
    }

    var body: some View {
        VerticalBarReader { barsAreVertical in
            shell(systemTabs: usesSystemTabs(barsAreVertical: barsAreVertical))
        }
            // Presentations are attached once, outside the navigation stack(s): the tab
            // shell has one stack per tab and must not register four copies of each sheet.
            .alert("Error", isPresented: $showingError, actions: {
                Button("OK", role: .cancel) { model.lastError = nil }
            }, message: {
                Text(model.lastError ?? "Unknown error")
            })
            // CG-16 / #98: name-and-create for an additional household (Plus).
            .alert("New Household", isPresented: $showNewHousehold) {
                TextField("Name", text: $newHouseholdName)
                Button("Create") { model.createHousehold(named: newHouseholdName) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Creates a separate household you can share independently.")
            }
            .onChange(of: model.lastError) { _, newValue in
                showingError = newValue != nil
            }
            // CG-05: a widget deep-link points at a chore on the Work surface, so bring
            // Work forward if we're in Edit/Calendar. WeekView + DayPage then handle the
            // day reset, scroll, and highlight (see AppModel.deepLinkChore). Nothing changes,
            // not even the scope, until leaving Edit is settled.
            .onChange(of: model.deepLinkRequest, initial: true) { _, choreID in
                guard let choreID else { return }
                model.deepLinkRequest = nil   // taken, so tapping the same chore again works
                leave(for: .chore(choreID))
            }
            // An alert, not a confirmation dialog: nothing on screen anchors this choice (a
            // dialog became a popover pointing at the middle of a wide window).
            .alert(pendingChores == 1 ? "Discard 1 unsaved chore?" : "Discard \(pendingChores) unsaved chores?",
                   isPresented: Binding(get: { pendingExit != nil },
                                        set: { if !$0 { pendingExit = nil } })) {
                Button("Discard", role: .destructive) {
                    editGuard.removeAll()   // the flows close with Edit; don't wait for their entries
                    if let pendingExit { perform(pendingExit) }
                    pendingExit = nil
                }
                Button("Keep Editing", role: .cancel) { pendingExit = nil }
            } message: {
                Text(pendingChores == 1 ? "It hasn't been saved yet." : "They haven't been saved yet.")
            }
            .sheet(isPresented: $showingHub, onDismiss: { onboarding.playPendingIfNeeded() }) {
                HubView()
                    .environmentObject(model)
                    .environmentObject(onboarding)
            }
            .sheet(isPresented: $showingLogs) {
                LogViewerView()
            }
            // CG-11 / #64: Personal→Household migration picker. Mounted here
            // (not in the toolbar control) so the offer banner's action can
            // present it from any tab.
            .sheet(isPresented: $model.showMigrationPicker) {
                MigrationPickerView()
                    .environmentObject(model)
            }
            .sheet(item: cardStep) { step in
                OnboardingCardView(
                    step: step,
                    hasNext: onboarding.hasNext,
                    onNext: { onboarding.advance() },
                    onSkip: { onboarding.finish() }
                )
                .interactiveDismissDisabled()
            }
            .task {
                onboarding.startFirstRunIfNeeded()
                #if DEBUG
                if let raw = ProcessInfo.processInfo.environment["CHOREGANIZE_ONBOARD_STEP"],
                   let id = OnboardingStep.ID(rawValue: raw) {
                    onboarding.play(OnboardingStep.step(id))
                }
                #endif
            }
            .overlayPreferenceValue(SpotlightAnchorsKey.self) { anchors in
                OnboardingSpotlightOverlay(coordinator: onboarding, anchors: anchors)
            }
    }

    /// One `TabView` in every configuration, so the mode views are never rebuilt when the
    /// system's sizes change: opening or closing iPhone Duo, rotating, resizing an iPad
    /// window. (Apple: "Keep functionality and the state of elements the same between
    /// displays.") `systemTabs` only decides who shows the modes: the system tab bar, or
    /// the floating glass switcher with the tab bar hidden. As with the pill, only the
    /// selected mode is mounted, so a hidden tab doesn't keep fetching, animating, or
    /// holding a flow open while the scope changes from another tab.
    private func shell(systemTabs: Bool) -> some View {
        TabView(selection: guardedMode) {
            ForEach(AppMode.allCases) { m in
                Tab(m.rawValue, systemImage: m.systemImage, value: m) {
                    Group {
                        if m == mode {
                            navigation(for: m, systemTabs: systemTabs)
                        } else {
                            Color.clear
                        }
                    }
                    // Every tab carries the bar's visibility, mounted or not (a placeholder
                    // stands in for the modes not on screen): set only on the open mode's view,
                    // the hidden bar came back as soon as the pill switched to another tab. The
                    // four tabs never change, so switching between the pill and the tab bar
                    // (an iPad window crossing compact/regular) keeps the open mode.
                    .toolbar(systemTabs ? .automatic : .hidden, for: .tabBar)
                    .environment(\.clearsModeSwitcher, !systemTabs)
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)   // "adapts to each platform"
        .onChange(of: mode, initial: true) { _, newMode in
            editUsesSplit = newMode == .edit ? (editUsesSplit ?? systemTabs) : nil
        }
    }

    /// A mode's navigation. Where the modes are in the system tab bar (iPad, iPhone Duo), Edit
    /// is a list and its detail: a system split view that shows both side by side where
    /// there's room (iPad, the Duo's inner display) and collapses to the pushed list on the
    /// Duo's outer display. It's a split view in every size there, so opening or closing the
    /// Duo keeps the Edit tab instead of rebuilding it. (Apple: a split view "expands on the
    /// inner display and collapses to a single pane on the outer display", and adapts its
    /// columns to the fold.) With the floating pill (iPhone, a narrow iPad window), Edit is
    /// the pushed list it always was: a Plus or Pro Max in landscape is wide enough for a
    /// split, which put the pill inside its first column.
    @ViewBuilder
    private func navigation(for mode: AppMode, systemTabs: Bool) -> some View {
        if mode == .edit && (editUsesSplit ?? systemTabs) {
            EditSplit(flowGuard: editGuard) { selection in
                // The same inset-grouped list as before, not the split view's sidebar style,
                // and no room held for a large title it doesn't have. While the add-flow in
                // the detail has staged chores, the list (and its bar: scope, sharing, Hub)
                // waits until it's saved or cancelled, so a tap here can't drop them.
                // The note sits above the list, pushing it down: at the bottom it covered the
                // last rows, which a short list doesn't scroll clear of.
                bars(on: EditHomeView(selection: selection).listStyle(.insetGrouped)
                        .safeAreaInset(edge: .top) {
                            if editGuard.unsavedChores > 0 {
                                Text("Save or cancel the chores you're adding to choose something else.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .padding(12)
                                    .frame(maxWidth: .infinity)
                                    .background(.regularMaterial, in: .rect(cornerRadius: 12))
                                    .padding(.horizontal)
                                    .padding(.top, 4)
                                    .transition(.opacity)
                            }
                        }
                        .animation(.easeInOut(duration: 0.2), value: editGuard.unsavedChores > 0),
                     systemTabs: systemTabs)
                    .disabled(editGuard.unsavedChores > 0)
                    .navigationBarTitleDisplayMode(.inline)
                    // Wide enough for the add-flow rows not to wrap; on the open iPhone Duo
                    // this puts the list's edge near the fold.
                    .navigationSplitViewColumnWidth(min: 320, ideal: 420, max: 480)
            }
        } else {
            // Edit's flows still report to the guard here, so a widget link asks before
            // dropping their unsaved chores.
            NavigationStack { bars(on: modeView(mode), systemTabs: systemTabs) }
                .environment(editGuard)
        }
    }

    private func modeView(_ mode: AppMode) -> some View {
        VStack {
            switch mode {
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
    }

    /// The chrome every mode shares: banners, the scope switch, sharing, the Hub, and the
    /// mode switcher itself (system tab bar, or the floating pill). Applied to the root of
    /// the selected tab's navigation stack.
    private func bars(on content: some View, systemTabs: Bool) -> some View {
        VerticalBarReader { isVertical in
            content
                .toolbar(.visible, for: .automatic)
                .animation(.easeInOut, value: mode)
                // Transient app banners (sync paused / not signed in, errors, info) live
                // in a top safe-area inset — symmetric with the bottom mode switcher, it
                // reserves its own room and pushes content down rather than overlapping.
                // The banner queue already existed on AppModel; this surfaces it (CG-06).
                .safeAreaInset(edge: .top) {
                    if let banner = model.currentBanner {
                        AppBannerView(banner: banner) { model.dismissBanner() }
                            .padding(.horizontal, 12)
                            .padding(.top, 4)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: model.currentBanner)
                // Freeze the calendar's perfect-day glow (shader + TimelineView) while a full-cover
                // sheet is up — otherwise it keeps rendering behind the sheet and tanks its framerate
                // (the Hub opened over the Calendar). Sheets opened from Work/Edit don't mount the
                // calendar, so this is a no-op there.
                .environment(\.glowAnimationActive,
                             !(showingHub || showingLogs || cardStep.wrappedValue != nil))
                .toolbar {
                    // Solo vs Household scope switch. (CloudKit sharing of the
                    // Household returns in Phase 3.)
                    // Two branches, so the item is rebuilt when the bar axis flips. The system
                    // places an item on an axis from the content it appears with; swapping only
                    // the label left the scope menu stranded in a top bar after a rotation.
                    if isVertical {
                        ToolbarItem(placement: .topBarLeading) {
                            scopeMenu(isVertical: true)
                                .onboardingAnchor(.scopeSwitch)
                        }
                    } else {
                        ToolbarItem(placement: .topBarLeading) {
                            scopeMenu(isVertical: false)
                                .onboardingAnchor(.scopeSwitch)
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        if model.scope == .household {
                            HouseholdShareControl()
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingHub = true
                        } label: {
                            Label("Hub", systemImage: PlatformText.hubSymbol)
                        }
                    }
                }
                // #65: the floating mode switcher lives in the bottom safe-area inset — it
                // reserves its own room and only hit-tests its own frame (no scrim, no
                // full-screen overlay). Default style is the Menu-backed glass pill; the
                // system owns expansion + outside-tap dismissal. See
                // .claude-work/current/liquid-glass-switcher-spec.md.
                // #65: the switcher floats OVER the content (an overlay, not a safeAreaInset)
                // so the scroll views run full-bleed underneath and content slides under the
                // translucent glass. A safeAreaInset would instead reserve an opaque band the
                // content stops above — the regression we're undoing. Each mode's scroll view
                // adds bottom contentMargins so its last rows still clear the floating chrome.
                .overlay(alignment: .bottom) {
                    if !systemTabs {
                        ZStack {
                            ModeSwitcher(mode: guardedMode,
                                         style: SwitcherStyle(rawValue: switcherStyleRaw) ?? .menu,
                                         onLongPress: { showingLogs = true })
                                .onboardingAnchor(.modePicker)
                            // CG-06: the sync status floats as its own glass chip BESIDE the
                            // switcher (trailing) — never under it, and never via a
                            // ToolbarItem(.status), which materializes an opaque bottom bar that
                            // covers content and breaks the switcher's float-over-content design.
                            // Non-interactive, so it never steals the switcher's touches.
                            HStack {
                                Spacer()
                                SyncStatusIndicator(state: model.syncState)
                                    .allowsHitTesting(false)
                                    .padding(.trailing, 20)
                            }
                            .animation(.easeInOut(duration: 0.2), value: model.syncState)
                        }
                        .padding(.bottom, 6)
                    }
                }
                // CG-06 with the system tab bar: the chip floats in the content's own corner,
                // inside the safe area, so it never covers the tab bar or iPhone Duo's side bar.
                .overlay(alignment: .bottomTrailing) {
                    if systemTabs {
                        SyncStatusIndicator(state: model.syncState)
                            .allowsHitTesting(false)
                            .padding(12)
                            .animation(.easeInOut(duration: 0.2), value: model.syncState)
                    }
                }
        }
    }

    private func scopeMenu(isVertical: Bool) -> some View {
        Menu {
            Picker("Scope", selection: Binding(
                get: { model.scope },
                set: { model.setScope($0) }
            )) {
                ForEach(AppScope.allCases) { scope in
                    Label(scope.title, systemImage: scope.systemImage).tag(scope)
                }
            }
            // CG-16 / #98: pick among several households. Switching is
            // never gated (a member of two shares must be able to reach
            // both); CREATING an extra household is the Plus affordance.
            let households = model.allHouseholds
            if households.count > 1 {
                Section("Households") {
                    ForEach(households, id: \.objectID) { household in
                        Button {
                            model.setActiveHousehold(household)
                            model.setScope(.household)
                        } label: {
                            if household == model.resolvedHousehold {
                                Label(household.name ?? "Household", systemImage: "checkmark")
                            } else {
                                Text(household.name ?? "Household")
                            }
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
            }
        } label: {
            if isVertical {
                // iPhone Duo's side bar is fixed-width and favors symbols: an icon + text
                // label would keep a whole horizontal bar alive for this one control. The
                // title still names the item (menus, overflow, VoiceOver).
                Label(scopeTitle, systemImage: model.scope.systemImage)
            } else {
                HStack(spacing: 4) {
                    Image(systemName: model.scope.systemImage)
                    Text(scopeTitle)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                // #52: pin the corner control to the leading edge and cap its
                // width so it grows/shrinks to the *right* and can never extend
                // past the screen bound mid-animation. Disabling the implicit
                // resize animation stops the "widen-then-recenter" jump when the
                // label changes (scope toggle / household-name edit).
                // #58: long household names still truncate at the tail.
                .frame(maxWidth: 160, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .transaction { $0.disablesAnimations = true }
            }
        }
    }

    private var scopeTitle: String {
        model.scope == .household ? model.householdName : model.scope.title
    }
}

/// Floating CloudKit sync status chip (CG-06), shown BESIDE the mode switcher in the
/// bottom safe-area inset — deliberately NOT a `.status` toolbar item, which would
/// materialize an opaque bottom bar that covers content and breaks the floating switcher
/// (#65). A spinner while a mirroring event runs; a "sync paused" cloud-slash when
/// CloudKit is intended but no iCloud account is available. Idle / disabled /
/// transient-error render nothing (errors surface via the banner), so the corner stays
/// empty in the common case.
struct SyncStatusIndicator: View {
    let state: AppModel.SyncState

    var body: some View {
        switch state {
        case .syncing:
            badge { ProgressView().controlSize(.small) }
        case .notSignedIn:
            badge { Image(systemName: "exclamationmark.icloud").foregroundStyle(.secondary) }
                .accessibilityLabel("Sync paused — not signed in to iCloud")
        case .idle, .disabled, .error:
            EmptyView()
        }
    }

    /// The shared floating-glass treatment — matches the switcher's material so the chip
    /// reads as a sibling floating control rather than chrome.
    private func badge(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .frame(width: 30, height: 30)
            .switcherGlass(interactive: false)
            .transition(.scale.combined(with: .opacity))
    }
}

/// How the floating mode switcher presents its options (#65). `.menu` (default) is the
/// robust, idiomatic iOS 26 path — a glass pill that opens a system Menu, so the OS owns
/// expansion + outside-tap dismissal + hit-testing (no scrim, no custom glass-morph →
/// none of the hit-test/Metal hangs). `.morph` is the opt-in custom GlassEffectContainer
/// pill⇄bar morph. See .claude-work/current/liquid-glass-switcher-spec.md.
enum SwitcherStyle: String, CaseIterable, Identifiable {
    case menu, morph
    var id: String { rawValue }
    var title: String {
        switch self {
        case .menu:  "Menu"
        case .morph: "Glass morph (default)"
        }
    }
}

/// Public entry point for the floating Work/Edit/Calendar switcher.
struct ModeSwitcher: View {
    @Binding var mode: AppMode
    var style: SwitcherStyle = .menu
    var onLongPress: () -> Void = {}

    var body: some View {
        switch style {
        case .menu:  MenuModeSwitcher(mode: $mode, onLongPress: onLongPress)
        case .morph: MorphModeSwitcher(mode: $mode, onLongPress: onLongPress)
        }
    }
}

private extension View {
    /// Liquid Glass capsule on iOS 26+, a `.bar` capsule fallback on iOS 18.6.
    @ViewBuilder
    func switcherGlass(interactive: Bool = true) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: .capsule)
        } else {
            self
                .background(.bar, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        }
    }
}

/// Default switcher: a glass pill that opens a system Menu of the three modes. The OS
/// owns presentation and outside-tap dismissal, so there's no scrim to strand touches
/// and the glass-morph pipeline is never invoked.
struct MenuModeSwitcher: View {
    @Binding var mode: AppMode
    var onLongPress: () -> Void = {}

    var body: some View {
        Menu {
            Picker("View", selection: $mode) {
                ForEach(AppMode.allCases) { m in
                    Label(m.rawValue, systemImage: m.systemImage)
                        .tag(m)
                        .accessibilityIdentifier(m.rawValue)   // UITest taps menu items by name
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: mode.systemImage)
                Text(mode.rawValue).fontWeight(.semibold)
            }
            .font(.subheadline)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .switcherGlass()
        .fixedSize()
        .animation(.snappy, value: mode)
        .accessibilityIdentifier("modeSwitcherCollapsed")
        .accessibilityLabel("Switch view")
        .accessibilityValue(mode.rawValue)
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.6).onEnded { _ in onLongPress() })
    }
}

/// Opt-in custom morph: the glass pill stretches into a 3-segment glass bar and back.
/// Corrected per the spec — no permanent scrim (the outside-tap backdrop is gated by
/// `allowsHitTesting(expanded)` so it can never linger), a single shared namespace, and
/// interactive glass.
struct MorphModeSwitcher: View {
    @Binding var mode: AppMode
    var onLongPress: () -> Void = {}
    @State private var expanded = false

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassMorph(mode: $mode, expanded: $expanded, onLongPress: onLongPress)
        } else {
            LegacyMorph(mode: $mode, expanded: $expanded, onLongPress: onLongPress)
        }
    }
}

@available(iOS 26.0, *)
private struct GlassMorph: View {
    @Binding var mode: AppMode
    @Binding var expanded: Bool
    var onLongPress: () -> Void
    @Namespace private var glassNS                  // declared once, owns both states
    private let morph: Animation = .spring(response: 0.5, dampingFraction: 0.86)

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            ZStack {
                if expanded { expandedBar } else { collapsedPill }
            }
        }
        // Outside-tap dismissal WITHOUT a permanent scrim: a backdrop that exists only
        // while expanded and never hit-tests when collapsed.
        .background {
            if expanded {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation(morph) { expanded = false } }
                    .allowsHitTesting(expanded)
                    .transition(.opacity)
            }
        }
        .onChange(of: mode) { _, _ in
            if expanded { withAnimation(morph) { expanded = false } }
        }
    }

    private var collapsedPill: some View {
        Button { withAnimation(morph) { expanded = true } } label: {
            HStack(spacing: 6) {
                Image(systemName: mode.systemImage)
                Text(mode.rawValue).fontWeight(.semibold)
            }
            .font(.subheadline)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .glassEffectID("modeSwitcher", in: glassNS)
        .accessibilityIdentifier("modeSwitcherCollapsed")
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.6).onEnded { _ in onLongPress() })
    }

    private var expandedBar: some View {
        HStack(spacing: 4) {
            ForEach(AppMode.allCases) { m in
                Button { withAnimation(morph) { mode = m } } label: {
                    HStack(spacing: 5) {
                        Image(systemName: m.systemImage)
                        Text(m.rawValue)
                    }
                    .font(.subheadline.weight(m == mode ? .semibold : .regular))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(m.rawValue)
            }
        }
        .padding(.horizontal, 4).padding(.vertical, 4)
        .glassEffect(.regular.interactive(), in: .capsule)
        .glassEffectID("modeSwitcher", in: glassNS)
    }
}

/// Pre-iOS-26 fallback for the morph: scale/opacity transition over the `.bar` material.
private struct LegacyMorph: View {
    @Binding var mode: AppMode
    @Binding var expanded: Bool
    var onLongPress: () -> Void
    private let morph: Animation = .spring(response: 0.5, dampingFraction: 0.86)

    var body: some View {
        ZStack {
            if expanded {
                HStack(spacing: 4) {
                    ForEach(AppMode.allCases) { m in
                        Button { withAnimation(morph) { mode = m } } label: {
                            HStack(spacing: 5) {
                                Image(systemName: m.systemImage)
                                Text(m.rawValue)
                            }
                            .font(.subheadline.weight(m == mode ? .semibold : .regular))
                            .padding(.horizontal, 12).padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(m.rawValue)
                    }
                }
                .padding(4)
                .background(.bar, in: Capsule())
                .transition(.scale.combined(with: .opacity))
            } else {
                Button { withAnimation(morph) { expanded = true } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: mode.systemImage)
                        Text(mode.rawValue).fontWeight(.semibold)
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .background(.bar, in: Capsule())
                .accessibilityIdentifier("modeSwitcherCollapsed")
                .simultaneousGesture(LongPressGesture(minimumDuration: 0.6).onEnded { _ in onLongPress() })
                .transition(.scale.combined(with: .opacity))
            }
        }
        .background {
            if expanded {
                Color.clear.contentShape(Rectangle()).ignoresSafeArea()
                    .onTapGesture { withAnimation(morph) { expanded = false } }
                    .allowsHitTesting(expanded)
            }
        }
        .onChange(of: mode) { _, _ in
            if expanded { withAnimation(morph) { expanded = false } }
        }
    }
}

#if DEBUG
#Preview {
    ContentView()
        .environmentObject(AppModel())
        .environment(\.managedObjectContext, PreviewStack.context)
}
#endif

/// The Edit tab where the modes are in the system tab bar: the Edit list and its detail in a
/// system split view. The list's selection drives the detail, which has its own stack so a
/// list there (Areas) can push. The split owns the selection, so each visit to Edit starts on
/// the list (only the selected mode is mounted). (Apple: "selecting an item in the view's
/// primary pane displays the item's contents in the secondary pane.")
private struct EditSplit<Sidebar: View>: View {
    let flowGuard: EditFlowGuard
    @ViewBuilder let sidebar: (Binding<EditDestination?>) -> Sidebar

    @State private var selection: EditDestination?
    /// Both columns while nothing is chosen, and always in landscape, where the list sits
    /// beside the detail. Taller than wide (a portrait iPad, the Duo held upright) the list
    /// sits over the detail, so once a row is chosen it steps aside; the sidebar button
    /// brings it back. Left to the system, portrait opened Edit on the empty detail with the
    /// list, and its scope, sharing and Hub controls, tucked away, and it still does on some
    /// launches, so the empty detail offers the list too.
    @State private var columns = NavigationSplitViewVisibility.all
    /// The split's shape, read without redrawing it (a redraw during its first layout is one
    /// way the system tucked the list away).
    @State private var shape = SplitShape()
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            sidebar($selection)
        } detail: {
            NavigationStack {
                if let selection {
                    // Its own identity per row: two lenses are the same view type, and
                    // switching between them kept the first one's steps.
                    selection.view.id(selection)
                } else {
                    ContentUnavailableView {
                        Label("Add or Manage Chores", systemImage: AppMode.edit.systemImage)
                    } description: {
                        Text("Choose a way to add chores, or a list to manage.")
                    } actions: {
                        if columns == .detailOnly {
                            Button("Show List") { withAnimation { columns = .all } }
                        }
                    }
                }
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            // Only a new width can mean the device turned: the keyboard coming up shortens the
            // split, and read as landscape, which brought the list back over the flow.
            guard size.width != shape.width else { return }
            shape.width = size.width
            let portrait = size.height > size.width
            let turned = shape.isPortrait != portrait
            shape.isPortrait = portrait
            if turned, selection != nil { updateColumns() }
        }
        .onChange(of: selection) {
            // Nothing in the detail means no flow is open: don't wait for the closed one's
            // entry to go.
            if selection == nil { flowGuard.removeAll() }
            updateColumns()
        }
        // The note is at the top of the list, beside the flow VoiceOver is in; say it once.
        // Not where the list is out of sight (one column, or tucked away in portrait).
        .onChange(of: flowGuard.unsavedChores > 0) { _, locked in
            if locked, sizeClass == .regular, columns == .all {
                AccessibilityNotification.Announcement(
                    "The list is unavailable until you save or cancel these chores.").post()
            }
        }
        .environment(flowGuard)
    }

    private func updateColumns() {
        let wanted: NavigationSplitViewVisibility = shape.isPortrait && selection != nil ? .detailOnly : .all
        if columns != wanted { columns = wanted }
    }
}

/// Edit's split's width and whether it's taller than wide, kept by reference so reading them
/// doesn't redraw.
private final class SplitShape {
    var width: CGFloat = 0
    var isPortrait = false
}
