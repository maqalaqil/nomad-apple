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

The paid individual publishing team and App Store Connect access were verified, and iOS/macOS records were created. The existing installed bundle identifier is selected locally for upgrade continuity; personal team settings remain outside Git. At this stage no build had been uploaded to TestFlight or submitted for review; later upload results are recorded below.

Version 0.3.0 build 8 adds original iOS/macOS icons, an offline policy view, a public support/privacy contact, required-reason API declarations, Mac category/copyright metadata and archived llama dSYMs. iOS and universal native Mac Release archives built with Apple Development signing. Deep/strict signature checks passed; both contained icons, privacy files and matching framework dSYM UUIDs. This is local archive verification, not App Store distribution signing or server-side validation.

The unlicensed MathJax wrapper was replaced by an independently written Apache-2.0 adapter using pinned MathJax/Speech Rule Engine packages. Twenty-one real WebKit checks passed, covering math geometry, colors, chemistry, Arabic text, assistive MathML/spoken labels, macro isolation, malformed/oversized inputs and local-only resources. The full course renderer smoke test also passed original scoring, answer restoration, keypad edits, hints, local Graphie/fonts/speech maps, blocked HTTP and unsupported-item rejection. The rebuilt bundle passed 393-file integrity verification and has no packages lacking both a declared license and notice in its conservative npm inventory. That inventory result is not blanket binary-distribution clearance.

All 34 portable core tests passed again. Final App Store collection/export declarations, GPL corresponding-source/distribution decisions, review materials and physical offline acceptance remain open as described in [release readiness](APP_STORE_READINESS.md).

