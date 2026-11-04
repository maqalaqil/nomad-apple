# NomadPad build and offline-use guide

An independent native iPad adaptation of Project NOMAD. This is a development preview with incomplete feature parity. See the [project overview](../README.md), [feature matrix](FEATURE_PARITY.md) and [App Store readiness](../docs/APP_STORE_READINESS.md).

## Build


Prerequisites: Xcode with the iOS 26 SDK, Python 3.11+, and Node 22+/npm for the offline web bundles. Initial dependency preparation needs internet access; the built tool interfaces do not.

From the repository root:

```sh
sh ipad/Vendor/fetch-corekiwix.sh
sh ipad/Vendor/fetch-llama.sh
python3 ipad/scripts/fetch-web-tools.py
python3 ipad/scripts/fetch-web-editors.py
python3 ipad/scripts/fetch-map-assets.py
python3 ipad/scripts/fetch-perseus.py
python3 ipad/scripts/generate-project.py
open ipad/NomadPad.xcodeproj
```

The generated Xcode project includes the Swift/Objective-C++ sources, SQLite, static CoreKiwix, bundled web tools, catalogs and the device-only llama framework. Regenerate it after adding source files. Do not put a top-level `Resources` directory inside the built `.app`; resource folders are copied individually.

Choose **NomadPad**, select the iPad, and configure **Signing & Capabilities → Team** with your own development account and a bundle identifier you control. The public source defaults to `io.github.maqalaqil.nomadpad`; the generated project stays untracked. Build and run. The project generator preserves your selected team and bundle identifier. A free Apple ID Personal Team is suitable for testing, but its provisioning profiles expire after **7 days**, requiring another signed installation; see [Apple's account limits](https://developer.apple.com/help/account/basics/about-your-developer-account/). Development signing and TestFlight are not permanent offline distribution arrangements; the final distribution method, expiry behavior and third-party license obligations remain release gates. No signing identity or provisioning profile is stored in this repository.

A simulator build does not need signing:

```sh
xcodebuild -project ipad/NomadPad.xcodeproj -scheme NomadPad \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath ipad/DerivedData CODE_SIGNING_ALLOWED=NO build
```

The official pinned llama framework has no iOS simulator slice. Its simulator screen explains that inference needs a physical device. Apple Intelligence availability also depends on the device and installed system model.

## Prepare the iPad for offline use

1. Install and launch the app while connected. Confirm the installation's signing validity for your intended trip.
2. In **Downloads**, browse the Arabic/English Wikipedia, worldwide/regional-map and small-model catalogs, or add a direct HTTPS file URL. Transfers use Wi-Fi and serialize downloading/verification. Official exact byte lengths and SHA-256 values are enforced when provided; older regional entries remain estimates. Paused entries stay paused. Catalog preflight includes pending transfers and a 512 MiB reserve. On filesystems that pass the local hardlink probe, completed verified ZIM/PMTiles downloads activate without another full copy; unsupported linking retains the full-copy capacity check. External Files imports still copy. The worldwide map has no published SHA-256, so exact size/format checks do not establish cryptographic integrity.
3. Import completed content into its module. The library reads local ZIM archives, EPUB books, PDFs and text. Maps supports compatible PMTiles and raster MBTiles. Education imports exported Kolibri channel folders as well as individual lessons. Models use compatible decoder-only GGUF files. Drug Reference accepts extracted official openFDA JSON parts or its documented SQLite schema. Other modules use their own Files import controls.
4. Prepare Apple's translation languages before disconnecting. For Apple Intelligence, confirm that the system model is available. Alternatively, import a suitable local GGUF model and test it on the actual iPad.
5. Save/export important user data. Verified internal library/map downloads can share immutable storage; Files imports, models and other modules can create another copy. Deleting one shared file entry does not remove the other module’s file.
6. Turn on airplane mode, turn Wi-Fi off, force-close and reopen the app, and exercise the exact content and tools you will need. Repeat after restarting the iPad. Check maps at several zoom levels, ZIM images/search, model generation, exercises, media and exported files individually.

The cataloged full-image Arabic and English Wikipedia editions plus worldwide street map total **281.33 GB** (decimal). Initial preflight requires about **281.86 GB free** when checked hardlinks are available, including a 512 MiB reserve. The fallback requires about **416.68 GB free** for one largest import copy. Other user content requires additional space. This is selected article media and a street basemap; satellite imagery and routing data are separate.

The model catalog includes Qwen2.5-0.5B-Instruct Q4_K_M (491.4 MB), intended as a small starting point. A model file's storage size is not its runtime memory budget. Test model fit, response quality and thermal behavior on the actual device. No model or large knowledge library is bundled automatically.

## Native architecture


- **SwiftUI shell and local stores:** app navigation, documents, notes, media, inventory, lessons, drawing, settings and persistent state.
- **Knowledge reader:** CoreKiwix/libzim via a narrow Objective-C++ bridge; local WebKit article resources with external requests blocked.
- **AI:** Apple's on-device Foundation Models API and a separate llama.cpp GGUF engine. No cloud inference fallback. Knowledge Collections builds local sentence embeddings and combines semantic and keyword retrieval for both assistants. GGUF library answers use up to three active-source passages, fitted with the loaded model’s actual tokenizer; the supplied excerpts and citation warnings persist with the answer. No matching sources means no model answer is generated. Indexing is bounded to 4,000 extracted passages; whole ZIM/EPUB contents are not indexed. Both assistants keep multiple named conversations, per-conversation source/context/generation settings, and validated JSON import/export. Migration preserves the old single-chat files, failed reads block writes, and conflicting saves cannot silently overwrite a newer archive. Library answers exclude prior conversation text and custom general-chat instructions; citation correctness still requires checking the sources.
- **Maps and courses:** locally served MapLibre/PMTiles with bundled fonts/styles, native raster MBTiles, and a validated Kolibri export importer with separate learner profiles and local progress. The complete pinned Perseus renderer scores supported exercises locally and saves answer/hint/result state. These are native workflows, not continuously running servers; Kolibri mastery/classroom parity and every widget/content format are not verified.
- **Web tools:** complete pinned CyberChef, IT Tools and Excalidraw distributions, served from local resources with network access restricted. Upstream operations that inherently contact online services cannot work offline.
- **PDF/translation/media/drawing/security:** PDFKit and Vision, Translation, AVKit, PencilKit and device-protected Keychain APIs.
- **Data preparation:** persistent background-capable URLSession transfers, local catalog snapshots and explicit content imports. Supply Depot shows actual document/model/transfer counts; Device & Storage has a cancellable metadata-only report with hardlink-aware totals and bundled offline help. iPadOS may suspend work; a desktop-style always-running service is not promised.

Most module data is saved under private Application Support directories; the Files workspace lives in Documents. The vault uses a device-only Keychain item protected by device authentication and supports separate passphrase-encrypted recovery. See [Vault](App/Vault/README.md). Whole-app backup supports 19 native store groups, optional content, selective restore and retained rollback; Downloads, unsaved web-tool storage, Keychain and system-managed models are excluded. See [Backup](App/Backup/README.md). Whole-workspace restore through physical Files providers and after restart remains an acceptance gate.

## Validation

See the [public validation summary](../docs/VALIDATION.md) for the scope of earlier tests and outstanding acceptance. Physical M1 testing, offline cold launch/restart and full English/world archive acceptance remain unverified. Private device logs and signing evidence are not part of the source repository.

```sh
swift test --package-path ipad
```

For UI tests, replace the destination with an installed iPad simulator:

```sh
xcodebuild -project ipad/NomadPad.xcodeproj -scheme NomadPad \
  -destination 'platform=iOS Simulator,name=YOUR_IPAD_SIMULATOR' \
  -derivedDataPath ipad/DerivedData CODE_SIGNING_ALLOWED=NO test
```

Test harnesses and dependency pins: [Tests](Tests/README.md), [native dependencies](DEPENDENCIES.md), [web tools](WEB_TOOLS.md), [course format](App/Education/CourseFORMAT.md) and [reference dataset format](App/Reference/DATASET_FORMAT.md).

## Distribution

The source repository is public, but no signed IPA or App Store release is provided. TestFlight and App Store publication are blocked on the [release gates](../docs/APP_STORE_READINESS.md), including license compatibility. Development signing and beta expiry must not be mistaken for permanent offline distribution.
