# Native regression checks

The [public validation summary](../../docs/VALIDATION.md) records development results through November 4, 2026. Counts below refer to historical runs of the named harnesses, not a fresh validation of every checkout. Private device reports, installation metadata, download progress and local result bundles are excluded. Airplane-mode cold launch, restart acceptance, M1 performance and complete feature parity remain unverified.

Run commands below from the repository root on macOS with Xcode and its command-line tools selected. Use Python 3.11 or later. WebKit tests require the prepared offline bundles from the [build instructions](../README.md); native GGUF/ZIM tests additionally require the pinned frameworks. Temporary executable paths in command examples are disposable output locations, not links to retained evidence.

Run portable storage and retrieval tests with `swift test --package-path ipad`. The historical suite passed **34 tests**, including an 18-test internal-download helper/library subset: hardlink inode/device identity, a 127 GB synthetic sparse archive without payload copying, source-removal survival, library deletion, atomic metadata rollback, corrupt-manifest preservation, unsafe/symlink/FIFO sources, existing destinations and probe cleanup. External imports retain independent copies. Synthetic archive sizes establish filesystem behavior, not full content validity.

The app-only download and EPUB components also have standalone macOS regression executables, so their data paths can be tested without an iOS simulator or background network transfer:

```sh
xcrun swiftc -parse-as-library -swift-version 5 \
  ipad/App/Downloads/DownloadStore.swift ipad/Tests/DownloadStoreRegression/main.swift \
  -o /tmp/nomad-download-regression
/tmp/nomad-download-regression

python3 ipad/Tests/EPUBRegression/fixtures.py /tmp/nomad-epub-fixtures
xcrun swiftc -parse-as-library -swift-version 5 \
  ipad/App/Library/EPUBArchive.swift ipad/Tests/EPUBRegression/main.swift \
  -o /tmp/nomad-epub-regression
/tmp/nomad-epub-regression /tmp/nomad-epub-fixtures
```

These tests use temporary files and original generated book content. They make no network requests. Download tests inject an ephemeral session and local held URL-protocol tasks, checking one active transfer/verification, oldest-first scheduling, authoritative exact lengths and SHA-256, queue storage reservations, pause/retry/removal/relaunch, legacy concurrent tasks, preserved manual pauses, stale callbacks, and manifest rollback. They also cover oversized HTTP length metadata and keeping a complete payload when pause races completion. They do not establish iPadOS background-transfer behavior across process termination or full 100+ GB downloads. EPUB tests verify both navigation versions, chapters/assets, standard font deobfuscation, unsafe and damaged archives, DRM rejection, and XML entity rejection. Device acceptance still needs real Files imports, EPUB reading-position gestures, rendering accessibility, background downloads, storage-pressure handling, and useful GGUF model performance.

The benchmark regression runs a short real CPU/storage workload, cancellation, cleanup, history reload/export, atomic write failure, and corrupt-history preservation:

```sh
xcrun swiftc -parse-as-library -swift-version 5 \
  ipad/App/Benchmarks/NativeBenchmarkEngine.swift ipad/App/Benchmarks/NativeBenchmarkStore.swift \
  ipad/Tests/BenchmarkRegression/main.swift -o /tmp/nomad-benchmark-regression
/tmp/nomad-benchmark-regression
```

The harness uses 1 MiB temporary test files. The app's documented default uses 64 MiB and a 2-second, single-worker SHA-256 phase, capped at 8,192 hashes. Volume capacity inspection must be available; a host sandbox that hides filesystem capacity will correctly reject the workload as unable to establish sufficient free space. App-level storage timings include synchronization for writes and SHA-256 verification for reads, and can be affected by the OS cache. They are not raw flash or desktop NOMAD scores.

The local semantic engine harness compiles the production NaturalLanguage engine and uses the system's installed sentence-embedding model. It checks real vectors and retrieval; model availability is device dependent:

```sh
python3 ipad/scripts/test-semantic-engine.py
```

GGUF document retrieval has a standalone production-code regression:

```sh
xcrun swiftc -parse-as-library -swift-version 5 \
  ipad/Sources/NomadCore/LibraryModels.swift ipad/App/Assistant/GGUFEngine.swift \
  ipad/App/Assistant/GGUFGrounding.swift ipad/Tests/GGUFGroundingRegression/main.swift \
  -o /tmp/nomad-gguf-grounding-regression
/tmp/nomad-gguf-grounding-regression
```

