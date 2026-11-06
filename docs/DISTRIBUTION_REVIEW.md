# Outstanding distribution review

Prepared for NOMAD Apple 1.0 (9), 5 November 2026. This is a factual review brief, not a claim of legal clearance. The App Store records and screenshots are prepared; no binary has been uploaded or submitted.

## GPL components and Store terms

The executable links the official CoreKiwix 14.2.1-2 static framework, including GPL libzim, libkiwix and Xapian. The bundled IT Tools workspace is GPL-3.0. NOMAD-authored code is Apache-2.0; preserving that notice does not exempt the combined executable from applicable GPL obligations. The source is public and the exact native source/notice inventory is available in [NATIVE_SOURCE_INVENTORY](NATIVE_SOURCE_INVENTORY.md). Official Kiwix Apple apps provide relevant precedent, but NOMAD has not established an applicable additional permission or its complete distribution plan.

The review must establish:

1. The license under which the combined binary is conveyed, while preserving upstream and NOMAD source notices.
2. The complete corresponding-source package and reproducible build materials to accompany the binary, including third-party sources and modifications.
3. Whether the selected Apple distribution terms and any custom EULA satisfy those component licenses; if additional permission is needed, who can grant it and whether it covers these exact components and versions.

A generic publisher approval to proceed cannot supply rights held by third-party copyright holders. No upstream license has been changed, and no external permission request has been sent.

Draft inquiry for a qualified reviewer or relevant rights holder:

> NOMAD Apple is a free, source-available iPhone/iPad/native Mac application. We statically link the official CoreKiwix 14.2.1-2 framework and bundle IT Tools v2024.10.22-7ca5933 in a local WebKit workspace. Our source, dependency pins and notices are at https://github.com/maqalaqil/nomad-apple. We intend to provide complete corresponding source with the binary. Please identify the licensing/distribution conditions needed to distribute this combination through Apple's App Store, including any additional permission or EULA requirements. We are seeking confirmation of the applicable terms, not a relicensing of third-party contributions you do not control.

## Privacy labels

The app has no NOMAD account, analytics backend, cloud inference or advertising integration. Local documents and model prompts stay local in the audited paths. Built-in online catalogs/downloads nevertheless contact independent Kiwix, Hugging Face and Source Cooperative endpoints. Some providers retain request metadata; remote catalog searches transmit search terms. See [PRIVACY_AUDIT](PRIVACY_AUDIT.md).

Resolve the scope of Apple's third-party-partner/collection definition for these integrations and map any covered retained data to its actual purpose and linkage. Source Cooperative's [open privacy-policy issue](https://github.com/source-cooperative/source.coop/issues/360) is an identified missing input. The app's public policy already describes provider requests, but no final collection label or empty collected-data manifest was asserted. A user-supplied download URL is not automatically an analytics partner; provider logging is not automatically absent either.

## Encryption

Vault recovery uses Apple's AES-GCM and PBKDF2. Bundled CyberChef and IT Tools provide additional published cryptographic operations. France is excluded from the first release. Apple's questionnaire, answered for standard algorithms outside the OS and no France distribution, returned no document-upload requirement. This does not establish that the app has no encryption or settle every US classification/reporting obligation. Confirm coverage of the full bundled algorithm inventory before setting an exemption key or associating a declaration with an uploaded build. See [Apple's export documentation table](https://developer.apple.com/help/app-store-connect/reference/app-information/export-compliance-documentation-for-encryption/) and [overview](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance/).

## Remaining technical acceptance

The final production-identity archives need distribution export/server validation. TestFlight installation, physical iPhone/M1 and Intel Mac coverage, actual English/Arabic translation execution and disconnected cold launch remain distinct from the simulator and local Mac results. See [VALIDATION](VALIDATION.md). No app has been represented as approved or live.
