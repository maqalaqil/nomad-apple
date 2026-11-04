#!/usr/bin/env python3
"""Compile and test the same Foundation/PDFKit/CoreGraphics/Vision engine used on iPad."""
from pathlib import Path
import subprocess
import tempfile

ipad = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="nomad-pdf-tests-") as temporary:
    executable = Path(temporary) / "pdf-workshop-tests"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
                    "-module-cache-path", "/tmp/nomad-pdf-module-cache",
                    str(ipad / "App/Tools/PDFWorkshopEngine.swift"),
                    str(Path(__file__).with_name("main.swift")), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
