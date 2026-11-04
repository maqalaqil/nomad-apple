# Download recovery and memory regressions

Run on macOS with Xcode installed:

```sh
python3 apple/Tests/DownloadStoreRegression/run.py
```

The runner compiles the production `DownloadStore.swift` with two isolated native harnesses. It uses temporary fixtures, intercepts HTTP requests, and never opens the simulator or accesses an iPad or the user's downloads.

- `main.swift` checks checksum and exact-size validation, stale callbacks, metadata-write rollback, serial queue behavior, pause/retry/remove, capacity reservations, and recovery after interruption.
- `memory.swift` recovers a persisted `verifying` entry and verifies **19,095,710,684 logical bytes** through the actual production SHA-256 worker. A sparse zero-filled file occupies less than 1 MiB of allocated file blocks. Its expected digest was calculated independently with Python `hashlib`. The test samples real process RSS, fails early above 128 MiB of growth, and requires completion within 180 seconds. It also verifies that the completed file keeps its inode, a separate manual pause remains paused, and the ready state survives reopening the store.

The memory regression catches autoreleased Foundation read buffers accumulating across the detached hashing task. Both the `FileHandle` read and `SHA256.update` must stay inside the per-iteration `autoreleasepool`; only a Boolean leaves that scope. [Apple's autorelease-pool guidance](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/MemoryMgmt/Articles/mmAutoreleasePools.html) describes local pools for loops that allocate temporary objects.

A capped macOS reproduction of the prior loop retained 201,342,976 bytes of RSS after reading 200,278,016 bytes. The pooled version read all 268,435,456 test bytes with 3,440,640 bytes of RSS growth. This establishes the memory-retention defect; it does not by itself establish the cause of a particular iPad process termination. Device verification still needs enough foreground execution time, and an interrupted verification retains its completed pending payload for recovery.
