# Choreganize — CloudKit / iCloud DevOps Runbook

Practical notes for operating the CloudKit side of the app after the move to
`NSPersistentCloudKitContainer` (NSPCKC). Written so you don't have to hold the
Apple-infra details in your head. Container: **`iCloud.com.svk.Choreganize`**.

> Status: Phase 1 (private-store sync). Sharing sections are marked **(Phase 3)**
> and are previews of what's coming — not yet wired up.

---

## 0. Mental model (read this once)

- **CloudKit has three databases per container:**
  - **Private** — your own data. NSPCKC mirrors the app's local store here.
  - **Shared** — data *other people* shared *with you*. (Phase 3.)
  - **Public** — unused by this app.
- **NSPCKC owns its own schema.** It creates record types named `CD_<Entity>`
  (e.g. `CD_CDChore`) and stores everything in a single zone called
  **`com.apple.coredata.cloudkit.zone`** in your Private database. Your old
  hand-rolled types (`AppState`, `Chore`, `Area`, `Completion` in `OwnerZone-*`)
  are **separate and now unused** — see §5 for cleanup.
- **Two environments:** **Development** (what Xcode debug builds talk to) and
  **Production** (TestFlight/App Store). They have independent schema + data.
  Schema is promoted Dev → Prod manually (§4). **Data is never promoted.**

---

## 1. Prerequisites (one-time)

- Signed-in Apple Developer account in Xcode (Team `YV4K38KS29`).
- The iCloud container `iCloud.com.svk.Choreganize` exists (it does — it's in the
  entitlements). Confirm at <https://icloud.developer.apple.com/dashboard/>.
- On the test device/simulator: **Settings → signed into iCloud**, with iCloud
  Drive on. NSPCKC silently no-ops sync if there's no account (the app still
  works locally), so "nothing syncs" is usually "not signed in."

---

## 2. First run — let NSPCKC create the Development schema

NSPCKC creates record types **lazily** the first time matching records save. So
the simplest path is just:

1. Build + run a **debug** build on a device/simulator signed into iCloud.
2. Use the app so the importer writes records (Checkpoint 1 does this at launch).
3. Wait ~10–60s for the first sync.

To **force/verify** schema creation up front instead of waiting, there's a debug
helper: temporarily add `CoreDataStack.shared.initializeCloudKitSchemaForDevelopment()`
to `ChoreganizeApp.init` (after `JSONImporter.runIfNeeded()`), run once, confirm
the log line `CloudKit development schema initialized.`, then **remove the call**.
(It only ever touches the Development environment.)

---

## 3. Verify in the CloudKit Dashboard

<https://icloud.developer.apple.com/dashboard/> → select container
`iCloud.com.svk.Choreganize`.

**Schema is correct:**
- **Schema → Record Types**: you should see `CD_CDChore`, `CD_CDArea`,
  `CD_CDCompletion`, `CD_CDLockedDay`, `CD_CDHousehold`. Each has `CD_`-prefixed
  fields (e.g. `CD_name`, `CD_isDaily`) plus CloudKit system fields.

**Data landed:**
- **Data** tab → **Database: Private** → **Zone:
  `com.apple.coredata.cloudkit.zone`** → **Record Type: `CD_CDChore`** → Query.
  - If "Query" complains a field isn't queryable, query on `recordName` or the
    system field `___recordID` — NSPCKC doesn't mark every field queryable, and
    that's fine; the app fetches by `recordName`, not arbitrary queries.
- Seeing your imported chores here = the private-store pipeline works end-to-end.

**If records don't appear:** check (a) signed into iCloud on the device,
(b) Logs in-app (long-press the mode picker) for "Core Data store loaded
(CloudKit)" and importer counts, (c) Xcode console for `NSCloudKitMirroringDelegate`
errors, (d) you're looking at the **Development** environment in the dashboard.

---

## 4. Promote schema to Production (before TestFlight / App Store)

Production starts empty and **rejects unknown record types** — a TestFlight build
will fail to sync until you deploy the schema.

1. Dashboard → **Schema** → **Deploy Schema Changes…** (top right).
2. Review the diff (Development → Production), confirm.
3. Flip `aps-environment` in `Choreganize.entitlements` from `development` to
   `production` for release builds (Debug uses `ChoreganizeDebug.entitlements`,
   which stays `development`).
