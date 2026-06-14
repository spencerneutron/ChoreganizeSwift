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
target's Build Settings set:

- `MARKETING_VERSION` = the app's (currently **1.2.1**)
- `CURRENT_PROJECT_VERSION` = the app's (currently **10**)

Keep them in sync going forward (a shared `.xcconfig`, or just bump both).

## 4. Run

1. Build & run the **Choreganize** app once on the device/sim. Foregrounding the
   app publishes the first snapshot (see `WidgetSnapshotWriter`, called from
   `ChoreganizeApp` on scene activate/background).
2. Long-press the Home Screen → **+** → search **Choreganize** → add **Today's
   Chores** (small or medium).
3. Complete/uncomplete a chore in the app, background it → the widget updates
   (the app calls `WidgetCenter…reloadTimelines`).

## Notes / deferred

- **Read-only for now.** Tapping the widget opens the app. Interactive
  completion (tap a chore in the widget to mark it done) needs an `AppIntent`
  that writes back into the shared store — a follow-up that requires giving the
  widget access to Core Data (or a write-back queue in the App Group).
- The widget shows the **active scope's** chores (Solo or the current
  household), because that's what the app snapshots. Switching scope in the app
  republishes on next foreground/background.
- `containerBackground(_:for:)` needs iOS 17+. The app's deployment target is
  **iOS 18.0**, so set the widget target to iOS 18.0 to match — fine either way.
- **Privacy:** the widget reads chore data from the on-device App Group only — no
  new data collection or transmission, so the App Store privacy labels are
  unchanged. The widget's `PrivacyInfo.xcprivacy` (added above) covers its
  UserDefaults access.
