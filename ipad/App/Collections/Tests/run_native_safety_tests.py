#!/usr/bin/env python3
"""Exercise the actual Foundation engines without loading iPad-only UI frameworks.

Only marked declarations are extracted verbatim. Fixtures and binaries live in
a disposable temporary directory; no app data or user-selected files are read.
"""
from pathlib import Path
import subprocess
import tempfile

app = Path(__file__).resolve().parents[2]


def marked(path, label):
    source = path.read_text()
    begin = source.index("\n", source.index("// BEGIN " + label)) + 1
    end = source.index("// END " + label, begin)
    return source[begin:end]


with tempfile.TemporaryDirectory(prefix="nomad-native-safety-") as directory:
    folder = Path(directory)
    source = folder / "main.swift"
    source.write_text(
        "import Foundation\nimport SQLite3\nimport ImageIO\nimport Darwin\n"
        + (app / "Collections/LocalManifestFile.swift").read_text()
        + marked(app / "Vault/VaultView.swift", "VAULT_UNLOCK_GATE")
        + marked(app / "Maps/OfflinePlacesView.swift", "RASTER_DATABASE")
        + (Path(__file__).with_name("NativeSafetyEngineTests.swift")).read_text()
    )
    binary = folder / "native-safety-tests"
    subprocess.run([
        "swiftc", "-parse-as-library", "-swift-version", "5", "-D", "NOMAD_NATIVE_SAFETY_TESTS",
        "-module-cache-path", str(Path(tempfile.gettempdir()) / "nomad-native-safety-module-cache"), str(source),
        "-o", str(binary), "-lsqlite3",
    ], check=True)
    subprocess.run([str(binary)], check=True)
