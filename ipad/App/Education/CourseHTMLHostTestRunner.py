#!/usr/bin/env python3
"""Compile the actual HTML5 coordinator on macOS and check its WebKit lifecycle.

Only the UIViewRepresentable wrapper is omitted. Coordinator code is read directly
from CourseHTMLView.swift; this harness does not maintain a replacement host.
"""
from pathlib import Path
import subprocess
import tempfile
import textwrap
import zipfile

ipad = Path(__file__).resolve().parents[2]
education = ipad / "App/Education"
original = (education / "CourseHTMLView.swift").read_text()
start = original.index("    @MainActor final class Coordinator:")
end = original.rindex("\n}")
coordinator = textwrap.dedent(original[start:end]).replace("final class Coordinator:", "final class CourseHTMLTestCoordinator:", 1)
with tempfile.TemporaryDirectory(prefix="nomad-html-host-") as temporary:
    folder = Path(temporary)
    extracted = folder / "ActualHTMLCoordinator.swift"
    extracted.write_text("import Foundation\nimport WebKit\nimport UniformTypeIdentifiers\n" + coordinator)
    archive = folder / "test.html5"
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as output:
        output.writestr("index.html", """<!doctype html><title>TEST-ONLY HTML5</title><script>
        window.API.LMSInitialize('');
        fetch('data.json').then(r=>r.json()).then(value=>{
          window.API.LMSSetValue('cmi.core.score.raw',String(value.score));
          window.API.LMSCommit('');
        });
        </script><p>TEST-ONLY package</p>""")
        output.writestr("data.json", '{"score":8}')
        output.writestr("large.txt", "TEST-ONLY" * (128 * 1024))
    sources = [ipad / "App/Collections/LocalManifestFile.swift", extracted] + [education / (name + ".swift") for name in ["CourseModels", "CourseZipArchive", "CourseChannelImport", "CourseStore", "CourseHTMLHostTests"]]
    binary = folder / "html-host-tests"
    subprocess.run(["swiftc", "-swift-version", "5", "-D", "NOMAD_HTML_HOST_TESTS", "-module-cache-path", str(Path(tempfile.gettempdir()) / "nomad-course-module-cache"), *map(str, sources), "-framework", "AppKit", "-framework", "WebKit", "-lsqlite3", "-lz", "-o", str(binary)], check=True)
    subprocess.run([str(binary), str(archive)], check=True, timeout=60)
