# Today's Chores widget — Xcode setup

The widget code is written, but a widget is a separate **app-extension target**
that must be created in Xcode (it can't be added by editing files alone). These
are the one-time steps. ~10 minutes.

> **Status:** this setup is **done and committed** on the release branch (widget
> target, sources, App-Group-only entitlements, version match). The steps below
> are kept as a record + a guide for redoing it from scratch, with the gotchas we
> actually hit called out.

## 1. Create the widget target

1. Xcode → **File ▸ New ▸ Target… ▸ Widget Extension**.
2. Product Name: **ChoreganizeWidget**. Team: same as the app.
3. **Uncheck** "Include Live Activity" and "Include Configuration App Intent"
   (this widget uses `StaticConfiguration`).
4. Finish → **Activate** the scheme when prompted.
5. The current Xcode template generates **several** `.swift` files —
   `ChoreganizeWidget.swift`, `ChoreganizeWidgetBundle.swift`, and
   `ChoreganizeWidgetControl.swift` (plus a LiveActivity file if you left that
   checked). **Delete all of them** (move to Trash) — we ship our own in the
   `ChoreganizeWidget/` folder, and **our** `ChoreganizeWidget.swift` already
   contains the `@main` `WidgetBundle`. Leaving the template's `…Bundle.swift`
   (or `…Control.swift`) causes duplicate-`@main` / "invalid redeclaration"
   errors. Keep the generated `Assets.xcassets` and `Info.plist`.

## 2. Add our sources to the widget target

Add these files (already in the repo) to the **ChoreganizeWidget** target:

- `ChoreganizeWidget/ChoreganizeWidget.swift`  (bundle + widget + provider)
- `ChoreganizeWidget/TodayChoresView.swift`    (the view)
- `ChoreganizeWidget/PrivacyInfo.xcprivacy`    (widget privacy manifest —
  declares the widget's UserDefaults access; **required** for a clean submission
  because the extension is its own bundle). Widget target only.
- `Choreganize/WidgetShared.swift`  ← shared with the app. In the File
  Inspector ▸ **Target Membership**, check **both** `Choreganize` and
  `ChoreganizeWidget`.

If you used "Add Files…", make sure *Target Membership* is the widget target for
the first three, and **both** targets for `WidgetShared.swift`.

> Do **not** add `WidgetSnapshotWriter.swift` to the widget — it's app-only (it
> reads Core Data). The widget only ever reads the published snapshot.

## 3. Add the App Group to BOTH targets

For **each** of the `Choreganize` app target and the `ChoreganizeWidget` target:

1. Signing & Capabilities → **+ Capability ▸ App Groups**.
2. Add / check the group **`group.com.svk.Choreganize`**.

This must match `WidgetShared.appGroupIdentifier`. The app's entitlements files
(`Choreganize.entitlements`, `ChoreganizeDebug.entitlements`) **already list this
group** — just confirm the capability is on and the group is registered in the
Developer portal (Identifiers ▸ App Groups).

> **Gotcha we hit (this project):** `CODE_SIGN_ENTITLEMENTS` is set at the
> **project level**, so a fresh widget target with no entitlements file of its
> own **inherits the app's** entitlements (aps-environment + iCloud + App Group).
> Checking the App Groups box on the widget then writes into the *app's* file,
> not a new one — and the widget ends up signed with push/iCloud it shouldn't
> carry. **Fix (already committed):** `ChoreganizeWidget/ChoreganizeWidget.entitlements`
> holds **only** the App Group, and the widget target's `CODE_SIGN_ENTITLEMENTS`
> (Build Settings ▸ "Code Signing Entitlements") points at it. Keep it that way;
> don't let Xcode redirect the widget back to the app's entitlements.

Until both targets share the group, the app's snapshot write and the widget's
read are safe no-ops (the widget shows its placeholder).

## 3b. Match the app's version and build (REQUIRED for upload)

A fresh widget target defaults to version `1.0` / build `1`. The App Store
**rejects** an extension whose version/build don't match the app. In the widget
target's Build Settings keep these equal to the app target's:

- `MARKETING_VERSION` = the app's `MARKETING_VERSION`
- `CURRENT_PROJECT_VERSION` = the app's `CURRENT_PROJECT_VERSION`

Both targets are kept in lockstep (currently **1.5.0 / build 14**; the `deploy`
skill bumps both at release time). Also keep `IPHONEOS_DEPLOYMENT_TARGET` equal
to the app's (**18.0**) — the widget was briefly at 18.6, which would have hidden
it on 18.0–18.5 devices that could still run the app; realigned to 18.0.

## 4. Run

1. Build & run the **Choreganize** app once on the device/sim. Foregrounding the
   app publishes the first snapshot (see `WidgetSnapshotWriter`, called from
   `ChoreganizeApp` on scene activate/background).
2. Long-press the Home Screen → **+** → search **Choreganize** → add **Today's
   Chores** (small or medium).
3. Complete/uncomplete a chore in the app, background it → the widget updates
   (the app calls `WidgetCenter…reloadTimelines`).

## Notes

- **Interactive completion (CG-02, v1.6.0).** Each home-screen chore row has a
  `Button(intent: CompleteChoreIntent(choreID:name:))`. Tapping it marks the chore
  done. The intent runs in the **app's** process (`openAppWhenRun = false`), so it
  uses the live Core Data + CloudKit stack normally — the widget never owns Core
  Data. `CompleteChoreIntent` is compiled into the widget too (so the `Button` can
  construct it), but its Core Data `perform()` body is gated out of the widget build
  via the `WIDGET_EXTENSION` Swift compilation condition (set on the widget target's
  build configs only — never the app's, or the app would get the no-op stub). After a
  write the app calls `WidgetCenter…reloadTimelines` so the widget reflects it.
  Requires the App Group on both targets (above) — it already is.
- **Lock Screen / accessory widgets (CG-04, v1.6.0).** `supportedFamilies` includes
  `.accessoryCircular` (a Gauge of chores remaining today) and `.accessoryRectangular`
  ("N of M left"), reusing the snapshot's precomputed remaining/total.
- **Deep-linking (CG-05, v1.6.0).** Widget rows carry `choreganize://chore/<uuid>`
  links; the `choreganize://` URL scheme is registered in `Info.plist`, and
  `ChoreganizeApp.onOpenURL` routes the tap so the chore is visible on today's
  DayPage (aligning the active scope if it's a Household chore). A richer
  scroll-to/highlight of the exact chore is a deliberate follow-up — see below.
- **Deep-link follow-up (not yet done).** `handleDeepLink` posts
  `Notification.Name.choreganizeDeepLink` with the chore UUID; nothing consumes it
  yet to scroll to / highlight the specific row (or jump to a non-today day). That
  consumer belongs in `ContentView`/`WorkViews`/DayPage, which were owned by other
  v1.6.0 tracks and kept conflict-free — so the hook is in place, the polish is
  pending.
- The widget shows the **active scope's** chores (Solo or the current
  household), because that's what the app snapshots. Switching scope in the app
  republishes on next foreground/background.
- `containerBackground(_:for:)` and widget `Button(intent:)` need iOS 17+. The app
  and widget deployment targets are both **iOS 18.0**.
- **Privacy:** the widget reads chore data from the on-device App Group only — no
  new data collection or transmission, so the App Store privacy labels are
  unchanged. The widget's `PrivacyInfo.xcprivacy` (added above) covers its
  UserDefaults access.
