#!/usr/bin/env python3
"""Install the checksum-pinned, complete upstream CyberChef distribution for bundling.

Uses only the Python standard library. All download requests happen at build time.
Use --archive and --license-file for a completely offline install from cached files.
"""
import argparse
import hashlib
import json
import pathlib
import shutil
import stat
import tempfile
import urllib.request
import zipfile


ROOT = pathlib.Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "Resources" / "WebTools"
MANIFEST_PATH = RESOURCES / "cyberchef-release.json"


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def fetch(url, destination):
    request = urllib.request.Request(url, headers={"User-Agent": "NomadPad-build-assets/1"})
    with urllib.request.urlopen(request, timeout=180) as response, destination.open("wb") as stream:
        shutil.copyfileobj(response, stream)


def verify(path, expected):
    actual = digest(path)
    if actual != expected:
        raise ValueError(f"Checksum mismatch for {path.name}: expected {expected}, got {actual}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=pathlib.Path, help="Previously downloaded official ZIP")
    parser.add_argument("--license-file", type=pathlib.Path, help="Previously downloaded upstream LICENSE")
    parser.add_argument("--verify", action="store_true", help="Verify every installed file without downloading")
    arguments = parser.parse_args()
    manifest = json.loads(MANIFEST_PATH.read_text())
    destination = RESOURCES / "CyberChef"
    if arguments.verify:
        installed = json.loads((destination / "nomad-installation.json").read_text())
        if installed["archive_sha256"] != manifest["archive_sha256"]:
            raise ValueError("Installed release does not match the pinned manifest")
        for name, expected in installed["files"].items():
            verify(destination / name, expected)
        print(f"Verified {len(installed['files'])} local CyberChef files ({manifest['version']}).")
        return
    RESOURCES.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".CyberChef-", dir=RESOURCES) as temporary:
        temporary = pathlib.Path(temporary)
        archive = arguments.archive or temporary / "release.zip"
        license_file = arguments.license_file or temporary / "LICENSE"
        if not arguments.archive:
            print(f"Downloading {manifest['version']} ({manifest['archive_bytes']:,} bytes)…", flush=True)
            fetch(manifest["archive_url"], archive)
        if not arguments.license_file:
            fetch(manifest["license_url"], license_file)
        verify(archive, manifest["archive_sha256"])
        verify(license_file, manifest["license_sha256"])
        if archive.stat().st_size != manifest["archive_bytes"]:
            raise ValueError("Release archive length differs from pinned manifest")
        staging = temporary / "CyberChef"
        staging.mkdir()
        with zipfile.ZipFile(archive) as source:
            for member in source.infolist():
                relative = pathlib.PurePosixPath(member.filename)
                if relative.is_absolute() or ".." in relative.parts or stat.S_ISLNK(member.external_attr >> 16):
                    raise ValueError(f"Unsafe ZIP member: {member.filename}")
            source.extractall(staging)
        # Keep every upstream asset and entry point. The wrapper uses a stable alias.
        html = (staging / manifest["entry_point"]).read_text()
        # Network-capable operations stay visible but cannot contact remote hosts.
        policy = (
            "default-src 'self' file: blob: data:; "
            "script-src 'self' file: 'unsafe-inline' 'unsafe-eval' blob:; "
            "style-src 'self' file: 'unsafe-inline'; img-src 'self' file: data: blob:; "
            "font-src 'self' file: data:; connect-src 'self' file: data: blob:; "
            "worker-src 'self' file: blob:; child-src 'self' file: blob:; "
            "object-src 'none'; form-action 'none'; base-uri 'self'"
        )
        meta = f'<meta http-equiv="Content-Security-Policy" content="{policy}">'
        if "<head>" not in html:
            raise ValueError("Unexpected upstream HTML: no head element")
        (staging / "index.html").write_text(html.replace("<head>", "<head>" + meta, 1))
        shutil.copyfile(license_file, staging / "LICENSE")
        files = {str(path.relative_to(staging)): digest(path) for path in sorted(staging.rglob("*")) if path.is_file()}
        installed = dict(manifest, files=files, local_changes=["index.html alias with offline Content Security Policy; upstream files unchanged"])
        (staging / "nomad-installation.json").write_text(json.dumps(installed, indent=2) + "\n")
        # Preserve the previous installation until the complete new staging tree is ready.
        previous = temporary / "previous"
        if destination.exists():
            destination.rename(previous)
        try:
            staging.rename(destination)
        except Exception:
            if previous.exists():
                previous.rename(destination)
            raise
    print(f"Installed complete CyberChef {manifest['version']} ({len(files)} files) in {destination}")


if __name__ == "__main__":
    main()
