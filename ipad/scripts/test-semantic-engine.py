#!/usr/bin/env python3
"""Compile and test the actual local embedding engine with temporary fixtures."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
sources = sorted((root / "Sources/NomadCore").glob("*.swift"))
sources += [root / "App/Collections/LocalManifestFile.swift",
            root / "App/Assistant/SemanticIndex.swift",
            root / "App/Assistant/Tests/SemanticEngineTests.swift"]
with tempfile.TemporaryDirectory(prefix="nomad-semantic-tests-") as directory:
    executable = Path(directory) / "semantic-tests"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
                    "-D", "NOMAD_SEMANTIC_ENGINE_TESTS", "-o", str(executable),
                    *map(str, sources)], check=True)
    subprocess.run([str(executable)], check=True)
