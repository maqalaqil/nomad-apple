# Native Notes

Notes is a standalone offline notebook, not the Flatnotes Docker service. The upstream NOMAD service is pinned to `dullage/flatnotes:v5.5.4` in `admin/database/seeders/service_seeder.ts`. Its [versioned README](https://github.com/dullage/flatnotes/blob/v5.5.4/README.md), [tagging guide](https://github.com/dullage/flatnotes/wiki/Tagging), [search guide](https://github.com/dullage/flatnotes/wiki/Advanced-Searching), and [image support guide](https://github.com/dullage/flatnotes/wiki/Image-Support) were checked on 2026-11-04.

## Implemented workflows

- Create, edit, search, share and reopen local notes. The raw Markdown remains editable; Save commits it atomically. The app follows the iPad's light/dark appearance.
- Read-only native Markdown preview: headings, paragraphs, emphasis/inline code/links, fenced and indented code, quotations, simple bullet/numbered/task lists and horizontal rules. No browser scripts or remote image requests. External links require explicit confirmation.
- Tags derive from `#hashtags` outside fenced, indented and inline code, without changing saved note data. Native support extends the upstream ASCII tags to Unicode letters, numbers and marks, including Arabic and mixed scripts. Underscores and hyphens are accepted; Latin letter case is ignored.
- Search supports case/diacritic-insensitive text, quoted phrases, implicit/explicit `AND`, `OR`, unary `NOT`, `title:`, `content:`, `tags:` and `#tag`. AND binds before OR. A tag query without wildcards matches the whole tag. `*` and `?` match characters within a whitespace-delimited word; this is not the Whoosh tokenizer. `NOT tags:*` finds untagged notes. Unsupported field/group/range syntax produces guidance instead of silently dropping it.
- Sort by title, creation or edit date. Save the current query as the Notes home view. These preferences use `notes.sort` and `notes.homeQuery` in UserDefaults; they are convenience settings, separate from note content.
- `[[Note title]]` links open matching active notes locally. Duplicate titles show a choice. The originating editor stays open with its draft intact. Missing targets are reported; links are not rewritten on rename.
- Import UTF-8 `.md`, `.markdown` and `.txt` files from Files, or a notebook JSON export. Reads use security-scoped access and coordinated, bounded regular-file access. A review sheet precedes the additive merge. Exact title/body duplicates across active notes and trash are skipped; conflicting identifiers receive new UUIDs. No existing record is overwritten.
- Export one draft as an unchanged Markdown body, all active notes as a folder of Markdown files, or the complete notebook including trash as JSON. Filenames are sanitized, bounded in UTF-8 bytes and disambiguated without changing the exported body. A Markdown file's filename supplies its title when imported. JSON preserves identifiers and dates; Markdown does not.
- Delete moves notes to persistent trash. Restore and permanent deletion are explicit, and nothing is automatically purged. Notebook JSON exports include trash; Markdown folder exports include only active notes.
- Editors compare their original record before saving or deleting. A removed note cannot be recreated by a stale editor. Conflicts leave the draft open, with reload and save-as-copy choices. The manifest's SHA-256 snapshot guards against another store or backup operation replacing the file; failed writes do not update in-memory records.

## Storage and compatibility

The existing path remains `Application Support/Nomad/Notes/notes.json`. The JSON keeps `formatVersion: 1`, the existing `notes` array, and unchanged `LocalNote` fields (`id`, `title`, `body`, `createdAt`, `updatedAt`). The additive `trash` array defaults to empty when reading older notebooks. Date encoding remains Foundation's default numeric reference-date representation. `NotesArchive.decode(_:)` is the shared validator for notebook import and module backup.

There are no attachment files or new backup paths. Notebook limits are 64 MiB of encoded JSON, 10,000 notes including trash, 2 MiB UTF-8 body per note, and 2 KiB UTF-8 title. Invalid metadata, duplicate IDs, nonregular/dangling-symlink manifests and unsafe roots fail closed. Reload preserves prior readable in-memory notes and leaves the original on-disk file untouched on failure. Recovery of a damaged manifest uses a previously exported notebook/module backup; Notes never silently resets it.

Imports accept at most 1,000 files / 64 MiB per batch. Queries are limited to 1,024 characters / 64 tokens. Preview displays at most the first 120,000 characters and 1,000 blocks, with a visible notice when truncated; editing and export retain the complete body.

## Remaining Flatnotes parity

This is not full Flatnotes feature parity. Still absent are WYSIWYG editing, complete GFM rendering (including tables and nested lists), attachment upload/paste/drop/display, a watched folder of externally editable Markdown, the complete Whoosh query language (date expressions, grouping, stemming and fuzzy matching), upstream keyboard shortcuts, a web REST server, and server authentication/read-only/user/2FA modes. Flatnotes image attachments are an actual upstream feature, not an assumed extra. Remote images and embedded HTML are not rendered. Customized home behavior currently means a saved search, not every upstream homepage configuration. Individual Notes preferences are not part of the notebook JSON archive.

## Validation

From the repository root:

```sh
swift test --package-path ipad --filter NotesStoreTests
```

Nine focused tests cover legacy schema, CRUD/reload, empty text, failed writes/corrupt preservation, trash restore/permanent deletion, stale editors/deletion/other store writes, additive import ID collisions and duplicate handling, UTF-8 and file-type rejection, bounds/unsafe symlinks, Arabic/mixed-script tags and Boolean/phrase/field/wildcard search, and Markdown block parsing.

Physical iPad SDK typecheck (no installation):

```sh
xcrun swiftc -typecheck -swift-version 5 -warn-concurrency \
  -target arm64-apple-ios26.0 \
  -sdk /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.5.sdk \
  -module-cache-path /tmp/nomad-notes-ios-cache \
  ipad/Sources/NomadCore/LocalStorage.swift \
  ipad/Sources/NomadCore/LibraryModels.swift \
  ipad/Sources/NomadCore/NotesStore.swift \
  ipad/App/Library/NotesView.swift
```

The existing `testNoteSurvivesColdLaunch` accessibility labels (`New note`, `Note title`, `Note text`, `Save`) are retained. Integrated UI testing is coordinated by the parent agent. New Files-provider import/export and nested wikilink sheets still need integrated simulator/device acceptance; SDK typechecking and persistence tests are not evidence that those gestures were exercised on hardware.
