# Native source and notice inventory

Audit date: 5 November 2026. This inventory records source provenance; it does not change any third-party license or settle App Store terms.

CoreKiwix 14.2.1-2 was built by the official `kiwix/kiwix-build` recipe at commit `23ecf5b8209acf705aa702fd040ea0f75c077829` (release build 2). The recipe merges its static dependencies into the Apple XCFramework. NOMAD calls libzim's archive/search APIs; this conservative inventory includes the complete merged-library dependency set, including components that the linker may discard.

| Component | Pinned version | Preserved notice |
| --- | --- | --- |
| libzim | 9.7.0, `92bf64eb9c79fa44d9baeeb80786d2ae3775fce7` | GPL-2.0-or-later |
| libkiwix | 14.2.1, `46b599fb2c88cf55b0f889971aa9c930cdae94cd` | GPL-3.0-or-later |
| Xapian | 1.4.23 | GPL |
| zlib | 1.3.1 | zlib license |
| liblzma / xz | 5.2.6 | upstream COPYING plus GPL/LGPL texts covering source components |
| Zstandard | 1.5.7 | BSD and alternative GPL notice |
| ICU | 73.2 | upstream Unicode/ICU and incorporated third-party notices |
| Mustache | 4.1 | MIT |
| pugixml | 1.15 | MIT |
| libmicrohttpd | 0.9.76 | LGPL/eCos dual-license notice; upstream Apple recipe disables TLS |
| curl | 8.4.0 | curl license |
| llama.cpp | `8642541b255bfb5dc39cd351a178be09013a55d6` / b11960 | MIT and vendor notices |

The Darwin Xapian recipe downloads **1.4.23**, also identified by the shipped headers. The recipe's generic versions file says 1.4.26; that value must not be substituted for the actual Apple dependency. Meson patch archive names and checksums are preserved exactly, including the historical `libmicrohttpd_0.9.16-3_patch.zip` filename for the 0.9.76 recipe.

## Retrieve the source

[The checked-in manifest](../apple/native-source-manifest.json) records 19 immutable source/build-patch archives, their exact URLs and verified SHA-256 digests. It includes ICU source/data, the Kiwix recipe and its patches, libzim/libkiwix source, the ZIM test-suite build input and llama.cpp source. No secrets, certificates or user data are included.

```sh
python3 apple/scripts/fetch-native-sources.py
python3 apple/scripts/fetch-native-sources.py --verify
```

The first command downloads missing archives into `artifacts/open-source` and verifies every file. The second checks existing files without network access. Neither command executes upstream code or extracts archive paths. The source package must accompany any distributed binary through the same release channel or an applicable source offer; merely fetching it locally does not fulfill that distribution step.

## Build recipe

Use the pinned kiwix-build source, its `apple_all_static` configuration and release versions. Its CI recipe specifies macOS 26, Xcode 26.5, Python 3.13, automake, meson, pytest, requests and distro. The release script invokes:

```sh
kiwix-build libkiwix --hide-progress --fast-clone --assume-packages-installed \
  --use-target-arch-name --config apple_all_static --make-release
```

Review the pinned `.github/workflows/cd.yml`, `.github/scripts/common.py`, dependency recipes and patches before building. CI signing/upload credentials are upstream infrastructure and are **not** needed or supplied by NOMAD. A source rebuild and byte-for-byte comparison with the official binary have not been performed. Preserve original licensing notices if rebuilding or modifying the framework.

For NOMAD's own integration, use [Apple setup](../apple/README.md) and its checked-in project generator, Objective-C++ wrapper, Swift sources and resource fetch scripts. The app's llama framework comes from the official pinned release described in [DEPENDENCIES](../apple/DEPENDENCIES.md); the simulator intentionally has no inference slice.

## Bundled notices

[ThirdPartyLicenses](../apple/Resources/ThirdPartyLicenses/) contains unmodified notice texts and a manifest recording source archive member and SHA-256 for each. Offline help → Open-source licenses displays these along with the generated web-tool license files. Bundled web-tool source and notice obligations are documented in [LICENSING](LICENSING.md).

The original sample library is dedicated under CC0 and contains no user documents. Content downloaded by users is not bundled into the app or this source inventory.
