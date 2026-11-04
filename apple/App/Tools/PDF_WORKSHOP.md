# Native PDF Workshop

This module uses PDFKit, Core Graphics, Core Text, ImageIO and Vision on the device.
It has no server, subprocess, CDN, model download or network fallback. User-selected
iCloud/third-party Files items may still need their provider to download them before
the coordinated local read; import them before going offline.

## Implemented workflows

- Existing PDFKit merge, selected-page extraction/reordering, split, clockwise rotation,
  embedded-text extraction, JPEG optimization and password-protected copies remain.
- Searchable OCR renders selected scans for Vision, redraws every visible source page
  into a new PDF, then adds an invisible Core Text layer. Source vector artwork is
  retained through PDF drawing; visible annotations are flattened. Pages with embedded
  text are skipped to avoid duplicate text. Unselected pages and page order remain.
- The editor allows rectangles on any page, with per-page counts, undo and a final
  confirmation before permanent redaction. **Every output page is rasterized**, and
  the masks are painted into those pixels before embedding the sole image. No source
  PDF page objects, original text, metadata, forms, attachments or annotations are
  copied. The exported file is reopened and rejected if it contains text or annotations.
- Visible freehand signatures/ink, rectangle highlights and text notes are flattened
  into a new PDF. These do **not** authenticate the signer or provide certificate
  signing, trusted timestamps or signature validation. Exporting edited pages can
  invalidate existing digital signatures.
- Selected PDF pages export to PNG in requested order. Images import as letter-size
  PDF pages with orientation correction and fit-to-page sizing; only the first frame
  of animated or multipage image files is used. UTF-8 text becomes a paginated,
  searchable PDF. Extracted text exports as plain text or escaped, self-contained HTML;
  HTML preserves text rather than the original page layout. No Office/HTML layout
  conversion is advertised.
- Watermarks and bottom-center page numbers apply to selected pages; numbering follows
  the selection order. Flattening redraws visible forms/annotations into noninteractive
  pages. These operations preserve embedded source text and are **not redaction**.
- Outputs can be reopened as a new workbench input for a second operation. Every export
  creates a copy; imported files are never overwritten.

## Geometry and OCR limits

Editor selections use normalized top-left coordinates in the **visible rotated crop
box**. PDFKit applies the original crop origin and page rotation when drawing; export
normalizes that visible page to a zero-origin media box with rotation zero. Vision's
bottom-left normalized rectangles map into that same page. Core Text glyph-path bounds
are fitted to the recognized line rectangle; invisible text uses the actual PDF text
drawing mode, not white or transparent visible text.

Page count, visible orientation, crop geometry and content are preserved, rather than
the source's internal box/rotation dictionaries. Core Text provides Unicode font
fallback. Native tests cover Latin, Greek, Cyrillic and Japanese extraction; they do
not establish every font/script/language combination. Vision language availability
depends on the OS. Users can enter recognition language tags or use automatic detection.
Skewed lines, vertical text, right-to-left reading order, ligatures, tables and complex
non-Latin layout need review. There is no deskew/cleanup engine, no certified reading
order and no guarantee that OCR recognizes every sensitive word.

Redaction masks include a one-pixel outward margin to cover antialiasing at selection
edges. Users must select all sensitive pixels themselves; this is not automatic PII
detection. Raster output loses resolution beyond its bounded render size, searchable
text and interactive structure. It deliberately has no replacement OCR layer that
might accidentally reintroduce redacted text.

## Bounds and lifecycle

Inputs are coordinated regular-file reads with symlink rejection and an extra-byte
limit check. PDFs are limited to 150 MB each, 300 MB of workbench inputs, 50 input files
and 500 pages per document/merged output. Individual generated PDFs and split/image
batches are limited to 150 MB. Raster redaction and OCR are limited to 100 pages;
PNG export and image-to-PDF use at most 50 images. Text input is at most 2 MB and extracted
text/HTML at most 8 MB. Image input is at most 32 MB per file. Page dimensions and all
rectangles/ink points are validated; output images have at most 4,096 pixels per side
(normal page rendering uses 2,800).

New operations run on private document snapshots in a worker task, release page-sized
objects in autorelease pools, write PDFs to unique temporary files, and check cancellation
between pages/recognition calls. A generation token prevents a dismissed view from
accepting stale asynchronous output. Failed/cancelled PDF exports remove their temporary
file and retain prior successful work. Vision/ImageIO/PDFKit calls are not forcibly
interrupted midway through a single page. Existing synchronous PDFKit assembly and
password/optimization calls remain bounded by the workbench limits.