The pure tests passed active-source exclusions before result limits, bounded
question/passages, no-source rejection, citation mapping/warnings, and history
round trips with older chat compatibility. They inject a deterministic token
counter to exercise prompt fitting. A separate run linked to the pinned macOS
llama framework and used the tiny official Stories test model: the real chat
template/tokenizer fit the context, generated native tokens, and reported the same
prompt-token count as preparation. This
proves engine execution, not useful or correctly cited answers. The app fits up to
three active-source passages with the loaded model's actual tokenizer and persists
the exact supplied excerpts. Physical retrieval quality and a useful model remain
acceptance gates. Multiple saved conversations and per-session settings are now implemented; the separate conversation suite below covers their persistence and isolation.

The Files workspace regression covers import/copy/move/rename, preserved originals and name collisions, canonical-path confinement, symbolic links, self-moves, and root-delete refusal:

```sh
xcrun swiftc -parse-as-library -swift-version 5 \
  ipad/App/Files/FileWorkspace.swift ipad/Tests/WorkspaceRegression/main.swift \
  -o /tmp/nomad-workspace-regression
/tmp/nomad-workspace-regression
```

Workspace copy tests need volume-capacity inspection and file-coordinator access. As with benchmark tests, run them outside a host sandbox that hides those operating-system capabilities.

The media regression creates short silent WAV files, exercises real AVFoundation metadata and AVPlayer seeking/completion, and checks playlist/progress persistence:

```sh
xcrun swiftc -parse-as-library -swift-version 5 \
  ipad/App/Collections/LocalManifestFile.swift ipad/App/Collections/CollectionStorageDirectory.swift \
  ipad/App/Collections/CollectionStorage.swift \
  ipad/App/Collections/MediaLibraryStore.swift ipad/App/Collections/MediaPlaybackSession.swift \
  ipad/Tests/MediaRegression/main.swift -o /tmp/nomad-media-regression
/tmp/nomad-media-regression
```

It also checks version-one media archive migration, independent copied files, reset/completion state, atomic progress/deletion rollback, interrupted deletion recovery, playlist pruning, and corrupt-manifest preservation. Run outside a host sandbox that denies AVFoundation codec/media services or coordinated file reads. The native player retains AVKit embedded subtitle/alternate-audio controls. Caption tracks, video codec support, scrubbing gestures, and interruption behavior require acceptance on the target iPad. Playback intentionally pauses on background or dismissal; this implementation does not configure background audio, PiP, server streaming, or transcoding.

## Courses and exercise engines

```sh
python3 ipad/App/Education/CourseTestRunner.py
python3 ipad/App/Education/CoursePerseusHostTestRunner.py
python3 ipad/App/Education/CourseHTMLHostTestRunner.py
```

The course harness passed **80 checks** when also supplied Kolibri's official
`content_import_test.json` through `--upstream-fixture`; without that optional
fixture, its 78 synthetic structural/persistence checks run. It verifies actual
export schema and asset paths, atomic staging, hashes, corrupt-import preservation,
separate learners, stored exercise state, and finite/type/range validation of scores.
It never fabricates a medical or production learning dataset.

The production Perseus native host passed **7 WebKit checks** using the unmodified
official sorter test item. The actual HTML5 coordinator passed **7 checks** for
local fetch, limited SCORM state, resume, blocked remote requests, cancellation and
dismissal. These need the bundled renderer and macOS WebKit services. The broader
official-engine bundle tests and pins are in
[Perseus README](../Resources/WebTools/Perseus/README.md); supported formats and
remaining mastery/classroom/H5P/QTI/Bloom gaps are in
[CourseFORMAT.md](../App/Education/CourseFORMAT.md).

## Catalogs and large maps

Run `python3 ipad/Tests/CatalogRegression/run.py` for the catalog regression.
Twenty-four checks passed against the extracted production catalog parser and
temporary malformed copies. They cover exact-length/hash preservation, Boolean
and fractional size rejection, duplicate IDs, unsafe URLs, overflow, pending
queue bytes, and both full-collection capacity branches: **281,863,089,798 bytes**
when linking is supported, or **416,675,510,352 bytes** with an import copy.
This pure test injects probe results and verifies that models still reserve a copy;
actual filesystem linking is tested independently by `InternalDownloadLinkTests`. Catalog metadata verification does not
mean the complete archives have been downloaded or their contents validated.

