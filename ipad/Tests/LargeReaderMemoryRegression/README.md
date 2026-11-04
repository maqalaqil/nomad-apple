# Large course / ZIM reader memory regression

Run from the repository root on macOS with Xcode and the pinned CoreKiwix vendor framework available:

```sh
python3 ipad/Tests/LargeReaderMemoryRegression/run.py
```

The runner creates a disposable **256 MiB sparse zero-filled asset**, a small synthetic Kolibri export database referencing it, and an uncompressed real ZIM using the vendored libzim writer. No network, production course, user archive or physical device is used. Temporary source/output files and compiled binaries are removed when the runner ends.

Two separate processes exercise production implementations:

- `CourseChannelImporter.prepare` performs the actual metadata validation, staged content copy, per-chunk MD5 update, and final Kolibri checksum validation. The synthetic asset is deliberately not playable video; this checks import copying, not playback.
- `ZIMSchemeHandler` reads the actual archive through `NomadZIMArchive.mm` and serves the non-HTML entry to a `WKURLSchemeTask` test consumer. The consumer hashes and discards each delivered chunk synchronously. The final SHA-256, byte count and 256 KiB chunk bound are verified. This is the production bridge/handler path, not WebKit media playback or its internal buffering.

The fixes put the entire read/hash/write or read/synchronous-delivery iteration inside `autoreleasepool`. Foundation's `FileHandle.read` and the bridge's `NSData dataWithBytes:` can otherwise retain autoreleased buffers until the large job finishes. ZIM `deliver` uses `DispatchQueue.main.sync`, so the consumer completes while the chunk is alive; the pool then drains before the next chunk. It does not queue an unbounded list of closures retaining the bytes. Existing cancellation and error paths remain in place.

The harness samples both RSS and Darwin physical footprint. It fails if additional physical footprint reaches 96 MiB during the 256 MiB operation. RSS can include clean, reclaimable file mappings, so the retained-memory assertion uses physical footprint; both measurements are printed. This is a host-side regression bound, not a promised iPad memory budget.

Final run on 2026-11-04:

| Production path | Verified bytes | RSS growth | Physical footprint growth |
| --- | ---: | ---: | ---: |
| Course copy + MD5 | 268,435,456 | 8,634,368 | 5,210,184 |
| ZIM bridge + synchronous consumer | 268,435,456 | 1,622,016 | 835,584 |

The existing course harness also passed all **80 checks** with the previously obtained official Kolibri metadata fixture:

```sh
python3 ipad/App/Education/CourseTestRunner.py \
  --upstream-fixture /tmp/nomad-kolibri-audit/content_import_test.json
```

Without that optional external fixture, the existing harness runs its 78 synthetic checks. The physical iPad SDK typecheck passed with `-warn-concurrency`, including the actual ZIMReaderView bridge Sendable conformance and dependent translation views.

## Read-only audit boundaries

No matching unbounded chunk-read loop was found in library imports: completed downloads hardlink, external imports use `FileManager.copyItem`, and text extraction/preview reads once up to 2 MiB. GGUF model import reads a four-byte signature then uses `FileManager.copyItem`.

EPUB uses a mapped-if-safe archive capped at 2 GB and materializes entries capped at 64 MiB (HTML 16 MiB). This is bounded per-entry and is not a streaming EPUB memory guarantee. ZIM HTML is also bounded at 16 MiB. Remaining bounded FileHandle loops include the benchmark (64 MiB default, 256 MiB configured maximum), inventory attachment reads (20 MiB), and the parameter-bounded CollectionStorage selected-file reader (no current caller found). Those were not changed in this focused fix. Backup and DownloadStore memory fixes are covered separately by their owners.
