# Offline PMTiles map assets

`PMTilesView` imports complete local PMTiles v3 archives into Application Support,
validates the header and directory extents, and reads requested byte ranges through
`nomad-map://archive/…`. It does not load a whole map archive into memory or require
a server. Every individual requested read is capped at 32 MiB. The originals in
Files are retained; deletion removes the imported app copy.

The map bundles MapLibre GL 4.7.1, PMTiles JS 4.4.0, and NOMAD's style, all its glyph
ranges, and all its sprite assets. `@protomaps/basemaps` 5.7.0 is pinned with the
upstream dependency set; the actual style is NOMAD's packaged JSON. The native
scheme handler only serves bundled assets and registered archive files. A CSP and
WebKit content blocker deny HTTP/HTTPS/WebSocket requests. Worker code comes from
the local JS bundle. The selected archive's attribution is displayed as sanitized
text, without loading or navigating external attribution links.

## Build

Run from the repository root:

```sh
python3 apple/scripts/fetch-map-assets.py
python3 apple/scripts/fetch-map-assets.py --verify
```

The fetch requires Python 3.11+, Node/npm, and internet on the development Mac.
Versions and npm transitive dependencies are pinned in the package lock. The
downloaded NOMAD `base-assets.tar.gz` is pinned by SHA-256 in `assets-release.json`.
An offline rebuild can pass `--archive /path/to/base-assets.tar.gz --npm-offline`
if the npm cache is populated. Generated files are ignored; the script writes a
SHA-256 installation manifest for every bundled file.

Xcode must copy the entire `Resources/WebTools` folder into the app as `WebTools`,
preserving directories. Runtime path: `Bundle.main.resourceURL/WebTools/Maps`.
Do not add npm `node_modules` to the app. Map content is imported separately.

## Source and licenses

* NOMAD map assets: `Crosstalk-Solutions/project-nomad-maps`, commit
  `5b444051914fbf4960be2e64c0fb11f507db7efd`, archive SHA-256
  `93181e170120fbb32d00ee1cd00c2f79a9c771e29573023bac54f512f80be370`.
* MapLibre GL 4.7.1: BSD-3-Clause, license copied from the pinned npm package.
* PMTiles: BSD-3-Clause. License source is
  `protomaps/PMTiles/aec8fa1341222fdddb3318e9ffa8e18e19b312f7/LICENSE`.
* Protomaps style code: BSD-3-Clause; visual design CC0. License source is
  `protomaps/basemaps/42ffaaa4a85a41bfcb23e43cc0f5b492a5eca123/LICENSE.md`.
* Noto glyphs: SIL OFL, included at `basemaps-assets/fonts/OFL.txt`.
* Map symbols: MIT, license source
  `tangrams/icons/92510779634f4a006c61ea70e50cb8c52c765a81/LICENSE.md`.

License source pins identify the notice texts, separately from engine version
pins. Notices are bundled under `licenses/` and alongside the font data. Imported
map archives have their own data attribution/license requirements. The app does
not infer a data license when metadata does not provide one.

## Verified behavior and limits

The macOS WebKit smoke runner uses the same native asset/range handler as the iPad
app. It validated header/range rejection, real rendering of NOMAD's pinned
`delaware_2025-12.pmtiles` (31,523,716 bytes, SHA-256
`be55ff8b6ae37372ddeb8278561a41415fff3f8505f56a80aece8e891a2ea4c9`),
1,578 rendered features, local labels/route shields, saved pin, and rejection of a
remote fetch. The screenshot was inspected. That fixture is not bundled.

```sh
xcrun swiftc -swift-version 5 -module-cache-path /tmp/nomad-map-swift-cache \
  apple/App/Collections/LocalManifestFile.swift \
  apple/Sources/NomadCore/InternalDownloadLink.swift \
  apple/App/Maps/PMTilesArchive.swift apple/App/Maps/PMTilesAssetHandler.swift \
  apple/scripts/fetch-map-assets.smoke.swift -o /tmp/nomad-map-smoke
/tmp/nomad-map-smoke "$PWD/apple/Resources/WebTools/Maps" /path/to/delaware_2025-12.pmtiles
```

The implemented workflow includes multiple imported archives with individual
visibility, coordinate search, zoom/pan/rotation, saved pins/notes, and archive
deletion. The style targets NOMAD/Protomaps vector layers with `kind` properties.
The older `pmap:kind` schema and unrelated vector schemas require a different style
and are reported as unsupported. Raster PMTiles use MapLibre's raster source;
vector rendering was the tested path. The decoder supports gzip/uncompressed
version 3 archives, not Brotli/Zstandard or older archive versions. Font coverage
is limited to the complete upstream glyph package, not every Unicode character.

Automatic region downloads/extraction, offline address geocoding, directions,
terrain, GPS, arbitrary user styles, and edits to map geometry are not implemented
here. Region files already extracted by NOMAD can be imported and layered. Physical
M1 iPad performance, Files imports at multi-gigabyte scale, and airplane-mode
operation on the signed device still need device testing.

Reference: [Protomaps MapLibre integration](https://docs.protomaps.com/basemaps/maplibre)
and [upstream basemap asset licenses](https://github.com/protomaps/basemaps-assets).
