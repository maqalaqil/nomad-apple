# Reading marks and library maintenance

EPUB Reading Marks saves chapter/fragment, approximate scroll fraction, an optional selected quotation, and an editable title/note. Marks can reopen their saved location, be searched, edited, deleted after confirmation, or exported as JSON. Books also exposes all marks, including retained notes from deleted books. Reimporting a book creates a new file identity; notes are not silently reassigned. These are location-linked annotations, not permanent inline EPUB highlights or interoperable EPUB CFIs.

Marks live in `Application Support/NomadPad/ReadingAnnotations/marks.json`, with a 2,000-record / 32 MiB limit. Record validation bounds title, quote, note, paths and positions. Writes are atomic. Editors/deletion confirmations carry the original `updatedAt`; stale changes fail rather than replace a newer note. A manifest SHA-256 snapshot detects changes from another store/restore operation. Invalid and dangling symbolic-link manifests block writes and preserve the original. Backup registers this file independently from EPUB payloads.

```sh
xcrun swiftc -parse-as-library -swift-version 5 -warn-concurrency \
  apple/App/Library/ReadingMarkStore.swift \
  apple/Tests/ReadingMarksRegression/main.swift \
  -o /tmp/nomad-reading-marks-regression
/tmp/nomad-reading-marks-regression
```

This network-free regression passed persistence, book filtering, edit/delete behavior, invalid locations and text bounds, JSON export, stale editors/stores, failed writes, corrupt-file preservation and dangling links. EPUB reader integration typechecked against the iPad SDK. Selected-text gestures and scroll-position restoration still need physical-device acceptance at different font sizes.

The Library and Books context menus expose File Details with a display-title editor and a bounded re-index action. Library also offers a serial recheck of registered files. The existing library schema is unchanged. `LibraryStore.rename(_:title:)` changes metadata only; `refreshIndex(_:)` checks regular-file identity/size/modification date before and after extraction, preserves current titles during a refresh, and commits metadata only after success. Failed PDF extraction, missing/symlink files, cancellation and failed metadata writes preserve the previous record/search text. ZIM/EPUB payloads are not scanned or copied by this operation. Semantic index snapshots require revalidation/rebuild when passages change.

```sh
swift test --package-path apple --filter 'LibraryStoreTests.testDisplayRename|LibraryStoreTests.testRefresh|LibraryStoreTests.testFailedPDF'
```

Four targeted tests passed: unchanged content bytes/inode/mtime during rename and stale-title rejection; text/size refresh with renamed-title preservation; metadata-write/missing/symlink failure rollback; and retaining a good PDF index when the file can no longer be extracted. Original generated PDF content is used only in the temporary fixture.
