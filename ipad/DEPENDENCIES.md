# Native iPad dependencies

## CoreKiwix / libzim

The ZIM reader links the official **CoreKiwix 14.2.1-2** static XCFramework. Its bundled headers identify **libkiwix 14.2.1** and **libzim 9.7.0**. The package contains iOS arm64, iOS simulator arm64/x86_64, and macOS arm64/x86_64 slices.

- Official archive: <https://download.kiwix.org/release/libkiwix/libkiwix_xcframework-14.2.1-2.tar.gz>
- Download mirror used for this checkout: <https://mirrors.dotsrc.org/kiwix/release/libkiwix/libkiwix_xcframework-14.2.1-2.tar.gz>
- SHA-256: `14820648788dddc3df8a89ff0820af60d7efc1cfda6c83602989455263ee1561`
- Official published MD5, independently matched: `78c0398d14228d11d2caf2c888314d04`
- Published checksum: <https://download.kiwix.org/release/libkiwix/libkiwix_xcframework-14.2.1-2.tar.gz.md5>
- Upstream Apple app pin verified at commit `517a235337fd00e96a8f402a95aeec2d8c1ea333`: <https://github.com/kiwix/kiwix-apple/blob/517a235337fd00e96a8f402a95aeec2d8c1ea333/Brewfile>
- Framework build source: <https://github.com/kiwix/kiwix-build>

Run `sh ipad/Vendor/fetch-corekiwix.sh` to fetch and verify the pinned archive. Binary downloads and extracted frameworks are ignored by Git. They must be restored before building the app. The Swift package's portable storage tests do not require CoreKiwix.

### Integration

`App/Library/NomadZIMArchive.mm` is an Objective-C++ wrapper written for this app against public libzim APIs. No Kiwix application UI code was copied. Compile the wrapper with C++17 and ARC; import `App/Library/NomadZIM-Bridging-Header.h` as the Swift bridging header. Link `Vendor/CoreKiwix.xcframework` as a static library, with no embed/copy phase, plus the C++ standard library. Its selected slice's `Headers` directory must be on the header search path. A macOS smoke executable linked successfully without additional non-system libraries.

The reader opens local archives, follows internal redirects, lists titles, searches title suggestions, and uses full-text search when the archive includes a full-text index. Resources are served from the archive in bounded chunks. The ephemeral WebKit reader blocks external navigation and HTTP/WebSocket resources, injects a restrictive content security policy, and exposes no native JavaScript bridge. Large HTML articles are limited to 16 MB. Service workers, external embeds, and network links remain disabled; archive content that requires those features will not work.

### Licenses and distribution

- libzim 9.7.0: **GPL-2.0-or-later**; <https://github.com/openzim/libzim/tree/9.7.0>, <https://github.com/openzim/libzim/blob/9.7.0/COPYING>.
- libkiwix 14.2.1: **GPL-3.0-or-later**; <https://github.com/kiwix/libkiwix/tree/14.2.1>, <https://github.com/kiwix/libkiwix/blob/14.2.1/COPYING>.
- The merged binary also contains supporting libraries such as Xapian, ICU, compression, and networking libraries. Its archive does not include a complete bundled-license inventory. Before distributing a release, produce the full dependency/source-and-license inventory from the pinned kiwix-build recipe, retain the applicable notices, and supply corresponding source as required by those licenses.

The original NOMAD repository remains Apache-2.0. Its license has not been replaced. A native executable statically linking these GPL libraries must not be represented as an Apache-only product. Public distribution, including App Store submission, is not validated by this development integration and needs a compatible source and licensing plan before release.

### Verification fixtures

Native bridge smoke tests use official fixtures from `openzim/zim-testing-suite` commit `2edf72096208e60c82b6ebbe313baa552cc6af52`, downloaded into `/tmp` only:

- `data/nons/small.zim`: opening, metadata, article listing, content bytes, title search, and invalid archive rejection.
- `data/nons/wikipedia_en_climate_change_mini_2024-06.zim`: full-text search and real article/resource extraction.

