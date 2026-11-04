#!/usr/bin/env python3
"""Run production EPUB archive/resource/desktop-position code in native macOS WebKit."""
from pathlib import Path
import subprocess
import tempfile
import zipfile

here = Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix="nomad-epub-desktop-") as temporary:
    folder = Path(temporary)
    archive = folder / "synthetic.epub"
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as output:
        output.writestr("mimetype", "application/epub+zip", compress_type=zipfile.ZIP_STORED)
        output.writestr("META-INF/container.xml", '<container><rootfiles><rootfile full-path="book.opf"/></rootfiles></container>')
        output.writestr("book.opf", '<package version="3.0"><metadata><title>Temporary desktop regression</title></metadata><manifest><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="chapter"/></spine></package>')
        output.writestr("chapter.xhtml", '<html><head><title>Test</title><script>window.bookScriptRan=true;</script></head><body>' + ''.join(f'<p>Temporary test-only paragraph {i} with offline text.</p>' for i in range(300)) + '<p>UNIQUE OFFLINE BOOKMARK</p></body></html>')
    binary = folder / "desktop-epub-tests"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-D", "NOMAD_EPUB_DESKTOP_TESTS", "-module-cache-path", "/tmp/nomad-epub-desktop-module-cache",
                    *[str(here / f"{name}.swift") for name in ["EPUBArchive", "EPUBSchemeHandler", "EPUBDesktopPosition", "EPUBDesktopRegression"]],
                    "-framework", "AppKit", "-framework", "WebKit", "-lz", "-o", str(binary)], check=True, timeout=180)
    subprocess.run([str(binary), str(archive)], check=True, timeout=45)