Both final archives were rebuilt after the math fixes. Their 397 Perseus-directory files match the prepared source bundle byte-for-byte, and their bundled policy matches the published document. Deep/strict signatures, matching llama dSYMs for every platform architecture, and the Mac App Sandbox entitlement were verified again. [GitHub CI for the release-preparation commit](https://github.com/maqalaqil/nomad-apple/actions/runs/42160955792) passed portable Swift tests and project generation. App Store Connect now retains the iOS/Mac descriptions and manual-release settings, plus the shared privacy-policy URL; this does not constitute submission.


## Store assets and sample review workflow — 5 November 2026

Version **1.0 build 9** adds an optional, original CC0 sample library (two text documents and one EPUB), displayed native/web open-source notices, a larger iPad reader sheet and compact iPhone EPUB toolbar controls. The sample files imported and indexed through the production library path on isolated iPhone/iPad simulators and an isolated sandboxed native Mac app. The EPUB opened on all three. The final compact iPhone toolbar was visually checked and captured after the simulator rebuild. These examples contain no user documents.

All **21 actual-app screenshots** were accepted by App Store Connect: seven each for iPhone, iPad and Mac. Dimensions and SHA-256 hashes are in [APP_STORE_SCREENSHOTS.json](APP_STORE_SCREENSHOTS.json). They show the dashboard, library, original reading/notes/source selection, actual local text conversion, bundled IT Tools and module navigation. The Mac AI screenshot records a real on-device Foundation Models response using sample text and visibly retains its missing-numbered-citation warning; it is not a staged model response or proof of general answer quality. No image generation or UI compositing was used. macOS captures include system window chrome.

Both platform listings retain review instructions describing the sample import path, separate content/model downloads, hardware-dependent AI, and feature limits. Contacts, free pricing, France exclusion, 16+ rating and EU non-trader status are saved. Those listing operations do not submit an app.

The iOS simulator Release build and isolated native Mac Release build passed. All **34 portable Swift core tests** passed again with zero failures. All **19 native source/build archives** passed SHA-256 verification. The source/notices inventory is reproducible; no byte-for-byte source rebuild equivalence or App Store GPL exception is claimed. Production-identity archive verification is recorded separately below.


## Distribution packaging follow-up — 6 November 2026

Both production-identity 1.0 (9) archives built successfully. Deep/strict signature verification passed, the native Mac sandbox entitlement is present, and all platform slices have matching llama dSYM UUIDs. Bundled samples, 23 upstream native notices, notice manifest and policy match the source bytes. The archived Mac code was also opened in an isolated, ad-hoc-signed test copy with a separate bundle identifier: the libzim COPYING notice appears in search and its full GPL text opens.

Initial local App Store exports obtained Cloud Managed distribution signing and produced both packages. Inspecting the generated `AppStoreInfo.plist` exposed a product-analysis error (`-21411` / `-67062`) for the loose IT Tools Python build-integration script, despite the export command returning success. That script is build documentation, not runtime app code. The fetch script now preserves it byte-for-byte in `nomad-build-integration-source.zip`, updates its integration notice and retains the pinned upstream source archive. The 286-file IT Tools integrity check passes; comparison confirms no runtime JavaScript, CSS or other functional asset changed. The regenerated Excalidraw integrity check also passes (243 files). Both corrected archives were rebuilt and re-exported successfully. Their final `AppStoreInfo.plist` reports contain no product errors; the loose script is absent and its ZIP is present. Deep/strict archive signatures, 286 IT Tools resource hashes, native notice/sample bytes and dSYM UUIDs passed again. The IPA uses Cloud Managed Apple Distribution with `get-task-allow = false`. The Mac export includes arm64 and x86_64 with App Sandbox enabled; its App Store installer signature verifies. These are local export checks, not server-side upload validation or TestFlight acceptance.

[CI for the screenshot/sample/notices commit](https://github.com/maqalaqil/nomad-apple/actions/runs/42172360310) passed. This is not App Review approval, a completed privacy label or permission to distribute the GPL combination through the Store.

Final packages are retained locally under `artifacts/app-store/iOS-1.0-9-verified` and `artifacts/app-store/macOS-1.0-9-verified`, with checksum/verification records. Earlier exports without the `-verified` suffix contain the superseded source-packaging issue and must not be uploaded. At this stage no binary had been uploaded to Apple or published on GitHub; subsequent private Apple uploads are recorded below.

[CI for the final packaging correction](https://github.com/maqalaqil/nomad-apple/actions/runs/42240549064) also passed portable core tests and project generation. Distribution licensing, provider/privacy declarations, export classification and physical/TestFlight acceptance remain open.

## Repeatable local release checks — 6 November 2026

[verify-release.py](../apple/scripts/verify-release.py) now checks the production archives **and apps extracted from the actual verified IPA/PKG**, without installing or modifying them. The run passed for 1.0 (9): release identity, deep/strict signatures, Mac universal architecture and sandbox, distribution debugging disabled, llama dSYM UUIDs, exact policy/manifest/sample/notice bytes, package checksums, no package-analysis errors, and all 21 screenshot hashes/dimensions. Each of the four app copies passed the five web-tool inventory checks: CyberChef 134, IT Tools 286, Excalidraw 243, Maps 1,078 and Perseus 393 files. The script also rejected the known product-analysis errors in both superseded exports during a separate negative check.

```sh
python3 apple/scripts/verify-release.py \
  --report artifacts/app-store/local-preflight-1.0-9.json
```

Run on macOS with Xcode tools and access to the system trust services; a restrictive automation sandbox can prevent certificate trust evaluation. The report is local and ignored by Git. The script accepts version/build/artifact-directory overrides, but the matching export checksum record and screenshot manifest must also exist. Exit success means local integrity checks passed, never permission to upload or Apple acceptance. It does not run a distribution app, contact App Store Connect, or submit declarations.

The existing CyberChef WebKit smoke harness was additionally run against **the final Mac archive's resources**, not just the prepared source directory. Its 505-operation catalog loaded; Base64, SHA-256, reverse, gzip round trip, Jq WebAssembly and ROT13 produced expected outputs. Document and worker remote fetches were blocked; the native blob download matched expected bytes. The harness uses nonpersistent browser data and temporary original test content. It does not exercise every algorithm, an installed App Store application, physical iOS hardware, or a disconnected device restart.

## Release acceptance handoff

These remaining checks have not been marked passed. They should use an isolated test library and the exact eventual distribution build, preserving the user's existing documents.

| Check | Procedure and acceptance result |
| --- | --- |
| Fresh install and upgrade | After distribution clearance, install through TestFlight on iPhone, M1 iPad and native Mac; verify the sample import/EPUB/tool path. Upgrade a test workspace containing notes, bookmarks and downloads; confirm preserved records and file hashes. Intel Mac execution needs separate hardware coverage. |
| Prepared offline operation | Prepare small licensed ZIM, map and model fixtures plus both translation directions. Disconnect networking, force quit and reopen, then read/search an article, render local maps, generate local tokens and translate real text in both directions. Repeat after device restart. Record outputs, not just language readiness. |
| Missing assets | In a fresh isolated library, attempt AI, translation and maps without content/models. The app must give an actionable preparation/import message without claiming assets are ready. |
| Permissions and files | Deny camera/microphone when explicitly invoking their tools; cancel file pickers and exports. Verify graceful recovery and unchanged data. Exercise Files/Finder exports, native Mac vault authentication and selected-file sandbox access. |
| Downloads and storage | Use small public fixtures: pause, relaunch, resume, interrupt networking and reject a checksum mismatch. Verify preserved verified payloads and disk-capacity rejection. Test iOS background completion separately from Mac reopen reconciliation. |
| Backup and restore | Export an isolated workspace, verify files/checksums, restore it and confirm records after the required quit/reopen. General backups are unencrypted; vault recovery is separately encrypted. Never overwrite the user's production workspace as a test. |
| Accessibility | Check VoiceOver labels/navigation, large text, keyboard focus and light/dark appearance on each supported platform. Screenshot acceptance does not establish accessibility. |

TestFlight is the project's distribution-test step, not a claim that Apple mandates beta testing before App Review. Apple upload processing, final declarations and rights review remain prerequisites in the documented release sequence.

## Private Apple uploads — 6 November 2026

Following the publisher's request to proceed with release work, both corrected production archives were exported with `destination=upload`, automatic signing on the selected individual team, symbols included and automatic build-number changes disabled. Xcode reported **Upload succeeded** and **EXPORT SUCCEEDED** for both iOS and macOS. This was a private technical-processing step; no testers were invited and no app was submitted for review or released.

App Store Connect initially showed iOS 1.0 (9) as Processing. It subsequently became selectable with **Missing Compliance** and was saved in the iOS release draft. The Mac build also processed with **Missing Compliance** and was saved in its release draft. TestFlight's description, feedback email, public policy/marketing links and original sample-based review instructions were saved. Private review contact details remain only in App Store Connect.

The iOS and macOS **Add for Review** actions each returned **Unable to Add for Review** with three specific requirements: Content Rights Information, build export-compliance information and App Privacy answers. Manual release remains selected. No licensing, collection, exemption or rights certification was supplied to bypass these requirements. Upload acceptance does not establish App Review approval, useful TestFlight execution, or distribution clearance.

Local upload logs are retained under `artifacts/app-store/upload-iOS-1.0-9.log` and `upload-macOS-1.0-9.log`. Export checksum records describe the earlier local exports; the upload command repackages the archive, so their hashes are not asserted to identify the transmitted package. The public repository contains source and status documentation, not the app binaries.

## Submission recheck — 7 November 2026

After Apple sign-in was restored, both platform drafts still showed version 1.0 build 9 with Missing Compliance and manual release. Add for Review was attempted separately for iOS and macOS; both returned Unable to Add for Review for Content Rights Information, export compliance and App Privacy. Neither platform entered review. The authorized encryption question was submitted through Apple Developer Support and its case-creation confirmation was verified. Case details are retained locally, not in this public repository. Provider privacy questions have also been sent; no answers or clearances are inferred from sending them. No binary, declaration or metadata was changed during this recheck.
