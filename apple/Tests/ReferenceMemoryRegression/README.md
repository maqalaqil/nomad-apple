# Reference import memory regression

Run from the repository root:

```sh
python3 apple/Tests/ReferenceMemoryRegression/run.py
```

The script compiles the production importer with optimization and Swift concurrency warnings, then imports 50,000 explicitly synthetic, nonclinical openFDA-shaped records from a temporary local file. Fixture generation also uses bounded per-record memory. No clinical corpus, network, app container or connected device is used. Foundation file coordination may require running outside a restricted process sandbox.

The test samples resident memory during the real actor import and cancels if growth exceeds 96 MiB or import time exceeds 150 seconds. It checks the exact record count, source date, preparation without activation, subsequent activation, grouped result count and the original first record's warning text. Temporary source/database files are removed afterward.

Verified development-Mac run: 24,366,720 input bytes; RSS baseline 8,765,440 bytes, peak 47,775,744 bytes, growth 39,010,304 bytes; 7.17 seconds through import and query checks. The existing 76 native Reference checks and physical iPadOS 26.5 SDK typecheck passed separately. Timings/RSS are observations from this optimized synthetic workload, not medical accuracy, real-dataset completeness or physical-iPad performance claims.
