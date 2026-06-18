import SwiftUI
import UIKit

enum AppMode: String, CaseIterable, Identifiable {
    case work = "Work"
    case edit = "Edit"
    case calendar = "Calendar"
    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .work: "checklist"
        case .edit: "slider.horizontal.3"
        case .calendar: "calendar"
        }
    }
}

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

    /// Card steps present as a sheet; spotlight steps use the overlay instead.
    private var cardStep: Binding<OnboardingStep?> {
        Binding(
            get: { onboarding.current?.spotlight == nil ? onboarding.current : nil },
            set: { _ in }   // dismissal is driven by the card's own buttons
        )
    }

    var body: some View {
        NavigationStack {
            VStack {
                switch mode {
                case .work:
                    WorkHomeView()
                case .edit:
                    EditHomeView()
                case .calendar:
                    CalendarHomeView()
                }
            }
            .toolbar(.visible, for: .automatic)
            .animation(.easeInOut, value: mode)
            .toolbar {
                // Solo vs Household scope switch. (CloudKit sharing of the
                // Household returns in Phase 3.)
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Scope", selection: Binding(
                            get: { model.scope },
                            set: { model.setScope($0) }
                        )) {
                            ForEach(AppScope.allCases) { scope in
                                Label(scope.title, systemImage: scope.systemImage).tag(scope)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: model.scope.systemImage)
                            Text(model.scope == .household ? model.householdName : model.scope.title)
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
                    .onboardingAnchor(.scopeSwitch)
                }
                ToolbarItem(placement: .status) {
                    if model.isSyncing {
                        ProgressView().controlSize(.small)
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
                        Label("Hub", systemImage: "square.grid.2x2")
                    }
                }
            }
            .alert("Error", isPresented: $showingError, actions: {
                Button("OK", role: .cancel) { model.lastError = nil }
            }, message: {
                Text(model.lastError ?? "Unknown error")
            })
            .onChange(of: model.lastError) { _, newValue in
                showingError = newValue != nil
            }
            .sheet(isPresented: $showingHub, onDismiss: { onboarding.playPendingIfNeeded() }) {
                HubView()
                    .environmentObject(model)
                    .environmentObject(onboarding)
            }
            .sheet(isPresented: $showingLogs) {
                LogViewerView()
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
            // #65: the floating mode switcher lives in the bottom safe-area inset — it
            // reserves its own room and only hit-tests its own frame (no scrim, no
            // full-screen overlay). Default style is the Menu-backed glass pill; the
            // system owns expansion + outside-tap dismissal. See
            // .claude-work/current/liquid-glass-switcher-spec.md.
            .safeAreaInset(edge: .bottom) {
                ModeSwitcher(mode: $mode,
                             style: SwitcherStyle(rawValue: switcherStyleRaw) ?? .menu,
                             onLongPress: { showingLogs = true })
                    .onboardingAnchor(.modePicker)
                    .padding(.bottom, 6)
            }
        }
        .overlayPreferenceValue(SpotlightAnchorsKey.self) { anchors in
            OnboardingSpotlightOverlay(coordinator: onboarding, anchors: anchors)
        }
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
