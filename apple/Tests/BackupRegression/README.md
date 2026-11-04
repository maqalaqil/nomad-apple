# Native backup regression harness

Run from the repository root on macOS with Xcode installed:

```sh
python3 apple/Tests/BackupRegression/run.py
```

The script compiles the production backup engine/coordinator and production notes/inventory/reading-mark validators with Swift 5 language mode and concurrency warnings. It creates only temporary local fixtures and an isolated UserDefaults suite. All content is synthetic and explicitly test-only. No network, user app containers, downloads or Keychain are used. Foundation file coordination may require execution outside a restrictive process sandbox.

Verified result: **140 native checks passed**. The final Backup/Reference SwiftUI modules, shared directory resolver and validators also typecheck against the iOS 26.5 simulator SDK.

Coverage includes streamed export and SHA-256 integrity; allowlisted/typed settings and unselected-preference isolation; strict conversation, inventory and reading-mark validation; optional-content dependencies; selective staging; concurrent scheduling from two workers; live-download exclusion; storage preflight; source mutation; cancellation after a real 1 MiB copy; path traversal, symlink and same-length tamper rejection; preservation of files absent from a package; activation, preferences and rollback; corrupt-journal fail-closed behavior; staged tampering immediately before activation; destination symlink rejection.

Notes coverage includes legacy archives without trash, exact restoration of active notes plus trash, duplicate/disjoint UUID checks, malformed trash, overlong bodies and NUL rejection, and bounded sort/home-search preference restoration and rollback. Mixed `Nomad`/`NOMAD` fixtures check read-only resolution to existing directory spelling on a confirmed case-insensitive host volume, inventory export without omission, activation/rollback, sibling-note preservation and symbolic-root rejection. These host engine checks do not establish simulator/device backup UI behavior.

Separate child processes terminate with `_exit(77)` at the real coordinator boundaries after old-file rename, after new-file rename, after preferences, before commit and after commit. Further child crashes test cleanup after durable intent, after staged-folder removal and after recovery-folder removal. A subsequent invocation uses the production startup recovery path and checks active data and unrelated folders. Injected I/O failure also exercises in-process rollback.

This harness validates local engine behavior, not iPadOS file-provider performance, whole-app UI lifecycle, medical content, PDF attachment rendering or complete upstream NOMAD parity. Backed-up test attachment bytes are deliberately synthetic; only length/digest and metadata semantics are asserted.

## Streaming memory regression

Run `python3 apple/Tests/BackupRegression/memory.py` for a separate production `BackupFileIO.copyAndHash` RSS check. It hashes a 512 MiB synthetic sparse file, then copies and hashes it, with one outer autorelease pool around each complete worker operation. SHA-256 and exact byte counts are checked; sampled RSS growth must stay below 64 MiB. Only temporary synthetic files are created, with about 512 MiB needed for the output copy.

The unchanged production implementation passed both operations on the development Mac: hash-only peak growth 2,195,456 bytes; copy-plus-hash growth 0 bytes in the recorded run. This confirms that its existing per-read pool drains temporary buffers for this workload; it is not a physical-iPad memory measurement or validation of every backup size/provider.
