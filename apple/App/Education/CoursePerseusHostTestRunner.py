#!/usr/bin/env python3
"""Exercise the production native scheme/CSP/bridge using a local official fixture.

Build the pinned renderer first. No network requests or package installs occur here.
"""
from pathlib import Path
import subprocess
import tempfile
import zipfile

ipad = Path(__file__).resolve().parents[2]
bundle = ipad / "Resources/WebTools/Perseus"
fixture = ipad / "scripts/fetch-perseus/upstream/sorter-item.json"
if not (bundle / "index.html").exists() or not fixture.exists():
    raise SystemExit("Build scripts/fetch-perseus before running the native host smoke test.")
with tempfile.TemporaryDirectory(prefix="nomad-perseus-host-") as temporary:
    folder = Path(temporary)
    archive = folder / "test.perseus"
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as output:
        output.write(fixture, "test-item.json")
    sources = [ipad / "App/Education" / (name + ".swift") for name in ["CourseModels", "CourseZipArchive", "CoursePerseusMessage", "CoursePerseusView", "CoursePerseusHostTests"]]
    binary = folder / "host-tests"
    subprocess.run(["swiftc", "-swift-version", "5", "-D", "NOMAD_PERSEUS_HOST_TESTS", "-module-cache-path", str(Path(tempfile.gettempdir()) / "nomad-course-module-cache"), *map(str, sources), "-framework", "AppKit", "-framework", "WebKit", "-lz", "-o", str(binary)], check=True)
    subprocess.run([str(binary), str(bundle), str(archive)], check=True, timeout=90)
