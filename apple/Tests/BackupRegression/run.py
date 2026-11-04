"""Compile the production backup engine and run isolated native failure tests."""
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[3]
sources = sorted((repo / "apple/App/Backup").glob("*.swift"))
sources = [path for path in sources if path.name != "BackupView.swift"]
sources.append(repo / "apple/App/Collections/InventoryModels.swift")
sources.append(repo / "apple/App/Collections/CollectionStorageDirectory.swift")
sources.append(repo / "apple/App/Library/ReadingMarkStore.swift")
sources += [repo / "apple/Sources/NomadCore" / name for name in ["NotesStore.swift", "LocalStorage.swift", "LibraryModels.swift"]]
with tempfile.TemporaryDirectory(prefix="nomad-backup-build-") as temporary:
    root = Path(temporary)
    binary = root / "regression"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
                    "-warn-concurrency", "-module-cache-path", str(root / "ModuleCache"),
                    *map(str, sources), str(Path(__file__).with_name("main.swift")), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