Run `python3 ipad/Tests/PMTilesRegression/run.py` for map storage/recovery checks.
All **72 checks** passed. Its world-sized sparse fixture tests 64-bit header ranges,
insufficient-space rejection before copying, and an actual same-inode hardlink
with only 513 MiB of reported free capacity. Source/map deletion independence,
manifest failure rollback and unsafe-path/collision preservation are covered.
It does not copy/render the real 134.8 GB world archive;
see [PMTiles regression notes](PMTilesRegression/README.md).

## Physical diagnostic profile

A DEBUG launch with `--device-validation` runs a separate visible screen, without
initializing normal user stores. It records OS/hardware/RAM/storage/thermal state,
actual bounded CPU/storage measurements, a tiny filesystem-hardlink probe, installed NLEmbedding ranking,
FoundationModels availability and up-to-32-token generation when available, and
optional GGUF/ZIM/map tests and temporary backup activation/rollback. Fixtures are read from `Documents/Validation/model.gguf`,
`sample.zim` and `sample.pmtiles`; absent fixtures are skipped. The map probe uses the actual local handler/assets with HTTP(S)/WebSocket requests blocked and waits for completed symbol placement and records visible feature/text-symbol counts plus a screenshot. It also checks installed English/Arabic translation availability without requesting downloads. The backup probe uses isolated temporary records, not the user workspace. Results are written incrementally
and atomically to `Documents/nomad-device-report.json`.

The test engines use isolated instances and temporary storage; they do not modify
user libraries/chats. Cancellation unloads the dedicated GGUF engine after its
operation exits. Time limits request cooperative cancellation, not forced process
termination. Raw generated output/rankings are observations, not quality scores.
Historical physical diagnostics exercised available local engines, bounded CPU/storage work, fixture archive access, local map rendering and isolated backup activation/rollback. These observations do not establish sustained performance, arbitrary archive coverage or network isolation. Actual translation requires installed assets for the selected exact language variants and a successful translation in each direction; a supported-language readiness result alone is insufficient. See the [validation summary](../../docs/VALIDATION.md).

## Conversation and storage regression checks

```sh
xcrun swiftc -parse-as-library -swift-version 5 \
  ipad/App/Assistant/ConversationStore.swift ipad/Tests/ConversationRegression/main.swift \
  -o /tmp/nomad-conversations-regression
/tmp/nomad-conversations-regression

xcrun swiftc -parse-as-library -swift-version 5 \
  ipad/App/Shell/StorageAudit.swift ipad/Tests/StorageAuditRegression/main.swift \
  -o /tmp/nomad-storage-audit-regression
/tmp/nomad-storage-audit-regression
```

Thirty-eight conversation checks cover lossless legacy migration, independent sessions/settings,
rename/select/delete, JSON export/import, version rejection, corrupt/symlink preservation
and stale-writer conflicts. Ten storage checks verify hardlink deduplication, classification,
external-link exclusion, traversal bounds, JSON roundtrip and shared-file deletion behavior.
The download suite also verifies MIME-derived filenames for extensionless OPDS acquisitions
without changing URL provenance or accepting folder/control-character names.

The expanded PDF engine passes **71** native checks; commands, fixtures, bounds and
geometry/redaction assertions are in [PDFWorkshop/README.md](PDFWorkshop/README.md).
A historical two-case simulator run passed conversation rename/cold-launch and Supply Depot navigation.
These simulator checks do not replace physical-device or network-isolation acceptance.

Backup: **140 native checks** plus the actual create-backup UI case passed
(also included in the final eight-test integrated UI run). The physical isolated
activation/rollback fixture passed; whole-workspace Files-provider/restart acceptance remains pending. See
[BackupRegression/README.md](BackupRegression/README.md). Inventory: **46 checks**,
including compatible migration and complete attachment roundtrips; see
[../App/Collections/Inventory.md](../App/Collections/Inventory.md).

Retrieval freshness: eight focused checks verify that old vectors cannot resurrect changed,
removed, excluded or filename-only source passages; renamed source titles are refreshed.
The production hybrid search also reruns lexical retrieval after its asynchronous model call.

