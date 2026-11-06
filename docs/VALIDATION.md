# Validation scope

This is a development preview. Passing a build or a small fixture does not establish full NOMAD parity, sustained inference quality, all-content compatibility or App Store readiness.

## Public snapshot

The public repository retains test source and reproducible commands. Private device logs, screenshots, download manifests, signing records and local build output are intentionally not published. Historical results below are developer-reported; they are not accompanied by raw device artifacts in this repository.

## Checks repeated on the clean public snapshot

On November 4, 2026, all **34 portable Swift core tests passed with zero failures** from this independent checkout. Project generation succeeded and `plutil -lint` accepted the generated Xcode project. The dependency-free tests do not establish that every downloaded bundle builds from a fresh network cache, and no distribution archive was validated.

## Results recorded during development

- 34 portable core tests passed, covering local storage, notes, retrieval filtering and safe internal-download imports.
- Eight simulator UI tests passed in one integrated run. Two targeted Notes/Media follow-ups passed after later folder handling changes; these are distinct runs.
- Engine regression results included 140 backup, 76 reference, 71 PDF, 46 inventory, 38 conversation, 18 translation-state/variant, 10 storage audit, eight retrieval-freshness and eight callback-deadline checks. Additional suites and their commands are in [Tests](../apple/Tests/README.md).
- A physical M2 iPad on iPadOS 26.5 completed local Apple Foundation Models and GGUF/Metal generation, semantic retrieval, small ZIM access, labeled local-map rendering and an isolated backup activation/rollback fixture.
- A 19.10 GB Arabic Wikipedia transfer passed its publisher SHA-256 verification, was saved in the library and was reported to open successfully by the tester. The tester also reported successful local AI use.
- A synthetic 19,095,710,684-byte recovery test exercised the production download verifier with approximately 3.75 MiB RSS growth. Other streaming regression checks cover course assets, ZIM resources, reference imports and backup copying.

## Native Apple platform port

The `apple/` source tree and generated **NomadApple** project now target iPhone and iPad on iOS/iPadOS 26+, and native Mac on macOS 26+. Mac Catalyst is not used. Existing bundle and persisted storage identifiers remain unchanged to protect upgrade continuity. The app uses a single workspace window on Mac and explicitly disables multiple iOS/iPadOS scenes; independent windows could otherwise race stores that retain manifest snapshots.

The unsigned physical iOS build passed with device families `[1, 2]` and an arm64 llama framework. The iOS simulator build also passed. All nine UI tests passed on each of the iPhone and iPad simulators in separate complete runs, covering inventory, backups, bundled catalogs, conversations, dashboard navigation, files, text tools and note/media persistence. Mac dashboard navigation, Base64 conversion and note persistence across relaunch passed as three selected workflows in separate runs after adapting the test selectors to AppKit accessibility.

After disabling multiple iOS/iPadOS scenes, the final device and simulator property lists were checked for `UIApplicationSupportsMultipleScenes = false`, both builds passed again, and targeted launch/dashboard/catalog tests passed on both iPhone and iPad simulators.

The final native Mac Debug build passed for both arm64 and x86_64. Its local ad-hoc signature passed deep/strict verification. Normal app entitlements include App Sandbox, selected-file access and client networking; verification used the normal app build without XCTest's temporary filesystem exceptions. Execution was on Apple silicon; Intel hardware is not validated. This local signature is not Developer ID notarization or App Store distribution signing.

Inside the normally sandboxed Mac app, built-in diagnostics completed local Foundation Models and GGUF generation, CPU/storage checks, sentence embeddings, hardlink-backed import, real ZIM access, PMTiles rendering and isolated backup activation/rollback. English/Arabic translation execution was skipped because those system language models were not installed on this Mac. Networking stayed enabled; these checks do not establish disconnected cold-launch acceptance.

Repeated port checks include 34 portable core tests, 140 backup, 76 reference, 71 PDF, 46 inventory and 433 vault engine checks. Production Mac WebKit checks passed for EPUB search/position persistence (12), HTML5 courses (7), Perseus (7), and bundled-tool conversion/network blocking/blob export. The course engine suite passed 78 checks. Native media playback/storage and Files safety regressions also passed. These isolated fixtures do not certify every document, codec or course package.

The Mac drawing/private-pasteboard harness passed 71 checks, including editable drawing round trips, nonblank PNG export, clipboard expiration ownership, and eraser geometry with curves, transforms, widths, masks and zoom. Signed user authentication in the Mac vault, native file-provider dialogs and long-session pointer/pen behavior still need acceptance testing.

The pinned native Mac GGUF framework generated tokens using both CPU and Metal in separate smoke runs, and CoreKiwix opened, read and searched a small real ZIM fixture. The iOS simulator has no GGUF inference slice. Neither a compiler pass nor a short generation demonstrates model quality or memory fit on every supported device.

All prepared offline bundles passed their integrity checks: CyberChef (134 files), IT Tools (286), Excalidraw (243), Maps (1,078), and Perseus (388). Dependency preparation requires internet access or a complete verified cache; prepared tools run from bundled assets.

## Still unverified

- Physical M1 performance and support across all intended devices.
- Airplane-mode cold launch and device-restart acceptance; the physical device remained online during recorded tests.
- Actual English/Arabic translation execution. Language readiness and successful translation are separate checks.
- Full English Wikipedia and worldwide-map download, import and rendering acceptance.
- Broad full-archive images/search, sustained model quality, memory pressure, background transfer interruptions and complete user-workspace restore through Files.
- App Store/TestFlight signing, archive validation, distribution licensing and App Review.

## Reproduce

```sh
swift test --package-path apple
```

For app/UI tests, prepare dependencies and generate the project as described in the [build guide](../apple/README.md), then select an installed iPhone/iPad simulator or native Mac destination using [Tests](../apple/Tests/README.md). GGUF inference requires a compatible physical iPhone/iPad or Mac with the pinned framework. The repository's CI checks portable source; it does not certify physical offline operation.

## Release packaging preparation — 5 November 2026

The paid individual publishing team and App Store Connect access were verified, and iOS/macOS records were created. The existing installed bundle identifier is selected locally for upgrade continuity; personal team settings remain outside Git. No build has been uploaded to TestFlight or submitted for review.

Version 0.3.0 build 8 adds original iOS/macOS icons, an offline policy view, a public support/privacy contact, required-reason API declarations, Mac category/copyright metadata and archived llama dSYMs. iOS and universal native Mac Release archives built with Apple Development signing. Deep/strict signature checks passed; both contained icons, privacy files and matching framework dSYM UUIDs. This is local archive verification, not App Store distribution signing or server-side validation.

The unlicensed MathJax wrapper was replaced by an independently written Apache-2.0 adapter using pinned MathJax/Speech Rule Engine packages. Twenty-one real WebKit checks passed, covering math geometry, colors, chemistry, Arabic text, assistive MathML/spoken labels, macro isolation, malformed/oversized inputs and local-only resources. The full course renderer smoke test also passed original scoring, answer restoration, keypad edits, hints, local Graphie/fonts/speech maps, blocked HTTP and unsupported-item rejection. The rebuilt bundle passed 393-file integrity verification and has no packages lacking both a declared license and notice in its conservative npm inventory. That inventory result is not blanket binary-distribution clearance.

All 34 portable core tests passed again. Final App Store collection/export declarations, GPL corresponding-source/distribution decisions, review materials and physical offline acceptance remain open as described in [release readiness](APP_STORE_READINESS.md).
