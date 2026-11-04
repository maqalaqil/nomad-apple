# PDF Workshop native regression

From the repository root:

```sh
python3 apple/Tests/PDFWorkshop/run.py
```

The runner compiles the actual portable PDF engine with the host macOS SDK. Vision
and NSFileCoordinator need normal local system-service access; a restricted process
sandbox may fail before the recognizer runs. No network, user PDFs or device are used.

The 71 checks validate output semantics instead of only checking that an export call
returned: searchable/extractable hidden Unicode text, visual preservation and selection
bounds across crop/rotation variants, redacted output's image-only resource structure,
masked pixels and failed OCR recovery, original preservation, filled-form flattening,
annotations, watermarks, selected numbering, PNG order, text pagination, HTML escaping,
invalid/oversized files, symlinks and cancellation removing its partial output.

PNG artifacts in `/tmp/nomad-pdf-workshop` show the redacted, searchable and annotated
fixtures and are visually inspected. See `App/Tools/PDF_WORKSHOP.md` for limits and the
honest upstream feature comparison. Hardware/Pencil/Files-provider UI acceptance remains
separate from these native engine tests.