## Upstream baseline audit

NOMAD's service seed pins `ghcr.io/stirling-tools/s-pdf:2.13.1`. The corresponding
[official tool registry](https://github.com/Stirling-Tools/Stirling-PDF/blob/v2.13.1/frontend/editor/src/core/data/useTranslatedToolRegistry.tsx)
was inspected at tree `956b8000e4e3d395f1a8643b40058b5e5e24867b`, along with its
[OCR controller](https://github.com/Stirling-Tools/Stirling-PDF/blob/v2.13.1/app/core/src/main/java/stirling/software/SPDF/controller/api/misc/OCRController.java)
and [redaction controller](https://github.com/Stirling-Tools/Stirling-PDF/blob/v2.13.1/app/core/src/main/java/stirling/software/SPDF/controller/api/security/RedactController.java).
The native module does not claim complete Stirling parity.

| Upstream surface | Native status |
| --- | --- |
| Read, merge, extract, reorder, remove pages by extracting the complement, split, rotate | Implemented within the listed bounds; no chapter/size/bookmark split engine. |
| OCR | Searchable PDF and text implemented using Vision; no OCRmyPDF/Tesseract deskew, cleaning, language-pack parity or renderer options. |
| Manual redaction | Implemented as confirmed raster-mask output; no text-pattern/regex automatic redaction. |
| Sign, add text, annotate | Visible ink, text and highlights implemented; no shared signing workflow or cryptographic claims. |
| Watermark, page numbers, flatten | Implemented; watermark is text-only, numbering is bottom-center, flattening uses visible appearances. |
| Compress, passwords | PDFKit JPEG optimization and protected output exist; no full qpdf/Ghostscript compression or permissions editor. |
| Convert | PDF→PNG, images→PDF, text→PDF, embedded/OCR text→plain text/escaped HTML implemented. Office, PDF/A, EPUB, spreadsheet/table, vector, video and layout-preserving HTML conversion are absent. |
| PDF text/image editing; add images/stamps; crop, scale, poster/booklet/N-up/overlay/single-page layouts | Not implemented by this module. |
| Metadata/outline editing; attachments; embedded-image extraction; blank/image/annotation removal; form design/fill UI/unlock | Not implemented as dedicated workflows. The preview can display PDF forms; only explicit flattening is tested here. |
| Repair, scanner splitting/effects, contrast/colors, comparison, auto rename | Not implemented. |
| Certificate signing/validation/removal, trusted timestamp, PDF verification, permissions, JavaScript inspection | Not implemented. Ordinary PDFKit reopen validation is not a certificate or PDF/A validator. |
| Server APIs, watch folders, pipelines/automation, SSO, collaboration | Not implemented; outputs may be manually chained in the local workbench. |

Apple primary references: [PDFPage drawing](https://developer.apple.com/documentation/pdfkit/pdfpage/draw(with:to:)),
[invisible PDF text mode](https://developer.apple.com/documentation/coregraphics/cgtextdrawingmode/invisible),
[Vision recognition](https://developer.apple.com/documentation/vision/recognizing-text-in-images),
and [normalized recognition bounds](https://developer.apple.com/documentation/vision/vndetectedobjectobservation/boundingbox).

## Validation

Run `python3 apple/Tests/PDFWorkshop/run.py` from the repository root on macOS with
local Vision and file-coordination access. The 71 checks compile the actual portable
engine, create synthetic PDFs, reopen outputs and inspect both image and PDF structure.
They cover actual Vision OCR, invisible selectable text, Unicode fallback, crop offsets
and all four rotations, irreversible masked pixels, OCR recovery attempts, absence of
font/form XObjects and metadata in redacted output, visible marks, form flattening,
conversion/page order, bounds, coordinated reads, symlink rejection and cancellation
cleanup. Rendered artifacts are in `/tmp/nomad-pdf-workshop` for visual inspection.

The complete PDF UI typechecks against the iOS 26.5 simulator SDK. These tests do not
replace physical iPad pencil gestures, Files-sheet export, long multi-page memory and
accessibility acceptance. No physical-device test was run during bulk content downloads.

## Native Apple UI

The same PDF/Vision/CoreGraphics engine now serves native macOS and iOS views.
macOS uses an AppKit PDFView representable; iPhone/iPad retain their UIKit PDFView.
The normalized SwiftUI markup canvas accepts pointer, touch, and Pencil input.
Both platform UI scopes typecheck, and the 71 native PDF output/geometry/OCR checks
pass. Native file-dialog interactions and physical Pencil/pointer acceptance are
separate from these engine checks.
