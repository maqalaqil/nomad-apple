# Native Drug Reference data contract

`MedicalReferenceView()` starts empty. No drug records, clinical answers, or synthetic example labels are bundled. All label text comes from user-selected files. The small situation catalog is copied unchanged from `collections/conditions.json` at upstream commit `54ee30a44902e5c252b477f8685c26ec3064ab72`; it contains search terms, not medical advice.

## Actual upstream distribution

The upstream NOMAD application downloads the official manifest at:

- [openFDA download manifest](https://api.fda.gov/download.json)
- [Drug labeling bulk-download page](https://open.fda.gov/apis/drug/label/download/)

The manifest entry is `results.drug.label`, containing `export_date`, `total_records`, and `partitions`. Each partition has `file` (an HTTPS `.json.zip` URL), `display_name`, `size_mb`, and `records`. Upstream code then streams the JSON records into **MySQL**, not a distributed SQLite database. There is no official NOMAD SQLite download implied by this module.

Authoritative repository references:

- `admin/app/jobs/download_drug_data_job.ts`: manifest URL, partition download and staging.
- `admin/app/jobs/ingest_drug_data_job.ts`: ZIP/JSON streaming ingestion.
- `admin/util/drug_labels.ts`: raw openFDA-to-NOMAD column mapping.
- `admin/database/migrations/1778600000004_create_drug_labels_table.ts`: label schema.
- `admin/docs/drug-reference.md`: label comparison is not a calculated drug-interaction checker.

## Supported import A: official extracted JSON

1. Download the desired official drug-label `.json.zip` parts while online.
2. Expand them in the iPad Files app.
3. Select the extracted **`.json`** files together in Drug Reference → Import.
4. Keep the app open while it streams, indexes and validates the new database.
5. Approve installation/replacement after the label count is shown.

Each file must be one complete openFDA envelope with a top-level `results` array of label objects; `meta` is read for `last_updated` when supplied. The bulk-download manifest itself is **not** a label data file and cannot be imported as one. ZIP extraction and in-app network downloading are not currently implemented here.

The reader holds one JSON record at a time, caps each record at 32 MB, and rejects malformed/truncated input. It maps the same identity and label-section fields as NOMAD, joining section arrays with two newlines. No section summary or medical interpretation is generated. Records without a usable `set_id` are counted and skipped; if none remain, the import fails. Duplicate `set_id` values are matched case-insensitively, with later selected records replacing earlier records in the prepared dataset.

Selecting one part imports only that part. The UI explicitly discloses that imported data may be incomplete. Every import prepares a **new replacement dataset**, not a silent merge into the active dataset; select all desired parts in one operation. Keep free space for source JSON, the prepared SQLite database, and the active database until replacement succeeds.

## Supported import B: compatible SQLite snapshot

Accepted extensions: **`.sqlite`**, **`.sqlite3`**, and **`.db`**. This is an interoperability format for native exports or correctly converted upstream data, not the upstream download format.

The database must contain a regular, non-virtual `drug_labels` table with an integer-valued primary-key `id` and all these columns:

```text
id
set_id
spl_id
version
brand_name
generic_name
manufacturer
product_ndc
route
product_type
searchable_name
indications
dosage
warnings
boxed_warning
drug_interactions
contraindications
when_using
stop_use
source_updated_at
```

`set_id` must be nonempty for each record. `id` must be the primary key; every stored identifier must have SQLite integer type. Text columns may be null. A case-insensitive unique `set_id` constraint is strongly recommended, and is created by native JSON ingestion. SQLite import does not require a MySQL `FULLTEXT` index. `ingested_at` and other extra columns are permitted but not required.

Optional provenance table:

```sql
CREATE TABLE dataset_metadata (key TEXT PRIMARY KEY, value TEXT);
```

Recognized metadata keys are `source`, `source_url`, and `export_date`. The native JSON importer also writes `imported_at`. These fields are **declared provenance**, not an authenticity guarantee; the UI never independently certifies a user-supplied file as FDA data. Missing source/date fields are explicitly shown as unknown/not supplied.

Imports open the original database read-only with trusted-schema behavior disabled, validate the schema and SQLite `quick_check`, and use SQLite's backup API to capture a consistent local snapshot rather than copying a possibly incomplete WAL-backed main file. The original database is not edited. The snapshot is revalidated before the user can activate it.

## Persistence and queries

- Data lives under `Application Support/NOMAD/Reference/`.
- Each prepared database has a unique filename. `dataset.json` is an atomically replaced pointer to the selected validated database.
- JSON ingestion uses a SQLite transaction. Invalid or cancelled imports cannot replace the active dataset.
- Label search and detail reopen the installed snapshot read-only. Search strings use bound parameters and escaped LIKE wildcards.
- Name search includes brand, generic name and `searchable_name`; indications search uses imported `indications` text. Results group by brand/generic and return one representative row, with a label count, for up to 100 groups.
- OTC filtering matches upstream `HUMAN OTC DRUG`. Situation browsing supports category/filter navigation through the 36 pinned condition groups, up to eight selected groups, and user-entered literal text groups. Each group OR-matches its alternative terms; all groups must match one label's indications before grouping and the 100-product limit. Removing/clearing a group changes the query immediately. Detail pages list pinned situation groups whose terms occur in that label.
- Situation intersection is a native **label-text** equivalent, not the upstream product-list algorithm: upstream `admin/inertia/pages/drug-reference/index.tsx` intersects brand/generic keys from separately limited 200-product situation lists, which can combine different labels of a product. Native matching requires one label to satisfy every group, then opens a representative matching label and counts only matching labels. It does not combine evidence across separate labels. Unlike upstream MySQL FULLTEXT ranking, native search uses escaped SQLite LIKE substrings and alphabetical ordering; Unicode case-folding behavior can differ. Negated or qualified mentions still match. No suitability/treatment inference follows from a match.
- Search terms are bound parameters, trimmed and deduplicated within groups, limited to 200 characters each and 20 alternatives per group. Invalid/empty/over-limit groups fail visibly rather than being silently truncated. Situation mode is OTC-only. Name and free-text indications modes retain their optional OTC filter. Query selection is transient UI state; database and `dataset.json` schemas are unchanged.
- Query work has a 30-second execution budget and cooperative cancellation checked inside SQLite's VM progress handler and around each result step. A cancelled UI search cannot publish stale results. SQLite lock waits retain the existing five-second bound. A too-broad search fails visibly instead of indefinitely blocking the module.
- Comparison shows the selected labels' actual boxed warnings, warnings, contraindications and drug-interaction sections. It does not calculate pairwise interactions, infer absent warnings, or declare combinations safe.

Affirmative natural/home-remedy content remains excluded. Upstream gates it off by default, and situation matching does not substitute for that corpus. Route filters, MySQL relevance/ranking and upstream per-situation fallback cards are not claimed as identical native behavior.

## Native engine regression command

```sh
xcrun swiftc -parse-as-library -swift-version 5 -warn-concurrency \
  -D NOMAD_REFERENCE_ENGINE_TESTS \
  ipad/App/Collections/CollectionStorageDirectory.swift \
  ipad/App/Reference/DrugReferenceDatabase.swift \
  ipad/App/Reference/DrugConditionCatalog.swift \
  ipad/App/Reference/DrugSituationSelection.swift \
  ipad/App/Reference/DrugReferenceEngineTests.swift \
  -lsqlite3 -o /tmp/nomad-reference-regression
/tmp/nomad-reference-regression
```

The harness uses only isolated, explicitly synthetic nonclinical fixtures. It tests JSON/SQLite import safety, original section retention, multi-group OR/AND behavior, matching within one label, filtering before result limits, grouped representative correctness, escaped wildcard/SQL-looking text, selection limits/clearing, and cancellation from inside a running SQLite VM scan. It does not certify the meaning or completeness of medical data.

Verified: **76 native engine checks passed**, and all Reference sources typechecked against the iOS 26.5 simulator SDK. The situation fixture has over 1,500 synthetic rows; none are included in the app.

Bulk JSON parsing, Foundation normalization and the SQLite insert callback now share one autorelease pool per label. SQLite uses copied text bindings; separators and retained source metadata remain outside the pool, and the existing 32 MiB single-label limit is unchanged. A separate `Tests/ReferenceMemoryRegression/run.py` test imported 50,000 synthetic nonclinical records (24,366,720 input bytes), checked exact counts/metadata/staging/search/source text, and observed 39,010,304 bytes of peak RSS growth on the development Mac. The 76 engine checks and physical iPadOS 26.5 SDK typecheck also passed after this change. This is not a real clinical-dataset or physical-device memory certification.

## Validation still required

The coordinating build must compile the module and exercise import/search/detail on real openFDA files and representative SQLite snapshots. Then verify offline cold launch, partial-dataset disclosure, corrupt/truncated files, cancellation, valid replacement, rejected replacement preserving old data, no-data states, query timeouts and uninstall cancellation on a physical iPad. No large dataset was downloaded during implementation.
