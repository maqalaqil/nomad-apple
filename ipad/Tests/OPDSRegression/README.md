# Custom OPDS catalogs

The native browser implements public **OPDS 1.x Atom/XML** navigation and acquisition feeds, standalone entries, facets, categories, paging, and OpenSearch keyword templates. Sources are user-added HTTPS URLs; the Kiwix button only prefills the official catalog address. Downloads begin only after confirming a direct acquisition. Purchase, subscription, borrowing, indirect acquisition, DRM, authentication, and OPDS 2 JSON are explicitly unsupported.

Metadata requests reject HTTP, credential-bearing URLs, unsafe redirects, failed HTTP status, responses above 4 MiB (including streamed/decompressed bytes), XML entities/DOCTYPEs, and non-UTF-8 XML. Parsing also bounds depth, node count, entries, links and text. Summaries are displayed as native text; feed HTML/scripts/images are not loaded. This is metadata validation, not a guarantee of a publisher's trustworthiness or the safety/license of a publication.

`OPDSCatalogStore` saves user catalogs and up to 1,000 acquisition-request provenance records in `Application Support/NomadPad/Catalogs/catalogs.json`. It caches up to 64 feed/search snapshots under `Catalogs/Cache`. Opened cached pages work without a connection; refreshing and uncached navigation/search require internet. Saved page timestamps remain visible. Cache eviction never removes imported publications or download entries. Broken settings are preserved and block writes until a successful reload. An acquisition receipt records a request, not completion.

The queue hands a publisher's `length`, when present, to `DownloadStore`. Metalink 4 acquisitions first resolve a bounded single-file metadata document to an HTTPS mirror, exact size, and published SHA-256 if available; both the catalog URL and resolved URL are retained as provenance. Ordinary direct links retain their URL and are clearly labeled when no hash is available. A MIME-derived suggested filename makes extensionless EPUB/PDF/ZIM endpoints usable in the native readers. Unsupported file formats remain downloadable/shareable and are labeled accordingly. Downloads applies its existing known-size queue capacity and completion checks.

Live Kiwix metadata required three narrowly scoped compatibility rules: its v2 feed omits page links (the browser requests 40 entries and uses the returned counters); its XML currently leaves some query-string ampersands unescaped (only the known endpoint's `&parameter=` spelling is escaped before XML parsing); and its OPDS lengths round up to KiB. For official Kiwix Metalinks with SHA-256, only that exact rounding difference is accepted, and the UI discloses it while enforcing the Metalink's exact byte length. Conflicting sizes from other providers are rejected. Entity/DOCTYPE rejection still runs before any XML repair. OpenSearch index offsets, including Kiwix's zero-based start, are respected.

Run the network-free regression from the repository root:

```sh
xcrun swiftc -parse-as-library -swift-version 5 -warn-concurrency \
  ipad/App/Catalogs/OPDSModels.swift ipad/App/Catalogs/OPDSParser.swift \
  ipad/App/Catalogs/OPDSClient.swift ipad/App/Catalogs/OPDSMetalink.swift \
  ipad/App/Catalogs/OPDSCatalogStore.swift \
  ipad/Tests/OPDSRegression/main.swift -o /tmp/nomad-opds-regression
/tmp/nomad-opds-regression
```

The test uses original XML and local URLProtocol fixtures. It checks actual parser namespace/base resolution, direct/protected acquisition distinctions, XML limits, Unicode search encoding, cached page/search/provenance persistence, failed writes, corrupt-settings preservation, HTTP rejection and a streamed response exceeding the limit. An optional argument supplies an already downloaded official Kiwix XML fixture. The official Kiwix root feed was separately fetched on November 3, 2026 (local time) and parsed as four navigation entries plus three links. No archive payload was downloaded. New code also typechecked against the iPadOS 26.5 SDK; on-device navigation and network-loss acceptance remain separate.

References: [OPDS 1.2 specification](https://specs.opds.io/opds-1.2), [official Kiwix catalog](https://library.kiwix.org/catalog/v2/root.xml).
