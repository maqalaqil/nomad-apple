# Native inventory regression

```sh
python3 ipad/Tests/InventoryRegression/run.py
```

The runner compiles the real models, validation, attachment IO and storage transaction
with Foundation, Combine, CryptoKit, ImageIO and PDFKit. It needs normal local
NSFileCoordinator access, so a restrictive command sandbox may need elevation.

All files are synthetic and temporary. The 46 checks include actual version 1 decoding,
version 2 persistence, local photo normalization/metadata removal, exact attachment
export/import, failure preservation, bounded reads, symlink and exclusive-write
collision checks, a metadata write failure after staging bytes, stale manifests and
safe confirmed deletion, mixed-case default-root persistence and symlink-root rejection.
See `App/Collections/Inventory.md` for schema and limits.
