# Library, education and map platform hosts

These modules use the same local content engines on iOS/iPadOS and native macOS. The macOS target is an AppKit/SwiftUI application, not a Catalyst wrapper. The project deployment versions, supported device families and complete-app acceptance results are documented at the repository root.

## Native presentation

- PDF previews and course PDFs use PDFKit through `UIViewRepresentable` on iOS and `NSViewRepresentable` on macOS.
- Other document previews use `QLPreviewController` on iOS and embedded `QLPreviewView` on macOS.
- ZIM, EPUB, PMTiles, HTML5 courses and Perseus use actual WKWebView hosts on both platforms. Their existing local scheme handlers, content restrictions, archive validation and storage formats are shared.
- Raster MBTiles retains the existing ImageIO validation/cache limits and renders decoded CGImages directly in SwiftUI on both platforms.
- Native form keyboard/navigation-bar preferences are platform-specific. Import/export continues through the system file picker and coordinated security-scoped file access.

EPUB keeps the existing iOS find interface and scroll delegate. On macOS, a chapter search bar calls WebKit's native text finder, while an isolated JavaScript content world observes scroll position. Archive scripts remain disabled. Position messages must match the current local chapter URL and contain a finite fraction between zero and one. The final snapshot is checked against its captured URL before saving. Restoration reads layout directly after navigation finishes; it does not wait for animation frames, which can be suspended in inactive Mac windows. Existing chapter/fragment/fraction persistence keys and reading-mark formats are unchanged.

Reader and map teardown stops loading and disconnects their delegates/message handlers. The delayed offline-content-rule callbacks check whether the host remains active before loading content.

## Focused native checks

Run from the repository root on macOS with Xcode selected:

```sh
python3 apple/App/Library/EPUBDesktopTestRunner.py
python3 apple/App/Education/CourseTestRunner.py
python3 apple/App/Education/CourseHTMLHostTestRunner.py
python3 apple/App/Education/CoursePerseusHostTestRunner.py
```

The EPUB runner creates an original temporary book and runs the production archive reader, resource handler and desktop position scripts in real macOS WebKit. Its 12 checks cover disabled archive scripts, actual position restoration and scroll messages, final-position snapshots, successful/absent text search, blocked remote fetch, and malformed/stale position events. It does not download content or use an existing library. The harness Swift source is compiled only when `NOMAD_EPUB_DESKTOP_TESTS` is set.

The existing course regression passes 78 synthetic structural/persistence checks without its optional official Kolibri metadata fixture. The actual HTML5 and Perseus native host regressions each pass seven checks; Perseus requires the prepared pinned renderer. The HTML5 harness extracts the production coordinator without replacing it. These counts describe the platform-port development runs, not universal content compatibility.

These engine checks do not establish complete iPhone, iPad or Mac UI acceptance. Real Files/Finder providers, window resizing, compact-phone layouts, accessibility, chapter navigation/relaunch, codec coverage, large archives, installed translation models and disconnected-device behavior require integrated acceptance on the supported hardware. Native macOS support does not remove the feature gaps in the repository's parity ledger.
