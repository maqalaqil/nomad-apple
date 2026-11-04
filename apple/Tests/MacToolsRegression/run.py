#!/usr/bin/env python3
from pathlib import Path
import subprocess
import plistlib
import uuid
import tempfile

root = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="nomad-mac-tools-") as temporary:
    contents = Path(temporary) / "MacToolsRegression.app" / "Contents"
    binary = contents / "MacOS" / "mac-tools-tests"
    binary.parent.mkdir(parents=True)
    # PencilKit's replica preferences require a real main-bundle identifier.
    (contents / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "org.nomad.tests.mac-tools." + uuid.uuid4().hex,
        "CFBundleExecutable": binary.name, "CFBundlePackageType": "APPL", "LSUIElement": True,
    }))
    sources = ["App/Collections/CollectionStorageDirectory.swift", "App/Collections/CollectionStorage.swift",
               "App/Collections/SketchMacCanvas.swift", "App/Vault/VaultClipboard.swift", "Tests/MacToolsRegression/main.swift"]
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-module-cache-path", "/tmp/nomad-mac-tools-cache",
                    *[str(root / name) for name in sources], "-o", str(binary)], check=True, timeout=180)
    subprocess.run([str(binary)], check=True, timeout=60)