## Catalog and reading additions

Custom OPDS navigation/search/cache and Metalink resolution passed both malformed-input checks and real official Kiwix fixtures; see [OPDSRegression/README.md](OPDSRegression/README.md). The production ZIM DOM capture/apply/restore scripts passed real WebKit checks; see [ZIMTranslationRegression/README.md](ZIMTranslationRegression/README.md). Installed Apple language models were not invoked by that harness.

EPUB marks passed persistence, limits, corrupt-file, stale-editor/store and dangling-link checks. Four new library rename/reindex tests and the original fourteen LibraryStore cases passed; see [ReadingMarksRegression/README.md](ReadingMarksRegression/README.md). Physical gestures, reading-position restoration and actual translation remain separate acceptance cases.

The Notes engine passed nine focused tests and an iPad SDK typecheck; its supported Markdown/search/import/recovery contracts and remaining gaps are in [NotesREADME.md](../App/Library/NotesREADME.md). The historical portable suite passed **34 tests** on November 4, 2026.

Inventory's actual save/relaunch UI case passed in a separate historical simulator run. A volume-aware directory lookup fixes simulator Foundation's alternate-case path lookup without renaming existing directories.

The callback deadline helper passes eight checks for completion, timeouts, late/duplicate callbacks, cancellation before/during a wait, explicit cancellation and error propagation. The map probe has a visible cancel control and per-operation bounds within its overall deadline.

The final folder-compatibility change adds three Core tests covering both historical
folder creation orders, preservation on reopening, read-only lookup, and rejected
symlink/file roots. The final portable suite has **34 passing tests**; its iPad SDK
typecheck also passed. Media's production default-directory branch and real
AVFoundation playback/persistence harness passed again, as did all **40** native
safety checks. See [MediaRegression/README.md](MediaRegression/README.md).

Translation state and language-variant selection have **18 historical passing checks**: twelve deterministic async cases for changed pairs/text, out-of-order responses, cancellation and leaving the view, plus six cases for exact/same-language variant resolution. The resolver maps generic Arabic to an actually supported variant such as `ar-AE`, preserves an exact selection and never substitutes an unrelated language. These model-independent tests do not download or invoke translation models. Commands and physical preparation steps are in [TranslationStateRegression/README.md](TranslationStateRegression/README.md).

The historical integrated simulator run passed eight cases: inventory persistence, backup creation, catalog search, conversation rename, dashboard navigation, file rename, Base64 and note cold-launch persistence. Separate follow-up runs covered Notes cold-launch persistence and Notes → Media with another Media relaunch after folder compatibility changes. They are not one combined ten-case run. Rerun `ipad/UITests/NomadPadUITests.swift` through the generated NomadPad scheme with an available iPad simulator; simulator UI results do not replace physical Files-provider, accessibility, storage-pressure or network-isolation acceptance.

## Bounded-memory regressions

```sh
python3 ipad/Tests/DownloadStoreRegression/run.py
python3 ipad/Tests/LargeReaderMemoryRegression/run.py
python3 ipad/Tests/ReferenceMemoryRegression/run.py
python3 ipad/Tests/BackupRegression/memory.py
```

The download runner executes queue/lifecycle cases and a **19,095,710,684-byte sparse-file** recovery/verification test. A historical run completed with **3.75 MiB RSS growth**, preserving the payload inode, manually paused state and ready state after relaunch. Temporary Foundation buffers drain per 1 MiB read/hash. The test does not transfer a large file over the network or establish iPadOS background scheduling. See [DownloadStoreRegression/README.md](DownloadStoreRegression/README.md).

The course/ZIM runner exercises the production checksum-copy path and real CoreKiwix resource delivery with a 256 MiB generated fixture. Historical RSS growth was approximately **8.3 MiB** for course copying and **1.6 MiB** for ZIM delivery, below the harness's 96 MiB growth bound. It requires the pinned macOS CoreKiwix slice; see [LargeReaderMemoryRegression/README.md](LargeReaderMemoryRegression/README.md). Reference and backup memory harnesses use their own temporary inputs and thresholds; inspect their README and runner before reserving test disk space. All reported timings and memory observations are machine/workload-specific rather than performance guarantees.
