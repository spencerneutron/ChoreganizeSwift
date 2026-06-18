import SwiftUI
import UIKit

enum AppMode: String, CaseIterable, Identifiable {
    case work = "Work"
    case edit = "Edit"
    case calendar = "Calendar"
    var id: String { rawValue }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var mode: AppMode = .work
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
            .safeAreaInset(edge: .bottom) {
                ZStack {
                    // Match the system bar appearance
                    Rectangle()
                        .fill(.bar)
                        .ignoresSafeArea()
                        .frame(height: 60)

                    Picker("Mode", selection: $mode) {
                        ForEach(AppMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .onboardingAnchor(.modePicker)
                }
                .contentShape(Rectangle())
                .simultaneousGesture(LongPressGesture().onEnded { _ in
                    showingLogs = true
                })
            }
        }
        .overlayPreferenceValue(SpotlightAnchorsKey.self) { anchors in
            OnboardingSpotlightOverlay(coordinator: onboarding, anchors: anchors)
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
