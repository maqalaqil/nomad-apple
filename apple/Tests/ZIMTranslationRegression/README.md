# ZIM article translation

An open ZIM article now has a Translate control. Language preparation is explicit and may download Apple models while online. The translation action uses `TranslationSession(installedSource:target:)`, checks readiness and `canRequestDownloads == false`, and sends batches only to the installed on-device service. Navigation and cancellation stop the operation. The original archive file is never modified.

The reader collects visible text nodes in a named isolated WebKit content world and applies completed translations with `nodeValue`, never `innerHTML`. Existing local images, anchors, styles and archive resource URLs remain in place. Code, equations, hidden text and controls are skipped. A changed or cancelled DOM snapshot cannot commit. Restore Original recovers the captured text and language/direction attributes. The translated display is temporary and is not a separate saved ZIM. Inline text runs can give the translator less grammatical context than a full paragraph, so wording around links needs review.

Bounds: 20,000 scanned DOM text nodes; at most 512 translated runs and 60,000 UTF-16 characters; 4,000 characters per input run; 20 requests per batch; 512,000 UTF-8 bytes of translated output. Larger articles produce a visible explanation rather than silently translating a prefix. Existing local-only navigation, resource handler and network-denial rules remain in effect. No native page-message bridge was added.

Run the native WebKit regression on macOS:

```sh
xcrun swiftc -parse-as-library -swift-version 5 -warn-concurrency \
  -framework AppKit -framework WebKit \
  apple/App/Library/ZIMTranslationDOM.swift \
  apple/Tests/ZIMTranslationRegression/main.swift \
  -o /tmp/nomad-zim-translation-regression
/tmp/nomad-zim-translation-regression
```

The regression passed on November 4, 2026, using original inline HTML and an embedded local SVG. It exercises the production DOM scripts in real WebKit: text capture, literal markup-looking output, inline-link/image retention, code/hidden exclusions, exact original restoration, isolated-world visibility, stale/cancelled snapshot rejection and input limits. It performs no network requests and does **not** run an Apple translation model or grade translated wording. The reader/controller/panel also typechecked against the real iPadOS 26.5 SDK and ZIM bridge. Installed-language availability and real article translation on the physical iPad remain acceptance checks.

Primary API references: [installed-only TranslationSession](https://developer.apple.com/documentation/translation/translationsession/init(installedsource:target:)), [WebKit isolated-world JavaScript](https://developer.apple.com/documentation/webkit/wkwebview/callasyncjavascript(_:arguments:in:in:completionhandler:)).
