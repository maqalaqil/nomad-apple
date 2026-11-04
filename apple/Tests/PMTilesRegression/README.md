# PMTiles storage regression

Run from the repository root:

```sh
python3 apple/Tests/PMTilesRegression/run.py
```

The runner compiles the actual `PMTilesArchive.swift`, `InternalDownloadLink.swift`,
and `LocalManifestFile.swift` on macOS. It needs filesystem capacity and `NSFileCoordinator` services, which
may be unavailable inside a restrictive host sandbox. All files are synthetic
and temporary; no network or user maps are accessed.

Coverage includes coordinated copies across multiple 4 MiB chunks; exact copied
bytes; regular-file/symlink checks; canceled-copy cleanup; corrupt, duplicate,
missing, and conflicting workspace protection; validation before mutations;
manifest write failures; import rollback; staged deletion rollback; deletion
recovery both before and after the metadata commit; and interrupted import cleanup.
Internal download tests verify actual device/inode identity, exclusive link creation,
source and map deletion independently, metadata failure rollback, invalid headers,
wrong byte counts, unsafe source paths, and preservation of a pre-existing destination.

A sparse fixture has the world's catalog length, 134,812,420,554 bytes. The test
reads only its header and checks 64-bit ranges, then injects insufficient free
capacity and verifies rejection before any archive copy starts. It also imports
that sparse fixture through the internal download API with only 513 MiB of reported
free capacity, verifies both paths reference the same inode, and confirms the map
remains readable after removing the source path. This does not download, allocate,
copy, render, or validate the contents of the real world map.

External Files imports always copy in 4 MiB chunks with a per-chunk autorelease pool,
and require another archive-sized allocation plus a 512 MiB reserve. Only verified,
immutable completed downloads inside an app-owned source directory may use the
internal hardlink API. Unsupported/cross-volume links fall back to the same full-copy
preflight; hardlink savings are never assumed for external Files imports. The physical
device capacity preflight must run `InternalDownloadLink.probe(in:)` on app storage
before budgeting for shared bytes, and every actual import validates its own link.

These tests do not establish a full 135 GB import's time, battery use, provider
materialization cost, or behavior under actual iPad storage pressure. They cover
recovery at the app's staging/manifest boundaries, rather than promising recovery
from all hardware/filesystem failures. Physical iPad Files-provider and large-map
acceptance remain separate.
