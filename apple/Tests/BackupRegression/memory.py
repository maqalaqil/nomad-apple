"""Measure production backup streaming RSS on isolated 512 MiB synthetic fixtures."""
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[3]
sources = [repo / "apple/App/Backup/BackupFileIO.swift",
           repo / "apple/App/Backup/BackupCatalog.swift",
           repo / "apple/App/Collections/CollectionStorageDirectory.swift",
           Path(__file__).with_suffix(".swift")]
with tempfile.TemporaryDirectory(prefix="nomad-backup-memory-build-") as temporary:
    root = Path(temporary)
    binary = root / "memory"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-warn-concurrency",
                    "-module-cache-path", str(root / "ModuleCache"), *map(str, sources), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=180)
