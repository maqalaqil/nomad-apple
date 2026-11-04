#!/usr/bin/env python3
"""Run isolated download queue tests and production large-file RSS verification."""
from pathlib import Path
import subprocess
import tempfile

here = Path(__file__).resolve().parent
ipad = here.parents[1]
with tempfile.TemporaryDirectory(prefix="nomad-download-regression-") as temporary:
    for name in ("main", "memory"):
        binary = Path(temporary) / name
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
                        "-module-cache-path", "/tmp/nomad-download-module-cache",
                        str(ipad / "App/Downloads/DownloadStore.swift"), str(here / f"{name}.swift"),
                        "-o", str(binary)], check=True, timeout=180)
        subprocess.run([str(binary)], check=True, timeout=240)
