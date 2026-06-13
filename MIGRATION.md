# Data Migration

Choreganize moved from a hand-rolled CloudKit scheme (originally a single
`AppState` record, later per-record types in a custom `OwnerZone-*` zone) to
**Core Data + `NSPersistentCloudKitContainer`**.

## What happens on upgrade

- On first launch the app imports the legacy on-device `chore_data.json` into
  Core Data (`JSONImporter`), preserving UUIDs, then renames the file to
  `chore_data.migrated.json` as a backup. The import is idempotent — it never
  double-imports.
- Core Data then mirrors to CloudKit automatically: the private database for your
  own data, and the shared database for Households shared with you. See
  `CLOUDKIT.md` for the operational details (schema, dashboard, sharing).

## Legacy CloudKit data

The old `AppState` records in the `OwnerZone-*` zone are abandoned —
`NSPersistentCloudKitContainer` uses its own `CD_*` record types and zones and
ignores them. They can be purged from the CloudKit Dashboard (`CLOUDKIT.md` §5);
doing so is optional.
