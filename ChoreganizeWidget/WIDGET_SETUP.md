# Today's Chores widget — Xcode setup

The widget code is written, but a widget is a separate **app-extension target**
that must be created in Xcode (it can't be added by editing files alone). These
are the one-time steps. ~10 minutes.

## 1. Create the widget target

1. Xcode → **File ▸ New ▸ Target… ▸ Widget Extension**.
2. Product Name: **ChoreganizeWidget**. Team: same as the app.
3. **Uncheck** "Include Live Activity" and "Include Configuration App Intent"
   (this widget uses `StaticConfiguration`).
4. Finish → **Activate** the scheme when prompted.
5. Xcode generates a template `ChoreganizeWidget.swift` (+ assets) in a new
   group. **Delete the generated `.swift`** (move to Trash) — we ship our own in
   the `ChoreganizeWidget/` folder. Keep the generated `Assets.xcassets` and
   `Info.plist`.

## 2. Add our sources to the widget target

Add these files (already in the repo) to the **ChoreganizeWidget** target:

- `ChoreganizeWidget/ChoreganizeWidget.swift`  (bundle + widget + provider)
- `ChoreganizeWidget/TodayChoresView.swift`    (the view)
- `Choreganize/WidgetShared.swift`  ← shared with the app. In the File
  Inspector ▸ **Target Membership**, check **both** `Choreganize` and
  `ChoreganizeWidget`.

If you used "Add Files…", make sure *Target Membership* is the widget target for
the first two, and **both** targets for `WidgetShared.swift`.

> Do **not** add `WidgetSnapshotWriter.swift` to the widget — it's app-only (it
> reads Core Data). The widget only ever reads the published snapshot.

## 3. Add the App Group to BOTH targets

For **each** of the `Choreganize` app target and the `ChoreganizeWidget` target:

1. Signing & Capabilities → **+ Capability ▸ App Groups**.
2. Add / check the group **`group.com.svk.Choreganize`**.

This must match `WidgetShared.appGroupIdentifier`. Until both targets share it,
the app's snapshot write and the widget's read are safe no-ops (the widget shows
its placeholder / "No chores today").

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
- iOS 17+ for `containerBackground(_:for:)`. Deployment target is iOS 26, so fine.
