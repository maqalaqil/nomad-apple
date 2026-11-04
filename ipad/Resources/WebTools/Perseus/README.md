# Offline Perseus renderer

This is the complete pinned upstream Perseus front end, integrated with the
official Kolibri migration, scoring, numeric-answer normalization, math renderer,
and mobile math keypad. Assessment JSON and all question images/Graphie pairs
come from the user's imported `.perseus` exercise package. No example curriculum
is installed by this builder.

## Build and verification

From the repository root:

```sh
python3 ipad/scripts/fetch-perseus.py
python3 ipad/scripts/fetch-perseus.py --verify
```

Node/npm and Python 3.11+ are required. The first build needs internet to fetch
pinned public dependencies and built-in assets. Use `--offline` once all inputs
and npm packages are cached; `--npm-cache /path/to/cache` selects an explicit npm
cache. `npm ci --ignore-scripts` uses the committed lockfile. Every downloaded
non-npm file is SHA-256 checked against `release.json`; npm integrity values are
in the lockfile. The generated `nomad-installation.json` records file hashes,
source pins, and the lockfile hash. Large generated assets are ignored by Git.
It also checks adapter source hashes so `--verify` detects a stale bundle after
renderer/build-script changes.

The app bundles this whole directory as `WebTools/Perseus`. The native host
serves it at `nomad-perseus://local/renderer/`, and serves package entries at
`nomad-perseus://local/package/`. Keep every generated file, including fonts,
speech maps, licenses, and source notices. No HTTP server or CDN is needed at
runtime. The host enforces local-only resource access and navigation; the page
also has a restrictive CSP.

## Pinned sources

- Kolibri commit `da32925bce3cd216c4c5c0ecb7429314926f50c5`:
  <https://github.com/learningequality/kolibri/tree/da32925bce3cd216c4c5c0ecb7429314926f50c5/kolibri/plugins/perseus_viewer>
- `@khanacademy/perseus` 78.2.0, `perseus-core` 28.2.0,
  `perseus-score` 8.11.7, `math-input` 26.4.37, `keypad-context` 3.2.65,
  `mathjax-renderer` 3.0.0, MathJax 3.2.2, React 18.2.0.
- Built-in protractor, graph-function icons, and MathJax fallback font have
  individually pinned URLs/hashes in `release.json`.
- MathQuill v1.0.3 source archive and MPL notice are retained under
  `licenses/MathQuill/`; its original project is
  <https://github.com/Khan/mathquill/tree/v1.0.3>.

The Kolibri integration files are retained unchanged in `scripts/fetch-perseus/upstream`.
The bundler adapts the CommonJS translation export and provides small local
translation/logging/static-URL shims. The shim uses the official English message
catalog. Scoring and numeric-response functions are not replaced with a custom
scorer. All registered widgets are bundled, rather than selecting a small set.
The CSS adapter scopes math-input module classes under `#exercise` so the
upstream keypad grid takes precedence over Wonder Blocks' injected flex defaults.

## Native bridge

After a `{type:"ready"}` message, call:

```js
await window.NomadPerseus.loadItem({
  item,                         // Original assessment JSON, up to 8 MiB
  itemId: "original-item-id",    // Stable identifier, max 500 characters
  locale: "en",
  answerState: null,             // Previously emitted answerState, if present
  hintsVisible: 0,               // Explicit value overrides answerState hints
  assetBaseURL: "nomad-perseus://local/package/"
});
window.NomadPerseus.checkAnswer(); // Official {type, earned, total, message?} score
window.NomadPerseus.showHint();
window.NomadPerseus.getState();    // Synchronous answerState, or null
window.NomadPerseus.flush();       // Emits state and returns it
```

Messages go to `window.webkit.messageHandlers.perseus`:

- `ready`
- `loaded`: `itemId`, `hintsVisible`, `totalHints`
- `state`: `itemId`, `answerState`, `hintsVisible`
- `result`: `itemId`, `score`, `answerState`, `hintsVisible`
- `error`: `message`

Answer state is `{userInput, hintsVisible}`. Legacy Kolibri serialized question
state is also accepted through the official conversion function. `${☣ LOCALPATH}/`
is rewritten in both JSON strings and dictionary keys, including image dimension
metadata. Graphie `.svg` and `-data.json` files load from the package. Saved
answers and scoring inputs restore the original placeholder URLs. State emits
after interaction, on visibility loss, and on pagehide. The native host also
captures synchronous `getState()` before releasing the WebView.

## Verified behavior and limits

The macOS WebKit smoke runner exercises this exact bundle through a custom URL
scheme with HTTP/WebSocket blocking. It checks the official Kolibri sorter
fixture with correct, incorrect, and restored answers; a numeric input with real
keypad Delete/2 edits and grid geometry; hints; local MathJax fonts, speech maps, and Graphie
SVG/metadata; preserved image dimensions; blocked HTTP; and rejection of an
unsupported item with no stale answer state or grading. Run:

```sh
node ipad/scripts/fetch-perseus/fixtures.mjs /tmp/nomad-perseus-fixtures
xcrun swiftc -parse-as-library -swift-version 5 \
  -module-cache-path /tmp/nomad-webkit-module-cache \
  ipad/scripts/fetch-perseus.smoke.swift -o /tmp/nomad-perseus-smoke
/tmp/nomad-perseus-smoke "$PWD/ipad/Resources/WebTools/Perseus" \
  /tmp/nomad-perseus-fixtures
```

These tests require a logged-in macOS GUI session and WebKit services. The
Education module also has a separate native-host test that exercises the actual
production coordinator, ZIP package route, bridge validation, and navigation
policy. Physical iPad touch, VoiceOver, keyboard, and broader course/widget
coverage still need device testing. Complete library inclusion is not a claim
that every historical exercise widget/content package has passed acceptance.

Unknown widgets, upstream deprecated stand-ins, video widgets, and iframe widgets
are rejected explicitly. A failed item migration, missing required image, or
rendering error prevents grading. Unbundled built-in assets also produce an
explicit error. Missing assets are never fetched from the internet. English UI
messages are bundled; imported content retains its own language and numeric
normalization uses the requested locale, but translated UI catalogs are not
bundled. Native course code owns question selection, learner progress, and mastery
rules; this renderer returns the original scorer result and does not derive a
mastery percentage. Kolibri server administration, classes, and account sync are
outside this renderer.

## License records

`main.js.LEGAL.txt` preserves linked upstream comments. `licenses/npm/` includes
original package metadata and all available license/notice files from the locked
dependency tree (including a conservative superset of build dependencies).
`inventory.json` records declared licenses and notice paths. Kolibri's MIT notice
and original integration sources are retained, along with MathQuill's source
archive/MPL notice.

**Unresolved upstream notice:** the published `@khanacademy/mathjax-renderer`
3.0.0 package has neither a license field nor a license file, and its declared
`Khan/mathjax-renderer` repository was unavailable when checked. The same public
package is used by the pinned Kolibri integration. No license is inferred for it.
See `licenses/npm/UNRESOLVED-NOTICES.txt` and preserved package metadata. Review
that upstream permission and asset/font notices before redistributing a release;
this local build does not establish redistribution clearance.
