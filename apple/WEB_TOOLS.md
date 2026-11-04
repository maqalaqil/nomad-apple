# Offline bundled web tools

The app also includes an offline PMTiles map renderer. Build its local map engine,
fonts, symbols, and style with `python3 apple/scripts/fetch-map-assets.py`. Imported
map archives stay on the iPad and are read through native byte ranges; no map
server is required. See [map setup, licenses, verification and limits](Resources/WebTools/Maps/README.md).

## CyberChef integration

NomadPad bundles the **complete CyberChef v11.5.0 distribution**, including its
505-operation catalog, dynamically loaded modules, WebAssembly support assets,
fonts, images, English Tesseract data, and dependency license notices. It is
opened from local files in `WKWebView`; the app does not load a hosted CyberChef
website or use a CDN fallback. The quick native utilities remain available.

This is full distribution coverage, not certification that every upstream
operation works on iPad. In particular, an offline device cannot complete
operations that require remote services.

## Reproduce the bundled assets

From the repository root, before generating/building the Xcode project:

```sh
python3 apple/scripts/fetch-web-tools.py
python3 apple/scripts/fetch-web-tools.py --verify
```

The fetch command needs internet access on the development Mac. App runtime
does not download CyberChef. Python's standard library is sufficient. The
83,125,922-byte release ZIP and upstream license are verified against committed
SHA-256 pins before extraction. The complete extracted directory is generated
and ignored by Git because it is approximately 83 MB; the manifest and fetch
script are committed. No release or update is chosen dynamically.

An offline build can use previously downloaded files:

```sh
python3 apple/scripts/fetch-web-tools.py \
  --archive /path/to/CyberChef_8cd426dd4f40f1423912d5fad91b578a86a65112.zip \
  --license-file /path/to/CyberChef-LICENSE
```

The Xcode project must copy `apple/Resources/WebTools` as a folder resource,
preserving subdirectories. The expected runtime entry point is:

```text
Bundle.main.resourceURL/WebTools/CyberChef/index.html
```

The wrapper also supports the legacy `Resources/WebTools/CyberChef/index.html`
path. Missing assets produce an explicit unavailable screen. Do not create a
top-level app-bundle directory named Resources: it can interfere with bundle
layout detection during simulator installation.

## Version and attribution