Source: <https://github.com/openzim/zim-testing-suite/tree/2edf72096208e60c82b6ebbe313baa552cc6af52>. These fixtures are not bundled as user content.

## llama.cpp GGUF inference

The optional device inference engine links **llama.cpp v0.8.0 / build b11960**, commit `8642541b255bfb5dc39cd351a178be09013a55d6`. The stable v0.8.0 release points to this build for its binary assets.

- Release: <https://github.com/ggml-org/llama.cpp/releases/tag/v0.8.0>
- Binary release: <https://github.com/ggml-org/llama.cpp/releases/tag/b11960>
- Archive: <https://github.com/ggml-org/llama.cpp/releases/download/b11960/llama-b11960-xcframework.zip>
- SHA-256, matched against GitHub's asset digest: `feba05e0b7cb5e682ae3354abb455bf9723ae2cc95c69e24d073264e6a34d759`
- Source and license: <https://github.com/ggml-org/llama.cpp/tree/8642541b255bfb5dc39cd351a178be09013a55d6>, <https://github.com/ggml-org/llama.cpp/blob/8642541b255bfb5dc39cd351a178be09013a55d6/LICENSE> (**MIT**).
- Public API reference consulted: <https://github.com/ggml-org/llama.cpp/blob/8642541b255bfb5dc39cd351a178be09013a55d6/examples/llama.swiftui/llama.cpp.swift/LibLlama.swift>. The app's actor implementation is written separately against that release's C API.

Run `sh ipad/Vendor/fetch-llama.sh` to fetch and verify. The archive extracts to `Vendor/build-apple/llama.xcframework`, and all generated binaries remain ignored by Git.

### Platform and linking

This official artifact contains **dynamic** iOS arm64 and macOS arm64/x86_64 frameworks. It **does not contain an iOS simulator slice**. The simulator can import/list/delete model files and display the interface, but inference explicitly reports unavailable. The iPad target must link, embed, and sign `ios-arm64/llama.framework`; module name is `llama`. Link and embed only for `iphoneos` builds so the missing simulator slice cannot break simulator builds. No Objective-C bridging-header change is required.

`GGUFEngine` owns model/context state in an actor, frees the context before the model, limits the context to 2,048 tokens or the model's smaller trained limit, batches prompt evaluation in 128-token chunks, and emits decoded UTF-8 text. It uses the model's supported embedded chat template or a plain role-format fallback. It supports CPU decoding, Metal offload by default, CPU retry after a recoverable GPU load/context failure, per-token cancellation, and the CPU abort callback. Setting zero GPU layers alone is insufficient to guarantee CPU-only execution in this release, so CPU mode supplies an empty offload-device list and disables operation/KV offload.

The user imports model files; no model is downloaded automatically. Import validates the GGUF magic and copies into app-owned storage. Model architecture support, actual memory use, speed, and output quality depend on the chosen file and device. The UI discloses memory limits and confirms loading files over 2 GB. A failed memory allocation may be reported by the engine, but iPadOS process termination cannot be intercepted as a normal error.

### Verification

A tiny official `ggml-org/models` test model (`tinyllamas/stories260K.gguf`, approximately 1.2 MB) is downloaded to `/tmp` only for native smoke testing; it is not bundled or presented as a useful assistant model. Native Mac smoke tests passed real CPU and Metal token generation, GPU-to-CPU fallback when Metal was unavailable, context overflow rejection, cancellation, and unload. The new Swift files typechecked against the real iPad SDK/framework and the simulator SDK without that framework. App tests must additionally cover a useful model on the user's physical M1 iPad; simulator UI checks cannot establish inference speed or memory fitness.

