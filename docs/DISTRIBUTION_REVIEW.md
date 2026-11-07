# Outstanding distribution review

Updated for NOMAD Apple 1.0 (9), 6 November 2026. This is a factual review brief, not a claim of legal clearance. Both platform builds have been uploaded for private App Store Connect processing. Neither has been submitted for App Review or released; open declarations and distribution terms remain unresolved.

## GPL components and Store terms

The executable links the official CoreKiwix 14.2.1-2 static framework, including GPL libzim, libkiwix and Xapian. The bundled IT Tools workspace is GPL-3.0. NOMAD-authored code is Apache-2.0; preserving that notice does not exempt the combined executable from applicable GPL obligations. The source is public and the exact native source/notice inventory is available in [NATIVE_SOURCE_INVENTORY](NATIVE_SOURCE_INVENTORY.md). Official Kiwix Apple apps provide relevant precedent, but NOMAD has not established an applicable additional permission or its complete distribution plan.

The review must establish:

1. The license under which the combined binary is conveyed, while preserving upstream and NOMAD source notices.
2. The complete corresponding-source package and reproducible build materials to accompany the binary, including third-party sources and modifications.
3. Whether the selected Apple distribution terms and any custom EULA satisfy those component licenses; if additional permission is needed, who can grant it and whether it covers these exact components and versions.

A generic publisher approval to proceed cannot supply rights held by third-party copyright holders. No upstream license has been changed.

With the publisher's authorization, licensing inquiries were posted on 6 November 2026:

- [Kiwix/libkiwix #1408](https://github.com/kiwix/libkiwix/issues/1408): CoreKiwix and its bundled native components.
- [IT Tools #1911](https://github.com/CorentinTh/it-tools/issues/1911): the bundled offline WebKit workspace.

Both inquiries remain open. A [Kiwix reply](https://github.com/kiwix/libkiwix/issues/1408#issuecomment-6690717566) mentions a User-Agent observed in logs but does not answer the licensing questions or grant additional permission. The mentioned User-Agent has not been attributed to this build. IT Tools has no reply as of this check. Clarification remains pending; posting an inquiry does not grant permission or resolve the distribution review.

Inquiry outline for a qualified reviewer or relevant rights holder:

> NOMAD Apple is a free, source-available iPhone/iPad/native Mac application. We statically link the official CoreKiwix 14.2.1-2 framework and bundle IT Tools v2024.10.22-7ca5933 in a local WebKit workspace. Our source, dependency pins and notices are at https://github.com/maqalaqil/nomad-apple. We intend to provide complete corresponding source with the binary. Please identify the licensing/distribution conditions needed to distribute this combination through Apple's App Store, including any additional permission or EULA requirements. We are seeking confirmation of the applicable terms, not a relicensing of third-party contributions you do not control.

## Privacy labels

The app has no NOMAD account, analytics backend, cloud inference or advertising integration. Local documents and model prompts stay local in the audited paths. Built-in online catalogs/downloads nevertheless contact independent Kiwix, Hugging Face and Source Cooperative endpoints. Some providers retain request metadata; remote catalog searches transmit search terms. See [PRIVACY_AUDIT](PRIVACY_AUDIT.md).

Resolve the scope of Apple's third-party-partner/collection definition for these integrations and map any covered retained data to its actual purpose and linkage. Source Cooperative's [open privacy-policy issue](https://github.com/source-cooperative/source.coop/issues/360) is an identified missing input. The app's public policy already describes provider requests, but no final collection label or empty collected-data manifest was asserted. A user-supplied download URL is not automatically an analytics partner; provider logging is not automatically absent either.

## Encryption

Vault recovery uses Apple's AES-GCM and PBKDF2. Bundled CyberChef and IT Tools provide additional published cryptographic operations. France is excluded from the first release. An earlier standard-algorithms-only questionnaire returned no document-upload requirement. A later tentative selection of both categories prompted a CCATS attachment, but the classification remains unresolved as explained below. This does not establish that the app has no encryption or settle every US classification/reporting obligation. Confirm coverage of the full bundled algorithm inventory before setting an exemption key or associating a declaration with an uploaded build. See [Apple's export documentation table](https://developer.apple.com/help/app-store-connect/reference/app-information/export-compliance-documentation-for-encryption/) and [overview](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance/).

### Prepared encryption evidence

[RELEASE_CRYPTO_INVENTORY.json](RELEASE_CRYPTO_INVENTORY.json) is generated from pinned local resources by [inventory-release-crypto.py](../apple/scripts/inventory-release-crypto.py). It identifies all 505 CyberChef catalog entries before extracting the six cryptography-related module groups and ten related operations from other modules. These groups include checksum, parsing and historical operations as well as modern encryption; a module name is not an export classification. The JSON records source hashes and the concrete IT Tools selector (AES, TripleDES, Rabbit and RC4), plus RSA key generation, bcrypt and hash/HMAC source evidence.

The native vault uses Apple CryptoKit AES-256-GCM and CommonCrypto PBKDF2-HMAC-SHA256 with 600,000 iterations and a 32-byte salt. Security supplies random bytes. The prepared Excalidraw bundle's observed `crypto.subtle` call computes a SHA-1 digest; that finding is not a blanket claim about every dependency. Archive/password operations and bundled implementations still need inclusion in the final classification review.

The factual questionnaire inputs are: encryption is present; it is not limited to Apple OS implementations; the release includes third-party JavaScript encryption; France is excluded. Do not convert those facts into an unsupported claim that every operation fits Apple's industry-standard category. No ECCN, CCATS or `ITSAppUsesNonExemptEncryption` value has been assigned by this inventory. The [current BIS regulation](https://www.bis.gov/regulations/ear/742) distinguishes publicly available encryption source/object-code conditions and non-standard cryptography; the [ENC provisions](https://www.bis.gov/regulations/ear/740) have separate classification/reporting rules. Public GitHub hosting alone is not the completed analysis. No regulatory notification has been sent.

Reproduce the evidence without network access:

```sh
python3 apple/scripts/inventory-release-crypto.py --output docs/RELEASE_CRYPTO_INVENTORY.json
```

## Remaining technical acceptance

The production-identity archives and local App Store exports pass signature/resource checks and package analysis. Apple accepted both uploads. Both iOS and macOS build 9 processed and are selected in their drafts with Missing Compliance. Apple's iOS and macOS submission validation explicitly requires Content Rights Information, export-compliance information and App Privacy answers. TestFlight installation, physical iPhone/M1 and Intel Mac coverage, actual English/Arabic translation execution and disconnected cold launch remain distinct from the simulator and local Mac results. See [VALIDATION](VALIDATION.md). No app has been represented as approved or live.


## Full-cipher questionnaire follow-up — 6 November 2026

The build-specific form offers standard algorithms, proprietary or nonstandard algorithms, both, or neither. The pinned CyberChef catalog includes LS47; its [v11.5.0 implementation](https://github.com/gchq/CyberChef/blob/v11.5.0/src/core/operations/LS47Encrypt.mjs) describes a modified ElsieFour construction and custom password expansion (retrieved Git blob `02f7d99451e61f295fe38c6110ab05a63cc5c9a6`). LS47 is also [publicly documented](https://github.com/exaexa/ls47).

**Correction:** the earlier assessment treated lack of international standardization as sufficient to select the nonstandard category. Apple's [overview](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance/) also includes a qualification concerning functionality that has not otherwise been published. Publication therefore matters; LS47's presence alone does not establish regulatory nonstandard status. Neither this inventory nor the exploratory questionnaire is a completed export classification.

The tentative selection of both categories, with France excluded, led to a required BIS CCATS approval attachment and a disabled Save button. The entered purpose text described standard and nonstandard ciphers; that description was provisional and is not a verified classification. The dialog was cancelled without saving. This records the result of that specific answer path, not a definitive CCATS requirement for NOMAD. Neither the earlier standard-only result nor this tentative result resolves which path applies to the complete build. No algorithm was removed, no exemption was asserted, and neither build's Missing Compliance status was cleared.

The publisher was asked whether a covering CCATS document exists; no answer has been recorded. The prepared Apple inquiry now asks specifically about the published-functionality qualification and the correct documentation route. If formal classification is required, [BIS describes the official request process](https://www.bis.gov/licensing/classify-your-item). No BIS account, classification request or government certification has been submitted.

The Content Rights form was inspected separately. Its affirmative answer combines access to third-party content with an assertion that the publisher has the necessary rights. Its negative answer says the app does not contain/show/access third-party content. The latter is factually inapplicable. The former remains pending verification of the applicable rights and conditions; the dialog was cancelled without an attestation. This content declaration does not independently resolve the combined executable's GPL distribution terms.

### Apple clarification request — sent 7 November 2026

Subject: Encryption documentation for NOMAD Apple 1.0 (9), app 6831442886

NOMAD Apple is a free offline knowledge/tool app for iPhone, iPad and Mac, version 1.0 build 9, app ID 6831442886. Its bundled CyberChef v11.5.0 and IT Tools implement AES and other published encryption operations, including publicly documented educational LS47 (https://github.com/exaexa/ls47). The full source and algorithm inventory are public at https://github.com/maqalaqil/nomad-apple/blob/main/docs/RELEASE_CRYPTO_INVENTORY.json. A tentative selection of both algorithm categories, with France excluded, prompted a BIS CCATS approval attachment; we cancelled without saving. Your export-compliance overview includes the qualification that nonstandard functionality has not otherwise been published. Please clarify how that qualification applies to these published algorithms, which questionnaire route and documentation Apple requires for the complete build, and whether any publicly available software provision is relevant. We are not asserting a CCATS number, exemption or regulatory classification, and intend to retain the complete cipher collection.

With the publisher's authorization, this clarification was submitted through Apple's official [encryption support route](https://developer.apple.com/contact/topic/SC1110/subtopic/30067/solution/select) on 7 November 2026. Apple displayed “Thanks for contacting us” and issued a case ID, retained in the local release records. The form included app ID 6831442886 and reproduction steps for the unsaved questionnaire. A response is pending; case creation is not encryption approval or an export classification.
