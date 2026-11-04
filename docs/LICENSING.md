# Licensing and redistribution

This is a source release, not a cleared App Store binary release. The repository's [Apache-2.0 license](../LICENSE) covers its own code unless a file carries a different notice. It does not replace the licenses of dependencies fetched by the build scripts or grant rights to downloaded books, models, maps, or course content.

The native project is an independent adaptation of [Crosstalk Solutions' Project NOMAD](https://github.com/Crosstalk-Solutions/project-nomad), based on upstream revision `54ee30a`. Preserve upstream copyright and license notices and identify modifications. Apache-2.0 section 6 does not grant general trademark rights; public branding must not imply upstream sponsorship or endorsement.

## Dependency status

| Component | License/provenance | Release action |
| --- | --- | --- |
| CoreKiwix 14.2.1-2, linked statically | Includes [libzim 9.7.0, GPL-2.0-or-later](https://github.com/openzim/libzim/blob/9.7.0/COPYING) and [libkiwix 14.2.1, GPL-3.0-or-later](https://github.com/kiwix/libkiwix/blob/14.2.1/COPYING). These are GPL, not LGPL. | Resolve the combined executable's license and App Store distribution terms; produce the complete dependency, notice, and corresponding-source inventory. |
| llama.cpp v0.8.0 / b11960 | [MIT, pinned source](https://github.com/ggml-org/llama.cpp/blob/8642541b255bfb5dc39cd351a178be09013a55d6/LICENSE) | Include its copyright/license notices in distributed binaries. Model weights have separate licenses. |
| CyberChef v11.5.0 | [Apache-2.0](https://github.com/gchq/CyberChef/blob/v11.5.0/LICENSE); fetched bundle retains generated dependency notices | Audit the full release bundle and preserve its notices. Encryption functionality also needs export-compliance assessment. |
| IT Tools v2024.10.22-7ca5933 | [GPL-3.0](https://github.com/CorentinTh/it-tools/blob/v2024.10.22-7ca5933/LICENSE); fetch script includes pinned source and license | Preserve corresponding source and resolve applicable App Store terms before shipping it. Its separate WebKit bundle does not become Apache-licensed. |
| Excalidraw | MIT; [preserved notice](../ipad/scripts/fetch-web-editors/LICENSE.excalidraw) and locked npm dependencies | Preserve package, font, and asset notices. |
| Perseus, Kolibri integration, and math dependencies | Package-level licenses; Kolibri integration is MIT; MathQuill is MPL-2.0 with source retained by the bundler | Audit the generated license inventory. **Unresolved:** `@khanacademy/mathjax-renderer@3.0.0` publishes neither a license field nor a license file in the inspected package. Obtain upstream permission or replace it before redistribution. |
| MapLibre / PMTiles / Protomaps / map assets | BSD-3-Clause code, CC0 style design, MIT icons, SIL OFL fonts; [pinned inventory](../ipad/Resources/WebTools/Maps/README.md#source-and-licenses) | Preserve all notices and the separate attribution/license of each map dataset. |

Details and checksums are in [native dependencies](../ipad/DEPENDENCIES.md), [web release manifests](../ipad/Resources/WebTools/), and the [Perseus notice audit](../ipad/Resources/WebTools/Perseus/README.md#license-records). Generated frameworks, downloaded archives, npm dependencies, and built web bundles are excluded from this source repository; running the fetch scripts does not establish permission to redistribute the result.

## Binary release gates

1. Inventory every library actually included by the pinned [kiwix-build](https://github.com/kiwix/kiwix-build) recipe, including supporting search, compression, Unicode, and networking libraries. The merged XCFramework has no complete bundled license inventory in this integration.
2. Provide applicable notices and corresponding source, including build instructions and modifications. A URL to this Apache-licensed repository alone is not a complete GPL source-compliance plan for the statically linked executable.
3. Resolve App Store terms against the GPL components, obtaining applicable additional permission or choosing replacement components if necessary. Publishing source does not by itself resolve restrictions on binary distribution. This audit has not established an App Store exception for the pinned dependencies; it does not claim that all GPL apps are categorically barred. See the [GPLv3 distribution conditions](https://www.gnu.org/licenses/gpl-3.0.html) and [Apple's standard EULA](https://www.apple.com/legal/internet-services/itunes/dev/stdeula/).
4. Resolve the MathJax renderer's missing permission and check every generated npm/font/asset notice. Do not infer a license from a package being publicly downloadable or used by another project.
5. Audit content separately. Catalog entries are download references, not grants of redistribution rights. Preserve Wikipedia attribution, OpenStreetMap/map-data terms, course licenses, and individual model licenses; do not bundle user files or test downloads into a release.

No third-party license is changed by this document. See [App Store readiness](APP_STORE_READINESS.md) for the remaining packaging and validation work.
