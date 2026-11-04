# Local vault recovery

The vault retains its existing Keychain service/account and access control:
`kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly` with `.userPresence`. Saving and
restoring use one update to the existing Keychain item after validation. Existing
credential IDs are retained during import, including their current passwords;
backup records with matching IDs are skipped. Nothing is written to Keychain
until authenticated decryption, validation, merge checks, and explicit review
succeed. The app provides neither cloud synchronization nor system AutoFill.

## Encrypted backup format, version 1

Files ending in `.nomadvault` contain binary data:

| Bytes | Meaning |
| --- | --- |
| 0–7 | ASCII `NMVLTBK1` |
| 8–11 | Unsigned big-endian PBKDF2 iteration count, exactly 600,000 |
| 12–43 | 32 random salt bytes |
| 44 onward | CryptoKit AES-GCM combined representation: 12-byte nonce, ciphertext, 16-byte tag |

The 44-byte header is authenticated as AES-GCM additional authenticated data. The
32-byte AES key is derived by CommonCrypto PBKDF2-HMAC-SHA256 with 600,000 rounds.
Passphrases are Unicode NFC-normalized and encoded as UTF-8, with explicit byte
length passed to CommonCrypto. Every export uses a new system-generated salt and
CryptoKit-generated nonce. The encrypted payload is JSON with `version: 1`,
`createdAt` (Foundation's default Date encoding), and `entries` containing the
credential fields. A future format/KDF change must use a new version; unknown
parameters are rejected before expensive derivation.

The export UI requires a passphrase of at least 20 characters, matching
confirmation, and acknowledgment that the user has retained the passphrase
separately. Length alone is not an entropy guarantee; the UI recommends several
randomly chosen words. There is no passphrase recovery service. Neither plaintext
backup files nor passphrase files are created.

The entire encrypted file is bounded to 4 MiB before decryption, with a bounded
read after file coordination to handle Files providers safely. Symlinks are
rejected. Payloads are limited to 5,000 credentials, unique UUIDs, 16 KiB per
ordinary field, 64 KiB per note, and the complete encoded backup size. Ordinary
Keychain edits use the same limits, so new data remains exportable. Failed
authentication, malformed data, duplicate IDs, excessive fields, and oversized
merged vaults produce a visible error without replacing stored credentials.

## Generator and lifecycle

Password generation uses `SecRandomCopyBytes` with rejection sampling, avoiding
modulo bias. Generated passwords include every selected character group; the UI
offers 12–128 characters and optional ambiguous-character exclusion. Copy uses a
local-only pasteboard item with a 45-second expiration.

Unlocked content locks on inactivity/background; in-progress biometric unlock
retains the existing attempt gate so the system authentication sheet can finish.
Views are covered and marked privacy sensitive while inactive. Recovery work runs
off the main thread, with cancellation and a `VaultUnlockGate` token checked
before any result is displayed. Lock/dismissal invalidates the token, clears
drafts, and cancels the task. PBKDF2 itself is synchronous and cannot be interrupted
mid-call; the result is discarded after cancellation. Swift strings and system
frameworks can retain copies in memory, so clearing view state and temporary
buffers is not a guarantee of forensic memory erasure.

## Verification

```sh
python3 ipad/App/Vault/Tests/run_vault_tests.py
python3 ipad/App/Collections/Tests/run_native_safety_tests.py
```

The vault tests exercise real CryptoKit/CommonCrypto operations with synthetic
credentials: round trip, wrong passphrase, salt/nonce/ciphertext/tag tampering,
fresh salt/nonce, NFC normalization, malformed and oversized input, coordinated
file bounds/symlink rejection, authenticated duplicate IDs, merge conflicts,
failed-import writer preservation, generator character groups, and stale-attempt
rejection. They do not read or alter a user's Keychain. Apple file coordination
requires its normal system service; a restrictive tool sandbox can block these
tests even though the same binary passes outside that sandbox.

The full module typechecks for iOS 26 in Swift 5 mode. Actual passcode/biometric
Keychain access, lock timing around Files/share extensions, encrypted export and
recovery on a signed physical iPad still require device QA. A backup should be
kept in Files locally for offline recovery; a cloud-only file may need downloading
before the iPad goes offline.
