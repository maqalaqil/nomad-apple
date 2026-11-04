#!/usr/bin/env python3
from pathlib import Path
import subprocess
import tempfile

ipad = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="nomad-inventory-regression-") as temporary:
    binary = Path(temporary) / "inventory-tests"
    sources = ["LocalManifestFile.swift", "CollectionStorageDirectory.swift", "InventoryModels.swift", "InventoryAttachments.swift", "InventoryStore.swift"]
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-module-cache-path", "/tmp/nomad-inventory-module-cache",
                    *[str(ipad / "App/Collections" / name) for name in sources], str(Path(__file__).with_name("main.swift")), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
