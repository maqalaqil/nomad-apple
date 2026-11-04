# NOMAD Apple build and offline-use guide

An independent native iPhone, iPad and Mac adaptation of Project NOMAD. This is a development preview with incomplete feature parity. See the [project overview](../README.md), [feature matrix](FEATURE_PARITY.md) and [App Store readiness](../docs/APP_STORE_READINESS.md).

## Build

Prerequisites: a Mac with Xcode containing the iOS 26 and macOS 26 SDKs, Python 3.11+, and Node 22+/npm for the offline web bundles. Initial dependency preparation needs internet access; the built tool interfaces do not.

From the repository root:

```sh
sh apple/Vendor/fetch-corekiwix.sh
sh apple/Vendor/fetch-llama.sh
python3 apple/scripts/fetch-web-tools.py
python3 apple/scripts/fetch-web-editors.py
python3 apple/scripts/fetch-map-assets.py
python3 apple/scripts/fetch-perseus.py
python3 apple/scripts/generate-project.py
open apple/NomadApple.xcodeproj
```

The generated Xcode project includes the Swift/Objective-C++ sources, SQLite, static CoreKiwix, bundled web tools, catalogs and the platform-specific llama framework. iPhone/iPad target iOS/iPadOS 26+ with device families `1,2`; native Mac targets macOS 26+ through AppKit and SwiftUI. Mac Catalyst is disabled. Watch, TV and Vision platforms are not targets. Regenerate it after adding source files. Resource folders are copied individually into the platform’s bundle resource directory. Do not add a second manually nested `Resources` folder; macOS already uses the normal `Contents/Resources` bundle layout.

