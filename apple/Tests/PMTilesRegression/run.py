#!/usr/bin/env python3
"""Compile actual PMTiles storage code and exercise temporary synthetic fixtures.

Requires macOS NSFileCoordinator services. No network or user archives are used.
The 134.8 GB fixture is sparse and is only inspected/preflight-rejected, not copied.
"""
from pathlib import Path
import subprocess
import tempfile

ipad = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="nomad-pmtiles-tests-") as temporary:
    binary = Path(temporary) / "pmtiles-tests"
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
        "-module-cache-path", str(Path(tempfile.gettempdir()) / "nomad-pmtiles-module-cache"),
        str(ipad / "App/Collections/LocalManifestFile.swift"),
        str(ipad / "Sources/NomadCore/InternalDownloadLink.swift"),
        str(ipad / "App/Maps/PMTilesArchive.swift"),
        str(Path(__file__).with_name("main.swift")), "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True)