4. Re-deploy schema whenever you add/rename Core Data entities or attributes.

> Do this **after** the model is stable. Re-deploying is cheap, but you can't
> delete a field from Production once deployed — only add. Plan the model before
> the first Production deploy.

---

## 5. Clearing out old / stale CloudKit data  ⚠️ DevOps action

You have two generations of data in the container: the **old hand-rolled** types
and the **new `CD_*`** types. They coexist harmlessly, but you'll likely want to
purge the old ones for cleanliness.

**Option A — surgical (keeps new data):** Dashboard → **Data** → Private DB →
delete the old **zone** `OwnerZone-<hash>` (this removes `AppState`/`Chore`/
`Area`/`Completion` and any old `CKShare`). Leave
`com.apple.coredata.cloudkit.zone` untouched. Do this per environment.

**Option B — nuke Development entirely:** Dashboard → **Schema** (or the
container settings) → **Reset Development Environment**. This wipes **all** Dev
schema **and data**, old and new.
- ⚠️ **Sequencing:** this also deletes the new `CD_*` schema/data. If you reset,
  do it **before** relying on NSPCKC, then relaunch the app to let it recreate
  the schema and re-import. Don't reset after you've built up Dev data you care
  about.
- Production is unaffected by a Development reset.

**When you must do this:**
- Old `OwnerZone-*` shares are confusing collaborators → Option A.
- The new schema got into a bad state during development iteration → Option B,
  then relaunch.
- You changed the Core Data model incompatibly while iterating in Dev (NSPCKC is
  additive; renames/removals can wedge Dev sync) → Option B is the clean reset.

**Local reset (device side):** deleting the app removes the local store but
**not** the CloudKit copy — on reinstall it re-downloads. To truly start clean,
clear CloudKit (above) *and* delete the app.

> **Existing shares break with this migration.** The old custom-zone shares are
> abandoned; once Phase 3 lands, current collaborators re-accept a fresh invite.

---

## 6. Sharing & ownership — how it'll work  (Phase 3 preview)

What you've struggled with maps to these concrete pieces:

- **"Getting the share UI to show up"** = presenting `UICloudSharingController`.
  With NSPCKC the clean path is the `preparationHandler` initializer, which
  creates the `CKShare` for a `CDHousehold` via
  `NSPersistentCloudKitContainer.share(_:to:)` and hands CloudKit a *fully saved*
  share — the #1 reason the sheet fails to appear today is presenting a share
  whose root record hasn't been saved yet. We'll guarantee save-before-present.
- **"Determining ownership/sharing in the dashboard":**
  - **Owner** = the account whose **Private** DB holds the shared zone. In the
    dashboard you'll see the `CKShare` record and a custom zone in *their*
    Private DB.
  - **Participant** = sees that data via their **Shared** DB; nothing new in
    their Private DB. NSPCKC routes participant objects into the `.shared`
    persistent store automatically.
  - The dashboard shows participants + permissions on the share record.
- **Co-equal household** = the share is created with read-write permission, so
  every participant edits the same `CDHousehold` graph; "owner" is just who hosts
  storage (matches the agreed model).
- **Solo vs Household** in-app = objects with `household == nil` (Private store,
  unshared) vs objects under the shared `CDHousehold` (the owner's Private store
  if you host it, or your Shared store if you joined).

Background delivery for near-real-time sync needs the **`remote-notification`**
background mode (added in Phase 4) — without it, pushes don't wake the app.

---

## 7. Quick troubleshooting table

| Symptom | Most likely cause |
|---|---|
| Nothing syncs, app works locally | Device not signed into iCloud / iCloud Drive off |
| No `CD_*` types in dashboard | Looking at Production (use Development); or no records saved yet |
| TestFlight build doesn't sync | Schema not deployed to Production (§4) |
| Share sheet never appears (Phase 3) | Share/root record not saved before presenting |
| Participant sees nothing (Phase 3) | Share accept didn't import; `.shared` store not loaded |
| Old + new data both visible | Expected during migration — purge old zone (§5 Option A) |
