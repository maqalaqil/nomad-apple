# NomadPad

An independent, native iPad adaptation of [Project NOMAD](https://github.com/Crosstalk-Solutions/project-nomad). Read local knowledge archives, run local AI, view offline maps, and work with documents on one iPad.

**Development preview — not an App Store release and not full NOMAD feature parity.** This project is not affiliated with or endorsed by Crosstalk Solutions. The name is a development name; public app branding remains a release decision.

## What works today

- ZIM/Wikipedia reading and search, EPUB reading, PDF and text imports.
- Local GGUF inference through llama.cpp/Metal, plus Apple's on-device Foundation Models when available.
- PDF/text retrieval for AI answers, source excerpts, multiple saved conversations and local settings. Entire ZIM/EPUB archives are not in the AI retrieval index.
- Local PMTiles and raster MBTiles maps, saved places and offline map assets.
- Download queues with capacity checks, optional publisher checksums and explicit library/map imports.
- Native notes, PDF tools, files, inventory, media, an encrypted vault, backup/restore and translation integration.
- Local web tools and supported Kolibri/Perseus educational content.

These are working implementations with different levels of coverage. Read the [feature matrix](ipad/FEATURE_PARITY.md) for missing workflows and the [validation summary](docs/VALIDATION.md) for what has actually been tested. Models, Wikipedia, maps and course libraries are downloaded or imported separately; none is included in this repository.

## Build and run

Requires macOS, Xcode with the iOS 26 SDK, Python 3.11+, and Node 22+/npm. The app targets iPadOS 26+. Apple Intelligence and local-model performance depend on the hardware and installed system models. Initial dependency preparation requires internet access.

```sh
git clone https://github.com/maqalaqil/nomad-ipad.git
cd nomad-ipad
sh ipad/Vendor/fetch-corekiwix.sh
sh ipad/Vendor/fetch-llama.sh
python3 ipad/scripts/fetch-web-tools.py
python3 ipad/scripts/fetch-web-editors.py
python3 ipad/scripts/fetch-map-assets.py
python3 ipad/scripts/fetch-perseus.py
python3 ipad/scripts/generate-project.py
open ipad/NomadPad.xcodeproj
```

Select the **NomadPad** scheme, an iPad, your development team and a bundle identifier you control. The project is generated locally and is not committed, so personal signing selections stay local. The default bundle identifier is `io.github.maqalaqil.nomadpad`; change it for your own account. A free Personal Team supports development testing, not App Store distribution. See the [build and offline-use guide](ipad/README.md).

Portable tests do not require the downloaded frameworks or web bundles:

```sh
swift test --package-path ipad
```

The pinned llama framework has no iOS simulator slice; test GGUF inference on a physical iPad. See [test instructions](ipad/Tests/README.md) for other suites.

## App Store status

**Not ready for submission.** Distribution licensing, privacy declarations, app identity/icon/store metadata, a signed Release archive, and offline/device acceptance are open gates. Apple Developer Program membership and App Store Connect access are required. The next distribution milestone is a compliant TestFlight build, followed by App Review—not a promise that the current preview will be approved. See [App Store readiness](docs/APP_STORE_READINESS.md).

## License and provenance

Native source authored for this project is provided under Apache-2.0; retained third-party files keep their own licenses. See [LICENSE](LICENSE), [NOTICE](NOTICE), [licensing notes](docs/LICENSING.md), [native dependency pins](ipad/DEPENDENCIES.md) and [web-tool pins](ipad/WEB_TOOLS.md).

The compiled app is **not an Apache-only product**: the current reader links GPL libraries, and some bundled tools have separate obligations. Source publication does not resolve binary/App Store distribution compatibility.

The initial public snapshot extracts the native `ipad/` implementation developed against upstream commit `54ee30a44902e5c252b477f8685c26ec3064ab72`. It excludes the Linux/server application, downloaded binaries/content, private device evidence, signing material and local build products. No upstream Git history is rewritten.
