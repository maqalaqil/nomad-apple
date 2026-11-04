# Translation state ordering regression

The production `TranslationRequestState` protects two asynchronous UI boundaries:

1. Language availability belongs to the captured source/target pair and latest refresh request. A late manual check cannot replace the status for a changed pair, and an older refresh of the same pair cannot replace the newer refresh.
2. A text response belongs to the captured original text, language pair and request token. The view sends that immutable snapshot to Apple Translation, disables the source editor during the operation, clears displayed output when input changes, and rejects results/errors after the view leaves or the identity changes.

A deterministic deferred provider holds individual requests until the test releases their continuations. No sleep-based ordering, Translation framework, installed model, network request or physical device is required. Twelve async checks cover reversed completion order, picker changes before replacement checks start, repeated same-pair refreshes, task cancellation, submitted source snapshots, changed source text/direction, replaced operations and leaving the view. Six additional checks cover generic Arabic resolving to a supported Arabic variant even when an unrelated language sorts first, preserving an exact saved regional variant, normalized locale spelling, English normalization, explicit unsupported-language absence, and diagnostic preference across swapped directions.

From the repository root:

```sh
xcrun swiftc -parse-as-library -swift-version 5 -warn-concurrency \
  apple/App/Tools/TranslationRequestState.swift \
  apple/Tests/TranslationStateRegression/main.swift \
  -o /tmp/nomad-translation-state-regression
/tmp/nomad-translation-state-regression
```

The helper must be included in the generated Xcode project along with `TranslationView.swift`. `TranslationLanguageResolver.resolve(preferredIdentifier:supported:)` selects an exact normalized identifier, then a supported language with the same base code, or returns nil. Both text and ZIM panels preserve an unsupported selection visibly rather than silently replacing it with an unrelated language. They wait for supported-language resolution before checking readiness.

`TranslationLanguageResolver.resolve(baseCode:preferredIdentifiers:supported:)` lets diagnostics prefer the exact saved model variant from either direction. For example, a saved `ar-AE` must be checked as `ar-AE`; generic `ar` can report different installation status. Resolution itself does not prove that models are installed.

## Physical preparation / acceptance

Open **Knowledge → Translation**, or use the existing debug module launch arguments `--module translation` without a competing `--device-validation` argument. Set **From English / To Arabic**, tap **Download / prepare languages** when shown, and accept the system prompt. Tap **Check language availability** until the status is installed. Swap to **Arabic / English**, check again, and prepare only if required. This does not require a ZIM archive.

Apple documents that [`prepareTranslation()`](https://developer.apple.com/documentation/translation/translationsession/preparetranslation()) can return while languages are already downloading. Its return alone is not a completed-install signal; [`status(from:to:)`](https://developer.apple.com/documentation/translation/languageavailability/status(from:to:)) checks readiness for the selected pair. The view now describes this distinction if preparation returns before installed status.

A short actual translation in each direction is a separate acceptance check. Both text and article translation use [`init(installedSource:target:)`](https://developer.apple.com/documentation/translation/translationsession/init(installedsource:target:)), which cannot request absent model downloads. The ZIM path additionally checks `canRequestDownloads == false` and `isReady` before capturing the page.

For article acceptance, open a local ZIM, choose an article, tap **Translate**, choose the correct source/target, then **Translate article offline**. Confirm readable translated text, preserved local images/links and **Restore original**. The current safety bounds reject an entire article above 512 text runs / 60,000 UTF-16 characters / 4,000 characters in one run; they do not silently translate just a prefix. Source text is sent per existing text node, so wording across inline links requires review. Search uses the archive's original-language index. Switching article or closing its reader restores the original by reloading the archive; translated displays are temporary.

No new preparation download or physical translation was performed by this regression. The parent device-validation workflow checks actual installed models and translated output; disconnected-device verification remains distinct from an installed-only session used while online.