The GGUF interface stores one local conversation, shared across selected models, in its own chat file. General chat submits that conversation using the model's supported chat template and rejects a conversation that exceeds the context budget. Optional document grounding retrieves up to three passages from the currently selected Knowledge Collections, using keyword search or the available on-device semantic index. Grounded turns send the current question and those passages, reserve response space using the actual model tokenizer and chat template, and retain the exact supplied excerpts with numbered source links. No matching passages produces an explicit message without model inference. Citation checks detect missing or out-of-range source numbers; they do not establish factual support. The interface explains that ZIM and EPUB content is not included in this indexed-text retrieval. Neither mode sends prompts to a remote provider or shares Apple FoundationModels chat history.

The grounding regression passed selected-source filtering, prompt bounds, source/citation persistence, and old-history decoding. A native smoke run with the tiny test model also confirmed that the real tokenizer's prepared prompt count matched generation and produced tokens within the context budget. That test establishes execution, not useful grounded-answer quality. Multiple named conversations and multimodal inputs remain unimplemented. Model files can be imported from Files or queued from Supply Depot; the app does not download them automatically.

Test model source: <https://huggingface.co/ggml-org/models/tree/main/tinyllamas>. Each imported model has its own license and content terms, independent of llama.cpp's MIT license.

## EPUB reader and system zlib

The EPUB reader uses the operating system's **zlib** (`import zlib`, raw DEFLATE mode), Foundation XML parsing, CryptoKit SHA-1 solely for the EPUB standard's font obfuscation, and WebKit. It adds no downloaded third-party EPUB framework. The archive directory/EPUB metadata integration is implemented in this repository.

- EPUB container/package/navigation reference: <https://www.w3.org/TR/epub-33/>
- zlib API reference: <https://www.zlib.net/manual.html>
- System zlib license/source: <https://www.zlib.net/zlib_license.html>

The implementation reads EPUB 2/3 package spines, EPUB 3 navigation or EPUB 2 NCX, compressed/stored ZIP entries, images/styles/fonts, and standard IDPF/Adobe font obfuscation. ZIP CRCs are verified on each resource read. It keeps archive data mapped and decompresses resources on demand without extracting arbitrary paths. ZIP64, split archives, unsupported compression, and DRM are rejected explicitly. Limits are 2 GB for the archive and summed expanded entries, under 50,000 directory entries, 64 MB per ZIP entry, 16 MB per rendered HTML chapter, and 4 MB per parsed metadata file. XML external entities and entity declarations are rejected, with parser depth/node/text bounds.

Books has EPUB/PDF import and browsing. EPUB reading includes a contents list, previous/next chapter, page/text zoom, Find in chapter, locally saved chapter/scroll fraction, bookmarks and location-linked notes with optional selected quotations. Notes are stored separately from the EPUB, can be searched/edited/exported, and remain accessible after a book is deleted. The ephemeral WebKit view has content JavaScript disabled, a restrictive content security policy, HTTP/WebSocket blocking, local-only navigation, and no native content bridge. App-initiated selected-text capture uses an isolated content world. This is a reading baseline, not a claim of complete EPUB reading-system conformance: media-overlay synchronization, interactive scripted books, fixed-layout spread behavior, permanent inline highlights, and Calibre format conversion are not implemented. Reading positions are approximate scroll fractions, not CFIs.

`Tests/EPUBRegression/fixtures.py` creates original EPUB 2/3 fixtures and intentionally invalid archives without internet access. `Tests/EPUBRegression/main.swift` validates package navigation, compressed chapter/image reads, percent-encoded paths, unsafe paths, unsupported DRM, XML entity declarations, truncation, and resource CRC failures. The official W3C EPUB Community Group sample **Accessible EPUB 3**, release **20230704**, was separately downloaded to `/tmp` and opened successfully: 22 spine chapters, 47 navigation entries, and 258,333 CRC-verified chapter bytes. It is not bundled as user content. Sample source/license information: <https://github.com/IDPF/epub3-samples/releases/tag/20230704>, <https://github.com/IDPF/epub3-samples>.

An offscreen native WebKit smoke run also rendered the original EPUB fixture's chapter text, local CSS, and SVG image with content JavaScript disabled. Reading-position gestures and device layout still need physical-iPad acceptance testing.
