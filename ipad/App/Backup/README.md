# Native backup and restore

`BackupView()` exports selected native stores to a version 1 `.nomadbackup` **folder** in Documents/Backups. Copy the complete folder using Files. It is not a ZIP file and is **not encrypted**: documents, conversations, source excerpts and settings remain readable. Vault passwords are never accessed; use Vault's separate encrypted recovery export.

The folder contains `manifest.json` and `Payload/<component>/<relative-path>`. The manifest records the app version, creation date, component/content selections, exact file lengths and SHA-256 digests. Digests detect damaged or changed bytes; they do not authenticate the publisher. Only import a backup you trust.

## Registered native stores

Paths below are relative to Application Support unless explicitly marked Documents. Case reflects the existing module paths. On a volume explicitly reporting case-insensitive names, registered directory lookup preserves the existing spelling (for example `Nomad` when a legacy module requests `NOMAD`). It does not rename folders, create them during export/review, or follow symbolic links. Case-sensitive volumes retain distinct directory names.

| Component | Saved state | Optional large content |
| --- | --- | --- |
| Notes | `Nomad/Notes/notes.json`, including recoverable trash when present | — |
| Inventory | All `NOMAD/Collections/inventory`, including metadata and attachments | Attachments always included |
| Sketchbook | All `NOMAD/Collections/sketches`, including editable drawings | Drawings always included |
| Files workspace | All Documents/Workspace files and folders | Workspace files always included |
| Dashboard | `NomadPad/dashboard.json` | — |
| Apple assistant | `NomadPad/assistant-conversations.json` and retained `assistant.json` | — |
| GGUF | `NomadPad/GGUF/{conversations,chat,benchmarks}.json` | `Models/` |
| Knowledge collections | `NomadPad/Knowledge/{collections,index}.json` | — |
| Custom catalogs | `NomadPad/Catalogs/catalogs.json`, including acquisition provenance | `Cache/` |
| Reading annotations | `NomadPad/ReadingAnnotations/marks.json` when present | — |
| Library | `Nomad/Library/library.json`, including extracted text | `Files/` archives, books and documents |
| Media | `NOMAD/Collections/media/library.json`, including playlists and progress | Imported media in the same folder |
| Courses | `NomadPad/Courses/learners-and-channels.json` | `Packages/`, including metadata, resources and licenses |
| Loose lessons | `NomadPad/Lessons/lessons.json` | Imported lesson files in the same folder |
| Vector maps | `NomadPad/PMTiles/workspace.json` | `.pmtiles` archives |
| Raster maps | `NomadPad/Maps/places.json` | `.mbtiles` archives |
| Drug reference | `NOMAD/Reference/dataset.json` | `.sqlite` dataset |
| Benchmarks | `NomadPad/Benchmarks/history.json` | — |
| Preferences | Explicit allowlist of assistant/GGUF, translation, EPUB, Notes sort/home-search and offline-preparation settings; EPUB reading positions | — |

Selection is by component. Optional content defaults off. Metadata-only library, media, courses, lessons, maps and reference backups require matching referenced content on the destination; the review blocks missing or wrong-sized dependencies. Include the content for a portable backup. A missing component file is not an instruction to delete a current file. Selected metadata files are replaced as complete records; this is not a record-by-record merge.

Excluded: all `NomadPad/Downloads` files, live/background transfers, resume data and pending verification; Keychain/Vault; existing backup/recovery folders; caches/temporary working files outside selected stores; unsaved web-editor/browser storage and cookies; system models, translation language downloads, app binaries, signing and permissions; files outside Workspace and the listed stores. Export web-tool documents to Workspace before backing them up. Temporary share/export files and diagnostic reports elsewhere in Documents are not included. This is not an iPad system backup or a complete upstream NOMAD server backup.

## Snapshot, validation and storage

The engine enumerates only registered paths and rejects symbolic links, special files, traversal, duplicate/case-colliding paths, file/directory conflicts, temporary import/delete paths and unsupported manifest versions. Copies use exclusive destination creation and 1 MiB buffers. Source inode/device, size, mtime and ctime are checked before and after reading, including the open descriptor. A changed file list or metadata snapshot aborts publication. This detects concurrent local edits; it does not lock every module for a database-wide transaction, so finish edits/imports before exporting.

Limits are 100,000 entries, 10 TB total, 32 MiB manifest and bounded native metadata reads. Export/staging preflight the full additional copy plus 512 MiB reserve; streaming rechecks free space every 64 MiB. Concurrent downloads can still consume free space between checks. Copy failures and cooperative cancellation remove the new partial staging/export and leave source/live files unchanged. Backup does not reserve or pause Downloads, and does not create hardlinks to mutable user data.

Review reads metadata before copying large content. Staging copies only selected components, verifies every selected file's length and SHA-256, and validates native metadata/dependencies. Conversation archives receive version/ID/role/settings/source validation; notes and optional trash use production `NotesArchive.decode` with disjoint IDs and text bounds; inventory uses `InventoryValidation.archive` and checks attachment SHA-256; reading marks use `ReadingMark.validate`. Other native schemas have component-specific envelope/reference checks, with their own stores retaining final format validation on load. Backup does not certify arbitrary media/archive/database content as usable or safe, or validate medical accuracy. Semantic indexes remain dependent on the destination's available embedding model.

## Cold-start activation contract

`BackupRestoreCoordinator.schedule` writes an intent under `NomadPad/BackupControl`; it never replaces active store data. Coordinator mutations share a process lock so two windows cannot replace each other's pending plan. Root must call `activatePendingRestore()` **once per process before constructing any normal store**, on a worker behind `WorkspaceStartupGate`. A second scene cannot activate a newly scheduled restore. Background DownloadStore reconnection is permitted because no backup path includes Downloads. The user closes all NOMAD windows and cold-launches to apply a scheduled restore.

Activation rechecks private staging integrity and dependencies, preflights every destination, then writes an activation journal. Each existing destination is renamed to that journal's `recovery-<UUID>/Old` before its replacement moves into place. Preferences are saved separately before replacement. Files absent from the package remain untouched. An interrupted/uncommitted activation rolls back at the next startup; a committed journal retains the restored state. An error must keep normal stores closed until recovery succeeds.

The UI can schedule an explicit rollback after a committed restore. It preserves displaced replacement files under `Displaced` and restores the older files/preferences. Empty directories created by an interrupted restore may remain. Recovery folders stay in Application Support until explicit cleanup; they are not automatically deleted or exported. A corrupt journal fails closed and requires recovery; it must never be replaced with an empty journal.

Explicit cleanup first persists the `discarding` phase, removes only the journal's staged and recovery folders, then removes the journal. Startup resumes interrupted cleanup idempotently. Unrelated stages, original backup packages and live data remain intact. Pending cancellation removes only the scheduled intent/stage. An interruption before intent/stage cleanup can leave an orphan staging folder; the engine never guesses that an unrelated folder is safe to delete.

The implementation is verified by native synthetic-fixture regressions and iOS SDK typechecking. Whole-app physical backup/restore and very large external Files-provider transfers require separate device acceptance; no such result is implied by engine tests.
