# Native local inventory

The native inventory supports names, locations, whole-number quantities, notes, tags,
manufacturer/model/serial details, purchase date/value/currency, warranty expiry and
optional minimum stock. Search includes identification fields, tags and attachment
names. Lists filter by location, tag, low-stock state or expired warranty, and sort by
name, update time or quantity. Low stock means quantity is **at or below** the configured
minimum. There are no remote notifications or exchange-rate calculations.

Photos and PDF receipts are copied into app storage when the item is saved. Selected
images are decoded with orientation correction, resized to at most 2,048 pixels, and
encoded as JPEG with a white background and no original image metadata. Only the first
frame is used. PDF receipts retain their original bytes; protected receipts can be
exported for opening with their password. Pending attachments are held in the editor
until Save, so Cancel does not leave stored draft files. Removal and replacement require
explicit UI confirmation. Saved attachments can be previewed and exported individually.

## Storage and compatibility

Live metadata remains at `Application Support/NOMAD/Collections/inventory/inventory.json`.
On a volume that reports case-insensitive names, existing directory-entry spelling is
reused (for example, the simulator’s existing `Nomad` root). No directories are renamed.
Case-sensitive volumes retain their distinct existing store paths.
Version 1 item records are decoded with empty/default new fields, then upgraded to
version 2 on the next successful save. UUIDs and old names/locations/notes/quantities
remain unchanged. Versions other than 1 or 2 are rejected.

New version 2 fields:

| Field | Stored value |
| --- | --- |
| `tags` | Unique case-insensitive string list |
| `serialNumber`, `model`, `manufacturer` | Strings |
| `purchaseDate`, `warrantyExpires` | Optional Foundation JSON dates, same convention as existing `updatedAt` |
| `purchasePrice` | Optional canonical nonnegative decimal string, at most 12 whole and 4 fractional digits |
| `currencyCode` | Three uppercase letters; old records default to `USD` |
| `minimumStock` | Optional nonnegative whole number |
| `attachments` | Descriptor array described below |

Each attachment has `id`, `name`, `fileExtension`, `byteCount`, `sha256`, `addedAt`.
Extensions are exactly `jpg`, `png`, or `pdf`. Its immutable relative file path is
`attachments/<lowercase UUID>.<extension>`; user-supplied names never become local paths.
All IDs, formats, sizes and hashes are validated. Attachments are unique across items.

Portable JSON uses `{version:2, items:[...], files:[{id, data}]}`, where Foundation's JSON
encoder represents file data as Base64. It includes every referenced attachment, and
rejects missing, duplicate, extra, mismatched or malformed files before replacing live
state. Old version 1 JSON without `files` imports normally. Live manifests never contain
embedded file bytes. This format is not a Homebox database or CSV import.

The whole-app backup catalog captures the entire inventory folder, including attachments.
It uses `InventoryValidation.archive` for the shared production metadata rules and checks
attachment references rather than restoring metadata with missing payloads.

## Limits and failure behavior

- 10,000 items; quantity/minimum from zero through one billion.
- Name and identification fields up to 1 KB, location 2 KB, notes 64 KB.
- At most 100 tags per item, 128 UTF-8 bytes per tag.
- At most 20 attachments per item, 20 MB per selected file and 100 MB of attachment
  bytes in the entire inventory. Imported photo dimensions are at most 8,192 pixels;
  newly selected photos are normalized to 2,048 pixels.
- Live encoded metadata is limited to 20 MB; portable JSON to 200 MB.

File reads are coordinated, bounded, regular-file-only, and do not follow final-component
symlinks. Exclusive file creation avoids overwriting an unrelated UUID collision. A failed
save removes only files created by that attempt. Existing metadata and attachment bytes
remain intact. Metadata is atomically committed before obsolete attachments are unlinked;
failed cleanup leaves an unused copy and a visible message, rather than losing referenced
data. A corrupt/missing manifest with retained attachment data fails closed. A second stale
store cannot overwrite newer metadata. Per-item stale editor checks prevent lost edits.

Import decoding and image preparation run in cancellable worker tasks. Dismissed views
reject stale completion. Final bounded metadata/attachment commit and export assembly are
synchronous and may briefly block UI for a large inventory. A process interruption before
metadata commit may retain an unreferenced attachment copy; automatic orphan deletion is
deliberately avoided. Hardware/filesystem failure recovery is not guaranteed by these tests.

## Homebox baseline and remaining gaps

NOMAD pins `ghcr.io/sysadminsmedia/homebox:0.26.2`. The official
[entity schema](https://github.com/sysadminsmedia/homebox/blob/v0.26.2/backend/internal/data/ent/schema/entity.go)
and [attachment schema](https://github.com/sysadminsmedia/homebox/blob/v0.26.2/backend/internal/data/ent/schema/attachment.go)
were audited at tree `e01dd737238a3fa7e1a6454b37de6c6fc88c86e4`.
The native fields and attachment workflow cover everyday local inventory work, not full
Homebox parity. Fractional quantities, entity/location hierarchies, custom fields/templates,
asset and QR labels, insured/archived/sale records, lifetime warranties, maintenance logs,
multi-user groups/roles, shared storage, remote notifications, CSV/database interoperability
and server APIs remain unimplemented. Minimum-stock filtering is a native convenience.

## Tests

Run `python3 apple/Tests/InventoryRegression/run.py` on macOS with local file-coordination
access. The 46 production-engine checks cover old-format migration, new metadata persistence,
image normalization, source preservation, complete portable attachment roundtrip, malformed
imports, limits, symlink/collision protection, metadata-write rollback, stale stores,
deletion ordering and corrupt/missing manifests. All fixtures are synthetic and temporary.
The full Inventory SwiftUI module is separately typechecked against the iOS 26.5 SDK.
Physical Files sheets, photo previews and large-inventory responsiveness still need device
acceptance after bulk downloads are finished.

## Native macOS

Inventory now uses native AppKit PDFKit for receipt previews on Mac, while keeping
UIKit PDFKit on iPhone/iPad. Forms, file import/export, image normalization, record
validation, and attachment storage use the same engines. Native macOS and iOS UI
scopes typecheck, and all 46 storage/import/rollback checks pass. Real macOS
sandbox file-provider dialogs remain a separate signed-app acceptance check.
