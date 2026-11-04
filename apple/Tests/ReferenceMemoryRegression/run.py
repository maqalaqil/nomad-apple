"""Compile the real Reference importer and measure a 50,000-label synthetic import."""
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[3]
sources = [repo / "apple/App/Collections/CollectionStorageDirectory.swift"]
sources += [repo / "apple/App/Reference" / name for name in
            ["DrugReferenceDatabase.swift", "DrugConditionCatalog.swift", "DrugSituationSelection.swift"]]
sources.append(Path(__file__).with_name("main.swift"))
with tempfile.TemporaryDirectory(prefix="nomad-reference-memory-build-") as temporary:
    root = Path(temporary)
    binary = root / "memory"
    subprocess.run(["xcrun", "swiftc", "-O", "-parse-as-library", "-swift-version", "5", "-warn-concurrency",
                    "-module-cache-path", str(root / "ModuleCache"), *map(str, sources), "-lsqlite3", "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=180)
