# Validation scope

This is a development preview. Passing a build or a small fixture does not establish full NOMAD parity, sustained inference quality, all-content compatibility or App Store readiness.

## Public snapshot

The public repository retains test source and reproducible commands. Private device logs, screenshots, download manifests, signing records and local build output are intentionally not published. Historical results below are developer-reported; they are not accompanied by raw device artifacts in this repository.

## Checks repeated on the clean public snapshot

On November 4, 2026, all **34 portable Swift core tests passed with zero failures** from this independent checkout. Project generation succeeded and `plutil -lint` accepted the generated Xcode project. The dependency-free tests do not establish that every downloaded bundle builds from a fresh network cache, and no distribution archive was validated.

## Results recorded during development

- 34 portable core tests passed, covering local storage, notes, retrieval filtering and safe internal-download imports.
- Eight simulator UI tests passed in one integrated run. Two targeted Notes/Media follow-ups passed after later folder handling changes; these are distinct runs.
- Engine regression results included 140 backup, 76 reference, 71 PDF, 46 inventory, 38 conversation, 18 translation-state/variant, 10 storage audit, eight retrieval-freshness and eight callback-deadline checks. Additional suites and their commands are in [Tests](../ipad/Tests/README.md).
- A physical M2 iPad on iPadOS 26.5 completed local Apple Foundation Models and GGUF/Metal generation, semantic retrieval, small ZIM access, labeled local-map rendering and an isolated backup activation/rollback fixture.
- A 19.10 GB Arabic Wikipedia transfer passed its publisher SHA-256 verification, was saved in the library and was reported to open successfully by the tester. The tester also reported successful local AI use.
- A synthetic 19,095,710,684-byte recovery test exercised the production download verifier with approximately 3.75 MiB RSS growth. Other streaming regression checks cover course assets, ZIM resources, reference imports and backup copying.

## Still unverified

- Physical M1 performance and support across all intended devices.
- Airplane-mode cold launch and device-restart acceptance; the physical device remained online during recorded tests.
- Actual English/Arabic translation execution. Language readiness and successful translation are separate checks.
- Full English Wikipedia and worldwide-map download, import and rendering acceptance.
- Broad full-archive images/search, sustained model quality, memory pressure, background transfer interruptions and complete user-workspace restore through Files.
- App Store/TestFlight signing, archive validation, distribution licensing and App Review.

## Reproduce

```sh
swift test --package-path ipad
```

For app/UI tests, prepare dependencies and generate the project as described in the [build guide](../ipad/README.md), then select an installed iPad simulator in the commands in [Tests](../ipad/Tests/README.md). GGUF inference requires a physical iPad with the pinned framework. The repository's CI checks portable source; it does not certify physical offline operation.
