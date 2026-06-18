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
    @State private var navExpanded: Bool = false
    @State private var showingHub: Bool = false
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
            // #65: reserve room for the floating switcher so list content scrolls
            // clear of it; the control itself is drawn in the overlay below.
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: 52)
            }
            .overlay(alignment: .bottom) {
                ZStack(alignment: .bottom) {
                    // Tap-away scrim: present only while expanded, sitting beneath the
                    // switcher so taps anywhere else collapse it.
                    if navExpanded {
                        Color.black.opacity(0.001)
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                            .onTapGesture { withAnimation(switcherMorph) { navExpanded = false } }
                    }
                    FloatingTabSwitcher(mode: $mode, expanded: $navExpanded)
                        .onboardingAnchor(.modePicker)
                        .padding(.bottom, 6)
                        .simultaneousGesture(LongPressGesture().onEnded { _ in
                            showingLogs = true
                        })
                }
            }
        }
        .overlayPreferenceValue(SpotlightAnchorsKey.self) { anchors in
            OnboardingSpotlightOverlay(coordinator: onboarding, anchors: anchors)
        }
    }
}

/// Shared morph timing for the floating switcher (#65). A gentle, low-bounce spring
/// reads as a fluid Liquid Glass flow between the pill and the bar, rather than a snap.
private let switcherMorph: Animation = .spring(response: 0.45, dampingFraction: 0.82)

/// The floating mode switcher (#65). Collapses to a glass pill showing the current
/// tab; tapping expands it to the three-way selector. Choosing a tab (or tapping
/// away — handled by the scrim in `ContentView`) collapses it back onto the new tab.
///
/// On iOS 26 the collapse/expand is a fluid Liquid Glass morph (the pill and the
/// selector share a `glassEffectID` inside a `GlassEffectContainer`, so the glass
/// flows between the two shapes). Earlier releases get a scale/opacity transition
/// over the `.bar` material (deploy floor 18.6).
private struct FloatingTabSwitcher: View {
    @Binding var mode: AppMode
    @Binding var expanded: Bool

    var body: some View {
        if #available(iOS 26.0, *) {
            MorphingTabSwitcher(mode: $mode, expanded: $expanded)
        } else {
            LegacyTabSwitcher(mode: $mode, expanded: $expanded)
        }
    }
}

/// iOS 26 Liquid Glass morph. The collapsed pill and the expanded selector share one
/// `glassEffectID` inside a `GlassEffectContainer`, so toggling `expanded` within an
/// animation makes the glass fluidly flow between the two shapes.
@available(iOS 26.0, *)
private struct MorphingTabSwitcher: View {
    @Binding var mode: AppMode
    @Binding var expanded: Bool
    @Namespace private var glassNS

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            ZStack {
                if expanded {
                    Picker("Mode", selection: $mode) {
                        ForEach(AppMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 280)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                    .glassEffect()
                    .glassEffectID("modeSwitcher", in: glassNS)
                } else {
                    Button {
                        withAnimation(switcherMorph) { expanded = true }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: mode.systemImage)
                            Text(mode.rawValue).fontWeight(.semibold)
                        }
                        .font(.subheadline)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .glassEffect()
                    .glassEffectID("modeSwitcher", in: glassNS)
                    .accessibilityIdentifier("modeSwitcherCollapsed")
                    .accessibilityLabel("Current view: \(mode.rawValue). Double-tap to switch.")
                }
            }
        }
        // Selecting a tab collapses the expanded selector back onto the new tab.
        .onChange(of: mode) {
            if expanded { withAnimation(switcherMorph) { expanded = false } }
        }
    }
}

/// Pre-iOS-26 fallback: scale/opacity transition over the `.bar` material capsule.
private struct LegacyTabSwitcher: View {
    @Binding var mode: AppMode
    @Binding var expanded: Bool

    var body: some View {
        ZStack {
            if expanded {
                Picker("Mode", selection: $mode) {
                    ForEach(AppMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
                .transition(.scale(scale: 0.85).combined(with: .opacity))
            } else {
                Button {
                    withAnimation(switcherMorph) { expanded = true }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: mode.systemImage)
                        Text(mode.rawValue).fontWeight(.semibold)
                    }
                    .font(.subheadline)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("modeSwitcherCollapsed")
                .accessibilityLabel("Current view: \(mode.rawValue). Double-tap to switch.")
                .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
        }
        .padding(.horizontal, expanded ? 8 : 16)
        .padding(.vertical, 8)
        .background(.bar, in: Capsule())
        // Selecting a tab collapses the expanded selector back onto the new tab.
        .onChange(of: mode) {
            if expanded { withAnimation(switcherMorph) { expanded = false } }
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
