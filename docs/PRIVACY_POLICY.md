# NOMAD Apple privacy policy

**Effective 5 November 2026.** This policy describes the current NOMAD Apple development build for iPhone, iPad and Mac. The publisher is **Maher Mansour M Al Aqil**. For private support or privacy requests, contact **[maheralaqil1993@gmail.com](mailto:maheralaqil1993@gmail.com)**.

NOMAD Apple is a workspace for using downloaded content and local tools. The app does not require a NOMAD account. Documents, notes, conversations and other workspace records are stored on your device. Some features use the internet when you choose them, and files you export can leave your device through the destination you select.

## Information used on your device

The app can store the files you import or download, extracted text and search indexes, notes, bookmarks, reading and playback positions, playlists, drawings, inventory records and attachments, manually saved map places, course learner names and progress, exercise answers, assistant conversations and preferences. These records support the features you use. They are not automatically uploaded to a NOMAD service by this build.

The local assistants process prompts and selected document excerpts using an available on-device Apple model or an imported GGUF model. PDF text recognition runs locally. Translation uses installed language models; preparing languages may contact Apple's download services. Model availability is controlled by your device and operating system. The app does not configure a cloud inference or translation provider.

Local benchmark history can include your device model, operating-system/app version, processor and memory information, power/thermal state, the tag you enter and measured performance. These results remain local unless you export them. The app does not submit them to a leaderboard.

## Connections you choose

Downloading a file sends a request to its host. Browsing an uncached online catalog, refreshing a catalog or using its remote search also contacts its provider. A remote catalog search sends your search terms. Filtering an already saved catalog page is local. Downloads you previously queued can resume later; iPhone and iPad downloads may continue in the background. Pause or remove unwanted queued transfers in Downloads.

Providers and their delivery services receive information needed for internet requests, such as your IP address, requested URL, request time and client headers. They may retain logs under their own policies. A URL can contain a private token or search text, so use care when entering or sharing it. Built-in content sources include Kiwix, Hugging Face and Source Cooperative; you can add other HTTPS sources. See [Kiwix's privacy policy](https://get.kiwix.org/en/privacy-policy/), [Hugging Face's privacy policy](https://huggingface.co/privacy) and the policy of any other provider you use. This app cannot erase another provider's request logs.

Opening an external link hands it to the system's browser or another application, which has its own privacy practices. System-managed model downloads, device backups, cloud file providers and Apple services are governed by your system settings and those services' terms.

## Bundled web tools and permissions

CyberChef, IT Tools, Excalidraw, offline maps and course exercises use locally bundled web content. Their embedded viewers block HTTP(S) and WebSocket requests and restrict navigation to local content. Network-dependent tools and online collaboration are unavailable in these viewers. IT Tools' bundled analytics integration is disabled. The app does not configure advertising or cross-app tracking.

Some tools save recipes, settings or drawings in the app's local browser storage. Export important work before reinstalling or clearing app data. General NOMAD backups do not include this browser storage.

If you open a camera or microphone tool, the system can ask for permission. Media is used by the local tool; saving or sharing it is your choice. You can deny or revoke these permissions in system settings. File import uses the system picker; a selected cloud file may need to be downloaded by its provider. The app does not request access to your contacts or your device's current location. Saved map coordinates are places you enter or select, not a record of GPS movement.

## Vault, clipboard and security

Vault entries are stored in the device's Keychain with device authentication. The app receives the authentication result; it does not receive your Face ID or Touch ID biometric templates. The vault does not sync to a NOMAD account. Its separate recovery export is encrypted using the passphrase you provide. Keep that passphrase safe: there is no NOMAD server that can recover it for you.

Copying information puts it on the operating system's clipboard. Other applications may be able to read it, and ordinary copies can participate in system clipboard sharing. Vault copies on iPhone and iPad request local-only storage and expiry after 45 seconds. On Mac, other apps and Universal Clipboard may read copied passwords; NOMAD clears its unchanged copy after 45 seconds while the app remains running. A later copy is not cleared.

Ordinary workspace files rely on the platform's app storage and device security; they are not all separately encrypted by NOMAD. Protect your device and your backups. Imported PDFs and other documents may retain their original metadata. No storage or sharing method guarantees protection against every form of access.

## Exports, backups and deletion

Exporting or sharing a document, conversation, report or backup sends the chosen copy to the app, person or file location you select. A cloud destination can upload it. Review the copy and destination before sharing.

General `.nomadbackup` folders contain readable copies of the selected records, including private conversations, documents and settings. They are **not encrypted**. Store them securely. Vault secrets require the separate encrypted vault recovery export. Restore may retain earlier records for rollback until you discard that recovery copy.

Use a module's delete controls to remove records you no longer want. Deleting a record does not delete separate exports, backups, retained restore copies, browser drafts or information copied into another record. Remove those copies separately. Deleting a library source may also leave references or excerpts in saved conversations or indexes.

Removing the app does not erase copies saved elsewhere. Keychain data can outlive app removal; delete unwanted vault entries from within the vault. On Mac, deleting the application bundle can leave its local data container. Device/cloud backups may retain earlier copies according to their own settings. NOMAD does not promise secure erasure merely from uninstalling.

## Support and policy updates

The project repository is [maqalaqil/nomad-apple](https://github.com/maqalaqil/nomad-apple). GitHub issues are public: do not post passwords, private documents, recovery files or personal identity information there. GitHub applies its [own privacy statement](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement) to visits and submissions.

If you email support, the publisher receives your email address and the information you choose to send and uses them to respond to your request. Do not send passwords, vault recovery passphrases or unnecessary private files. Email is processed through the publisher's email provider, Google, under its [privacy policy](https://policies.google.com/privacy). You may request deletion of support correspondence at the same address, subject to any applicable record-retention obligations.

Updates to this policy will identify their effective date and reflect changes to the app's data handling. App Store distribution disclosures will be checked against the build being distributed; this development policy does not assert a completed App Store privacy review.
