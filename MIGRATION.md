# CloudKit Record Migration

The initial versions of Choreganize stored the entire application state in a single `AppState` record in CloudKit.  In order to improve merge behaviour and reduce sync conflicts, the data model now stores separate records for each `Chore`, `Area` and `Completion`.  A lightweight `AppState` record remains as the root of the share and provides a single point for update notifications.

## Migration Steps

1. **Update the application** – install an app version that understands the new record types.
2. **First launch** – the app fetches the existing `AppState` record.  If the JSON blob is present it is decoded and every `Chore`, `Area` and `Completion` is written back to CloudKit as its own record.  The old JSON payload is then cleared.
3. **Subsequent launches** – the app loads individual records directly and continues syncing using the updated APIs.
4. **Sharing** – existing shares continue to work because the `AppState` record is still the share root.  New child records are added to the same share and inherit permissions.

No manual user action is required.  Once all collaborators run the updated app the migration is complete.