Choose the **NomadApple** scheme in **NomadApple.xcodeproj**, select an iPhone, iPad or **My Mac** destination, and configure **Signing & Capabilities → Team** with your own development account and a bundle identifier you control. The public source defaults to `io.github.maqalaqil.nomadpad`; this legacy bundle identifier and existing storage keys/folder names are preserved for data compatibility. Project/scheme names have changed to NomadApple. Retain your installed app’s bundle identifier when upgrading; changing it creates a separate application/container. The generated project stays untracked. Build and run. The project generator preserves your selected team and bundle identifier. For physical iPhone/iPad development testing, a free Apple ID Personal Team is suitable, but its provisioning profiles expire after **7 days**, requiring another signed installation; see [Apple's account limits](https://developer.apple.com/help/account/basics/about-your-developer-account/). Development signing and TestFlight are not permanent offline distribution arrangements; the final distribution method, expiry behavior and third-party license obligations remain release gates. No signing identity or provisioning profile is stored in this repository.

A simulator build does not need signing:

```sh
xcodebuild -project apple/NomadApple.xcodeproj -scheme NomadApple \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath apple/DerivedData CODE_SIGNING_ALLOWED=NO build
```

A native Mac build can be checked separately:

```sh
xcodebuild -project apple/NomadApple.xcodeproj -scheme NomadApple \
  -destination 'generic/platform=macOS' \
  -derivedDataPath apple/MacDerivedData CODE_SIGNING_ALLOWED=NO build
```

These unsigned build commands check compilation/linking; they do not validate a distribution archive or the behavior of a properly signed release. The Mac target includes [App Sandbox entitlements](App/Platform/NomadApple-macOS.entitlements) for user-selected files, outgoing network requests, camera and audio input. Exercise file access, web tools and permission prompts in the signed sandboxed application before release.

The official pinned llama framework has no iOS simulator slice. Simulator builds expose model-management UI but report inference unavailable. Physical iPhone/iPad and native Mac use their corresponding framework slices. Short production-engine CPU and Metal generation checks passed on the development Mac; useful model quality, memory fit and hardware coverage need separate testing. Apple Intelligence availability depends on the device and installed system model.

## Prepare a device for offline use

1. Install and launch the app while connected. Confirm the installation's signing validity for your intended trip.
2. In **Downloads**, browse the Arabic/English Wikipedia, worldwide/regional-map and small-model catalogs, or add a direct HTTPS file URL. Cellular transfers are disabled; iPhone/iPad preparation uses Wi-Fi, while Mac can use its available non-cellular network connection. Downloading and verification are serialized. On Mac, keep the app running for reliable progress and completion handling: it does not relaunch itself for background URLSession events, and reconciles any retained transfers when reopened. Official exact byte lengths and SHA-256 values are enforced when provided; older regional entries remain estimates. Paused entries stay paused. Catalog preflight includes pending transfers and a 512 MiB reserve. On filesystems that pass the local hardlink probe, completed verified ZIM/PMTiles downloads activate without another full copy; unsupported linking retains the full-copy capacity check. External Files imports still copy. The worldwide map has no published SHA-256, so exact size/format checks do not establish cryptographic integrity.
3. Import completed content into its module. The library reads local ZIM archives, EPUB books, PDFs and text. Maps supports compatible PMTiles and raster MBTiles. Education imports exported Kolibri channel folders as well as individual lessons. Models use compatible decoder-only GGUF files. Drug Reference accepts extracted official openFDA JSON parts or its documented SQLite schema. Other modules use their own system file pickers (Files on iPhone/iPad, Finder-backed dialogs on Mac).
4. Prepare Apple's translation languages before disconnecting. For Apple Intelligence, confirm that the system model is available. Alternatively, import a suitable local GGUF model and test it on the actual device.
5. Save/export important user data. Verified internal library/map downloads can share immutable storage; Files imports, models and other modules can create another copy. Deleting one shared file entry does not remove the other module’s file.
6. On iPhone/iPad, enable airplane mode and turn Wi-Fi off. On Mac, disconnect Wi-Fi, Ethernet and other network connections. Fully quit and reopen the app, then exercise the exact content and tools you will need. Repeat after restarting the device. Check maps at several zoom levels, ZIM images/search, model generation, exercises, media and exported files individually.

The cataloged full-image Arabic and English Wikipedia editions plus worldwide street map total **281.33 GB** (decimal). Initial preflight requires about **281.86 GB free** when checked hardlinks are available, including a 512 MiB reserve. The fallback requires about **416.68 GB free** for one largest import copy. Other user content requires additional space. This is selected article media and a street basemap; satellite imagery and routing data are separate.

The model catalog includes Qwen2.5-0.5B-Instruct Q4_K_M (491.4 MB), intended as a small starting point. A model file's storage size is not its runtime memory budget. Test model fit, response quality and thermal behavior on the actual device. No model or large knowledge library is bundled automatically.

## Native architecture

- **SwiftUI shell and local stores:** app navigation, documents, notes, media, inventory, lessons, drawing, settings and persistent state.
- **Knowledge reader:** CoreKiwix/libzim via a narrow Objective-C++ bridge; local WebKit article resources with external requests blocked. UIKit and AppKit reader hosts share the same engines. Mac EPUB adds native chapter search and an isolated-world scroll-position bridge; see [reader platform notes](App/Library/APPLE_PLATFORMS.md).
- **AI:** Apple's on-device Foundation Models API and a separate llama.cpp GGUF engine. No cloud inference fallback. Knowledge Collections builds local sentence embeddings and combines semantic and keyword retrieval for both assistants. GGUF library answers use up to three active-source passages, fitted with the loaded model’s actual tokenizer; the supplied excerpts and citation warnings persist with the answer. No matching sources means no model answer is generated. Indexing is bounded to 4,000 extracted passages; whole ZIM/EPUB contents are not indexed. Both assistants keep multiple named conversations, per-conversation source/context/generation settings, and validated JSON import/export. Migration preserves the old single-chat files, failed reads block writes, and conflicting saves cannot silently overwrite a newer archive. Library answers exclude prior conversation text and custom general-chat instructions; citation correctness still requires checking the sources.
- **Maps and courses:** locally served MapLibre/PMTiles with bundled fonts/styles, native raster MBTiles, and a validated Kolibri export importer with separate learner profiles and local progress. The complete pinned Perseus renderer scores supported exercises locally and saves answer/hint/result state. These are native workflows, not continuously running servers; Kolibri mastery/classroom parity and every widget/content format are not verified.
- **Web tools:** complete pinned CyberChef, IT Tools and Excalidraw distributions, served from local resources with network access restricted. Upstream operations that inherently contact online services cannot work offline.
- **PDF/translation/media/drawing/security:** PDFKit and Vision, Translation, AVKit and device-protected Keychain APIs, with platform-specific presentation. Sketchbook uses PencilKit on iPhone/iPad and a native AppKit canvas on Mac; drawing formats and input capabilities have platform-specific limits.
- **Data preparation:** persistent URLSession transfer queues, local catalog snapshots and explicit content imports. Supply Depot shows actual document/model/transfer counts; Device & Storage has a cancellable metadata-only report with hardlink-aware totals and bundled offline help. iOS/iPadOS controls background execution. Mac does not automatically relaunch for transfer callbacks; keep it running while preparing content and reopen it to reconcile interrupted transfers. No always-running service is promised.

Most module data is saved under private Application Support directories; the Files workspace lives in Documents. The vault uses a device-only Keychain item protected by device authentication and supports separate passphrase-encrypted recovery. See [Vault](App/Vault/README.md). Whole-app backup supports 19 native store groups, optional content, selective restore and retained rollback; Downloads, unsaved web-tool storage, Keychain and system-managed models are excluded. See [Backup](App/Backup/README.md). For restore activation on Mac, **quit with Command-Q and reopen**; closing windows alone does not restart the process. Whole-workspace restore through real Files/Finder providers and after restart remains an acceptance gate.

## Validation

See the [public validation summary](../docs/VALIDATION.md) for the scope of earlier tests and outstanding acceptance. Physical M1 iPad testing, offline cold launch/restart and full English/world archive acceptance remain unverified. Private device logs and signing evidence are not part of the source repository.

```sh
swift test --package-path apple
```

For UI tests, replace the destination with an installed iPhone or iPad simulator:

```sh
xcodebuild -project apple/NomadApple.xcodeproj -scheme NomadApple \
  -destination 'platform=iOS Simulator,name=YOUR_IPHONE_OR_IPAD_SIMULATOR' \
  -derivedDataPath apple/DerivedData CODE_SIGNING_ALLOWED=NO test
```

For native Mac UI tests, use `-destination 'platform=macOS'` with the same project/scheme and a separate derived-data directory. Configure local signing and grant macOS test-runner permissions when required. The presence of a runnable test target does not establish a passing full UI suite; current results belong in the [validation summary](../docs/VALIDATION.md).

Test harnesses and dependency pins: [Tests](Tests/README.md), [native dependencies](DEPENDENCIES.md), [web tools](WEB_TOOLS.md), [course format](App/Education/CourseFORMAT.md) and [reference dataset format](App/Reference/DATASET_FORMAT.md).

## Distribution

The source repository is public, but no distribution-signed iOS or macOS app or App Store release is provided. TestFlight and App Store publication are blocked on the [release gates](../docs/APP_STORE_READINESS.md), including license compatibility. Development signing and beta expiry must not be mistaken for permanent offline distribution.
