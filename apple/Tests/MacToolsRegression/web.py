#!/usr/bin/env python3
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="nomad-mac-web-host-") as temporary:
    binary = Path(temporary) / "WebHost"
    sources = ["App/Platform/PlatformSupport.swift", "App/Tools/CyberChefView.swift", "Tests/MacToolsRegression/web.swift"]
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-module-cache-path", "/tmp/nomad-mac-web-host-cache",
                    *[str(root / name) for name in sources], "-o", str(binary)], check=True, timeout=180)
    subprocess.run([str(binary), str(root / "Resources/WebTools/CyberChef")], check=True, timeout=100)
