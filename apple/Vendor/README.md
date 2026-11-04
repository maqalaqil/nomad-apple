# Native framework preparation

Run these commands from the repository root:

```sh
sh apple/Vendor/fetch-corekiwix.sh
sh apple/Vendor/fetch-llama.sh
```

For an offline restore, pass `--archive /path/to/pinned-archive` to either script. The source archive is read only. Both scripts verify the fixed SHA-256 before staging extraction and replacing a framework. Bad or missing archives preserve an existing framework. Generated frameworks and downloaded archives are ignored by Git. These scripts require macOS command-line tools; do not run concurrent copies of the same installer into one checkout.

## Xcode linking

| Target SDK | CoreKiwix header directory under `Vendor/CoreKiwix.xcframework` | llama framework directory under `Vendor/build-apple/llama.xcframework` |
| --- | --- | --- |
| `iphoneos` | `ios-arm64/Headers` | `ios-arm64` |
| `iphonesimulator` | `ios-arm64_x86_64-simulator/Headers` | None; omit framework linkage and embedding |
| `macosx` | `macos-arm64_x86_64/Headers` | `macos-arm64_x86_64` |

Link the `CoreKiwix.xcframework` reference as a static library; do not embed it. The Objective-C++ ZIM wrapper uses C++17, ARC, the matching headers, and the app bridging header. Retain `-lc++ -lz -liconv` linker flags. Link `-framework llama` only where its slice exists, and expose that directory through framework search paths.

Embed the **complete** selected `llama.framework` with `ditto` or Xcode's copy phase. For native Mac preserve `Versions/A`, `Versions/Current`, and the framework symlinks. Its install name is `@rpath/llama.framework/Versions/Current/llama`; the remaining dependencies are system frameworks/libraries. The archive's Mac signature is ad hoc, not a distribution signature. Sign the copied nested framework with the app's selected signing identity before signing the app.

- iOS destination: `$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH` (normally `App.app/Frameworks`); runpath `@executable_path/Frameworks`.
- Native Mac destination: `$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH` (normally `App.app/Contents/Frameworks`); runpath `@executable_path/../Frameworks`.
- Do not edit the cached source framework's install name or signature. No absolute development-machine path should be embedded in the app.

The archive contains native Mac arm64 and x86_64 binaries and iOS arm64 binaries. CoreKiwix also includes an iOS simulator slice, but llama does not. No Mac Catalyst or visionOS slice is supplied, and no source-built replacement is claimed here. The app's simulator interface must continue to report inference unavailable.

## Native checks and platform limits

After local restoration, the production native Mac ZIM wrapper opened an official small climate archive, listed and read entries, performed title and full-text search, and rejected invalid input. The production GGUF engine loaded a tiny public test model, generated eight tokens using CPU and eight using Metal, and unloaded; the actual tokenizer/template grounding regression also passed. These fixtures are not included in the app and are not an answer-quality certification.

Native Mac storage regressions passed 140 backup checks, 76 synthetic Drug Reference checks, and the download queue suite. A production download verification test hashed a 19,095,710,684-byte sparse fixture with about 3.9 MB of peak RSS growth. This validates isolated engine behavior, not a signed sandboxed application's full lifecycle or user interface.

AppKit apps do not support automatic background launch for URLSession completion. Keep the Mac app running to verify transfers and advance its serial queue; after quitting, reopen it to reconcile retained transfers. A scheduled restore similarly requires quitting the process (Command-Q) and launching again; closing a window alone is insufficient.

Licenses, pins, source links, and unresolved distribution work remain in [DEPENDENCIES.md](../DEPENDENCIES.md) and [licensing](../../docs/LICENSING.md). Successful local linking does not establish App Store redistribution permission.