- [Official release v11.5.0](https://github.com/gchq/CyberChef/releases/tag/v11.5.0)
- Source commit: `8cd426dd4f40f1423912d5fad91b578a86a65112`
- Release SHA-256: `f6478925d3eaa16ec08626a85f5b85eed10d531a5e18700615fed7ecb024cccf`
- [Upstream Apache 2.0 license](https://github.com/gchq/CyberChef/blob/v11.5.0/LICENSE)
- Crown Copyright 2016–2026; original attribution is retained.

All upstream archive files are unchanged. The build adds a stable `index.html`
alias containing the same entry-point HTML plus an offline Content Security
Policy, the upstream LICENSE, and a hash manifest for the installed files.
`--verify` checks the generated files as well as the original assets.

## Native integration

`ToolsView` links to `CyberChefView`. The wrapper:

- Grants WebKit read access only to the CyberChef resource directory.
- Applies an HTTP/HTTPS/WebSocket content-blocking rule list **before loading**.
- Uses CSP to constrain document and worker resources to local files, blobs,
  and data URLs. Explicit `file:` permission is necessary for blob workers to
  load local operation modules; `'self'` alone leaves lazy operations stalled.
- Rejects external navigation and HTTP download redirection.
- Uses the system Files picker for CyberChef's HTML file inputs, copying chosen
  files into temporary storage for the active view. Originals are untouched.
- Handles blob downloads through `WKDownload`, then presents the iPad share
  sheet. Choose **Save to Files** to retain output or exported recipes. Multiple
  exports are queued. Temporary exported copies are removed after sharing.
- Supplies native JavaScript alerts, confirmation dialogs, and text prompts.
- Reports loading, navigation, export, and WebKit process termination errors.

CyberChef settings and saved recipes use the default persistent WebKit data
store. Do not rely on that store as a backup: export valuable recipes and output
before clearing app data or reinstalling.

## Verification

The four native tool view files passed an isolated iOS 26 / Swift 5 device-SDK
typecheck. The bundled release and license passed their pinned SHA-256 checks;
all 134 installed files passed `--verify`.

All smoke checks passed on November 3, 2026. The reproducible macOS WebKit smoke runner uses the same local entry point,
read-access scope, and content-blocking rules:

```sh
swift apple/scripts/fetch-web-tools.smoke.swift
```

It requires access to macOS GUI/WebKit services but opens no visible window.
It checks catalog/worker initialization, Base64, SHA-256, Reverse,
Gzip→Gunzip, Jq/WebAssembly, ROT13, denied remote fetches from both the document
and a worker, and a native blob download with byte-for-byte verification.
The runner uses a separate, nonpersistent website data store.

These checks exercise actual WebKit and the upstream recipe engine. They do not
replace tests on the M1 iPad, including native Files imports, share-sheet export,
touch/keyboard interactions, memory pressure, and a cold launch with Wi-Fi and
cellular disabled.

## Known limits and remaining work

- HTTP Request, DNS over HTTPS, online map tiles, external links, and other
  network-dependent functionality are blocked. The operations remain in the
  upstream catalog and must not be treated as completed offline features.
- Operation-by-operation compatibility across all 505 entries is still pending.
  The included OCR assets, media operations, image rendering, worker-heavy
  operations, and browser permission flows require individual iPad tests.
- The upstream desktop layout is most usable in iPad landscape. It has not been
  redesigned as 505 native SwiftUI screens.
- WebKit/iPadOS memory limits still apply; a large file or expensive recipe can
  terminate the web process. Export work frequently. Background execution is
  not guaranteed while the app is suspended.
- Cloud file-provider placeholders need downloading before going offline.
- CyberChef's own “Download CyberChef” ZIP link points to an archive that is not
  stored inside the app. Rebuild with the fetch script to update the engine.

# IT Tools and Excalidraw

`ITToolsView()` contains the complete official **IT Tools
v2024.10.22-7ca5933** frontend, matching NOMAD's pinned release. The release has
89 navigable local routes in the WebKit smoke check. `ExcalidrawView()` embeds
the complete official **@excalidraw/excalidraw 0.18.1** editor with React 18.3.1,
local fonts, shapes/arrows/freehand/text/images, the editor's library system,
and its normal canvas controls. The native sketchbook remains separate.

Both use a stable `nomad-local://` origin backed by `WKURLSchemeHandler` reading
only the respective bundled directory. This supports root-relative asset paths,
SPA routing, ES modules, Web Crypto, and IndexedDB without a network server.
Remote requests are still blocked by CSP and WebKit content rules. The shared
native wrapper provides file import, download sharing, and JavaScript dialogs.

## Build and verify

```sh
python3 apple/scripts/fetch-web-editors.py
python3 apple/scripts/fetch-web-editors.py --verify
```

The IT Tools release ZIP, license, and corresponding source tarball are pinned
by SHA-256 in `Resources/WebTools/it-tools-release.json`. Its original JavaScript
and assets are retained; only the entry-point CSP is added. The original HTML,
upstream GPL v3 license, corresponding source archive, transformation script,
and integration notes are bundled. The source archive and license can be
exported from the app's information sheet.

Excalidraw is built from the pinned `scripts/fetch-web-editors/package-lock.json`
with `npm ci --ignore-scripts`; a local esbuild bundle includes the editor and
its dependencies, and all production font assets are copied into the app.
The MIT license and generated license notices are included. No CDN is required.
The installation manifest hashes every generated asset and the dependency lock.

An offline rebuild can supply IT Tools files through `--it-tools-archive`,
`--it-tools-source`, and `--it-tools-license`, and use `--npm-offline` with a
previously populated npm cache. Use `--skip-it-tools` or `--skip-excalidraw` to
rebuild only one integration.

## Drawing storage and file compatibility

Excalidraw automatically saves the current scene, image data, and library items
to IndexedDB. The toolbar reports saving failures and completion; wait for
**Saved on this iPad** before leaving. `.excalidraw` and `.excalidrawlib` files
can be imported and exported. PNG and SVG exports open the native share sheet.
Exported scene files provide independent drawings and backups; the local editor
automatically restores one active workspace. Reinstalling/clearing app data can
remove this workspace.

The wrapper asks for camera/microphone permission when a browser tool requests
recording, provided the app has the matching privacy descriptions. Missing
privacy keys produce an explanatory error instead of invoking the device API.

## Actual verification and remaining compatibility work

On November 3, 2026, the local WebKit checks passed:

- IT Tools: full interface/89 local routes, secure-context Web Crypto, navigating
  to the Base64 converter, and converting `NOMAD` to `Tk9NQUQ=` through its UI.
- Excalidraw: creating rectangle/text elements using the actual editor API,
  automatic IndexedDB save, restoring both elements after a page reload, and
  exporting a valid PNG through native `WKDownload`.
- All native tool sources typecheck against the iOS 26 SDK in Swift 5 mode.

The reproducible editor smoke runner takes either resource directory:

```sh
swift apple/scripts/fetch-web-editors.smoke.swift apple/Resources/WebTools/ITTools
swift apple/scripts/fetch-web-editors.smoke.swift apple/Resources/WebTools/Excalidraw
```

These are macOS WebKit checks. Physical-iPad camera/recording, clipboard,
Files/share sheets, Apple Pencil gestures, memory pressure, cold-launch storage,
and operation-by-operation coverage still require device tests. Excalidraw's
hosted account, cloud sharing, live collaboration, and external library catalog
are not local editor features and are unavailable offline. Network-dependent IT
Tools operations likewise cannot complete offline. This integration includes
the complete editor/tool frontends without asserting that every browser feature
has passed on the target iPad.
