#!/usr/bin/env python3
"""Reproduce complete IT Tools and Excalidraw offline bundles (build-time network only)."""
import argparse
import hashlib
import json
import pathlib
import shutil
import stat
import subprocess
import tempfile
import urllib.request
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "Resources" / "WebTools"
BUILD = ROOT / "scripts" / "fetch-web-editors"


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def acquire(url, path, expected, cached=None):
    if cached:
        shutil.copyfile(cached, path)
    else:
        request = urllib.request.Request(url, headers={"User-Agent": "NomadPad-build-assets/1"})
        with urllib.request.urlopen(request, timeout=180) as response, path.open("wb") as stream:
            shutil.copyfileobj(response, stream)
    if digest(path) != expected:
        raise ValueError(f"Checksum mismatch for {path.name}; no assets installed")


def verify(directory):
    installed = json.loads((directory / "nomad-installation.json").read_text())
    for name, expected in installed["files"].items():
        if digest(directory / name) != expected:
            raise ValueError(f"Installed file changed: {directory.name}/{name}")
    if directory.name == "Excalidraw" and digest(BUILD / "package-lock.json") != installed["package_lock_sha256"]:
        raise ValueError("Excalidraw package lock changed since build")
    print(f"Verified {directory.name}: {len(installed['files'])} files")


def install_it_tools(arguments):
    manifest = json.loads((RESOURCES / "it-tools-release.json").read_text())
    with tempfile.TemporaryDirectory(prefix=".WebEditors-", dir=RESOURCES) as temporary:
        temporary = pathlib.Path(temporary)
        archive, source, license_file = temporary / "release.zip", temporary / "source.tar.gz", temporary / "LICENSE"
        acquire(manifest["archive_url"], archive, manifest["archive_sha256"], arguments.it_tools_archive)
        acquire(manifest["source_url"], source, manifest["source_sha256"], arguments.it_tools_source)
        acquire(manifest["license_url"], license_file, manifest["license_sha256"], arguments.it_tools_license)
        with zipfile.ZipFile(archive) as package:
            for member in package.infolist():
                path = pathlib.PurePosixPath(member.filename)
                if path.is_absolute() or ".." in path.parts or stat.S_ISLNK(member.external_attr >> 16):
                    raise ValueError(f"Unsafe archive member: {member.filename}")
            package.extractall(temporary)
        staging = temporary / "dist"
        entry = staging / "index.html"
        html = entry.read_text()
        (staging / "index.upstream.html").write_text(html)
        policy = "default-src 'self' nomad-local: blob: data:; script-src 'self' nomad-local: 'unsafe-inline' 'unsafe-eval' blob:; style-src 'self' nomad-local: 'unsafe-inline'; img-src 'self' nomad-local: data: blob:; font-src 'self' nomad-local: data:; connect-src 'self' nomad-local: data: blob:; worker-src 'self' nomad-local: blob:; object-src 'none'; form-action 'none'; base-uri 'self'"
        if "<head>" not in html:
            raise ValueError("Unexpected IT Tools entry point")
        entry.write_text(html.replace("<head>", f'<head><meta http-equiv="Content-Security-Policy" content="{policy}">', 1))
        shutil.copyfile(source, staging / "it-tools-source.tar.gz")
        shutil.copyfile(license_file, staging / "LICENSE")
        shutil.copyfile(pathlib.Path(__file__), staging / "nomad-build-integration.py")
        (staging / "NOMAD-INTEGRATION.txt").write_text(
            "IT Tools upstream source is included in it-tools-source.tar.gz. The upstream release files are preserved, except index.html has an offline CSP; index.upstream.html is the original. nomad-build-integration.py documents the transformation. The native WebKit wrapper serves these files at a local custom origin to support existing absolute asset URLs and SPA routes. No upstream JavaScript has been removed or replaced.\n"
        )
        files = {str(path.relative_to(staging)): digest(path) for path in sorted(staging.rglob("*")) if path.is_file()}
        (staging / "nomad-installation.json").write_text(json.dumps(dict(manifest, files=files), indent=2) + "\n")
        destination = RESOURCES / "ITTools"
        previous = temporary / "previous"
        if destination.exists(): destination.rename(previous)
        try: staging.rename(destination)
        except Exception:
            if previous.exists(): previous.rename(destination)
            raise
    print(f"Installed complete IT Tools {manifest['version']}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify", action="store_true")
    parser.add_argument("--skip-it-tools", action="store_true")
    parser.add_argument("--skip-excalidraw", action="store_true")
    parser.add_argument("--it-tools-archive", type=pathlib.Path)
    parser.add_argument("--it-tools-source", type=pathlib.Path)
    parser.add_argument("--it-tools-license", type=pathlib.Path)
    parser.add_argument("--npm-offline", action="store_true", help="Use only the npm cache")
    args = parser.parse_args()
    if args.verify:
        if not args.skip_it_tools: verify(RESOURCES / "ITTools")
        if not args.skip_excalidraw: verify(RESOURCES / "Excalidraw")
        return
    if not args.skip_it_tools: install_it_tools(args)
    if not args.skip_excalidraw:
        command = ["npm", "ci", "--ignore-scripts", "--no-audit", "--no-fund", "--cache", str(pathlib.Path(tempfile.gettempdir()) / "nomad-web-editor-npm-cache")]
        if args.npm_offline: command.append("--offline")
        subprocess.run(command, cwd=BUILD, check=True)
        subprocess.run(["npm", "run", "build"], cwd=BUILD, check=True)


if __name__ == "__main__": main()
