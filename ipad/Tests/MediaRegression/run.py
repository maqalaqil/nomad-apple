#!/usr/bin/env python3
"""Compile and run the production media engines against isolated temporary fixtures."""
from pathlib import Path
import subprocess
import tempfile

ipad = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="nomad-media-regression-") as temporary:
    binary = Path(temporary) / "media-tests"
    sources = ["LocalManifestFile.swift", "CollectionStorageDirectory.swift", "CollectionStorage.swift", "MediaLibraryStore.swift", "MediaPlaybackSession.swift"]
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-module-cache-path", "/tmp/nomad-media-module-cache",
                    *[str(ipad / "App/Collections" / name) for name in sources], str(Path(__file__).with_name("main.swift")), "-o", str(binary)], check=True, timeout=180)
    subprocess.run([str(binary)], check=True, timeout=60)
