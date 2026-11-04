# Native course import and exercise support

This module imports actual Kolibri exported folders. It does not rename a custom
course format as Kolibri compatibility. The schema and package paths were audited
against Kolibri commit `da32925bce3cd216c4c5c0ecb7429314926f50c5`.

## Import

Select an exported `KOLIBRI_DATA` folder in Files, or its parent. It must contain:

```text
databases/<32-character channel ID>.sqlite3
storage/<first checksum character>/<second checksum character>/<MD5>.<extension>
```

Metadata comes from the original `content_channelmetadata`, `content_contentnode`,
`content_file`, `content_localfile`, optional `content_assessmentmetadata`, and
optional `content_language` tables. Titles, hierarchy, content IDs, attribution,
licenses, assessment IDs, language, randomization flag, and original mastery-model
JSON are retained. Read-only SQLite backup includes committed WAL transactions.
Imports stage locally, validate the schema and hierarchy, and check each copied
asset against its original MD5 before the confirmation step. Failed imports never
activate or replace an installed channel. Missing assets in partial exports are
reported. Source exports are never written to.

The installed folder retains the original SQLite database and content files plus
a derived `course.json` catalog. Sharing the original channel folder preserves
that database/resources layout. Learner profiles and progress are exported
separately as JSON; this JSON is a native backup/export, not Kolibri facility data.

Bounds: at most 100 channels per import, 512 MB per metadata database, 50,000 nodes
and 100,000 file references per channel, and 64 MB of decoded metadata rows. ZIP32
packages support stored and deflated entries, at most 1 GB compressed, fewer than
10,000 entries, 128 MB per expanded entry, and 512 MB expanded total. Encrypted,
split, ZIP64, symlink, duplicate, and traversal-path archives are rejected. ZIP
entries are served in memory; they are not extracted to arbitrary paths.

## Playback and progress

- PDF uses PDFKit; audio/video uses AVKit and checks whether the local codec plays.
- HTML5 ZIP loads `index.html`/`index.htm`, or a local launch resource from a simple
  IMS manifest. Only local assets can load. A deliberately limited SCORM bridge
  saves package-reported status, score, location, and suspend data. It does not
  claim full SCORM compatibility or implement the Kolibri custom-channel JS API.
- `.perseus` ZIPs use `<assessment_item_id>.json` entries. The pinned official
  Perseus renderer, migrations, widget registry, Kolibri numeric localization and
  scoring functions run locally. See `scripts/fetch-perseus` for pins, sources,
  licenses, and bundle reproduction. There is no substitute native answer scorer.
- Each local learner has separate completion, attempts, exercise answer state,
  hints, and exact scorer results. State is saved atomically. An unreadable
  manifest disables writes and preserves its original bytes.
- Native manual completion and individual exercise results do not imply Kolibri
  mastery. The original mastery model and randomization setting are preserved;
  selecting questions and recording exact results do not implement those policies.

## Explicit remaining integrations

H5P, QTI, Bloom, unsupported media codecs, the Kolibri custom-channel content API,
full SCORM tracking, mastery policies, automatic question selection, classroom
assignments/exams, coach reports, account authentication, facility sync and channel
updates are not implemented by this module. Perseus video/iframe, unknown and
deprecated stand-in widgets fail explicitly rather than being awarded a substitute
score. Built-in UI strings currently use English; content and numeric parsing use
the resource locale. Unsupported resources and their licenses remain exportable.

## Verification

Recorded November 3, 2026: **80 native engine checks** with the optional official
Kolibri metadata fixture, **7 production Perseus-host WebKit checks**, and **7
actual HTML5-coordinator WebKit/lifecycle checks** passed. These are macOS/native
harness results, not physical-iPad course acceptance. The signed app launches on
iPad14,6/iPadOS 26.5; real-channel device and airplane-mode checks remain pending.

`CourseTestRunner.py` creates disposable explicitly test-only SQLite exports and
ZIP files, and optionally imports the original fields from Kolibri's official
`content_import_test.json` fixture. It performs no network requests. It checks
staging, corruption rejection, atomic installation, checksum/path validation,
partial exports, per-learner persistence, exercise bridge validation, original
mastery metadata retention, deletion behavior, and failed-read write gates.

`CoursePerseusHostTestRunner.py` uses the production native WKWebView coordinator
with the unmodified official sorter test item. It verifies native scheme loading,
restored official scoring, state callbacks, package fetch, blocked external fetch,
and denial of main-frame navigation into imported content. It needs a built
Perseus bundle but performs no downloads or installs.

`CourseHTMLHostTestRunner.py` compiles the actual HTML coordinator directly from
its source, omitting only the UIKit wrapper. It exercises local JSON fetch, exact
SCORM state reporting, resume, blocked remote requests, canceled asset requests,
and dismissal while a background asset read is pending.

Sources:

- [Kolibri export documentation](https://kolibri.readthedocs.io/en/latest/manage/resources.html#export-from-kolibri-to-local-drive)
- [Audited schema](https://github.com/learningequality/kolibri/blob/da32925bce3cd216c4c5c0ecb7429314926f50c5/kolibri/core/content/contentschema/columns/content_columns_6.py)
- [Official Perseus](https://github.com/Khan/perseus)
