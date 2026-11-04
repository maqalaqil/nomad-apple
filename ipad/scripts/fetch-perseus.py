#!/usr/bin/env python3
"""Build the pinned, completely local Perseus renderer and retain its notices."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "scripts/fetch-perseus"
OUTPUT = ROOT / "Resources/WebTools/Perseus"
PINS = json.loads((OUTPUT / "release.json").read_text())


def sha(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def hashes():
    return {str(path.relative_to(OUTPUT)): sha(path) for path in sorted(OUTPUT.rglob("*"))
            if path.is_file() and path.name not in {"nomad-installation.json", ".gitignore", "README.md"}}


def adapter_hashes():
    names = ["build.mjs", "main.jsx", "package-notices.mjs", "shims.js", "style.css", "package.json"]
    result = {name: sha(SOURCE / name) for name in names}
    result["../fetch-perseus.py"] = sha(Path(__file__).resolve())
    return result


def obtain(pin, directory, offline):
    if Path(pin["file"]).name != pin["file"]:
        raise SystemExit("Unsafe pinned filename")
    path = directory / pin["file"]
    if path.exists() and sha(path) == pin["sha256"]:
        return path
    if path.exists():
        raise SystemExit(f"Pinned input was changed: {path}; refusing to overwrite it.")
    if offline:
        raise SystemExit(f"Missing or changed pinned input: {path}")
    directory.mkdir(parents=True, exist_ok=True)
    print(f"Fetching {pin['file']}…", flush=True)
    request = urllib.request.Request(pin["url"], headers={"User-Agent": "NomadPad-offline-builder/1"})
    with urllib.request.urlopen(request, timeout=60) as response:
        data = response.read(32 * 1024 * 1024 + 1)
    if len(data) > 32 * 1024 * 1024 or hashlib.sha256(data).hexdigest() != pin["sha256"]:
        raise SystemExit(f"SHA-256 mismatch or oversized input: {pin['file']}; refusing installation.")
    path.write_bytes(data)
    return path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--offline", action="store_true", help="Require all pinned files and npm packages to be cached")
    parser.add_argument("--npm-cache", type=Path, help="Optional npm cache directory")
    parser.add_argument("--verify", action="store_true", help="Verify the existing generated files and lockfile without building")
    args = parser.parse_args()
    if args.verify:
        manifest = json.loads((OUTPUT / "nomad-installation.json").read_text())
        if (manifest["files"] != hashes() or manifest["pins"] != PINS
                or manifest["package_lock_sha256"] != sha(SOURCE / "package-lock.json")
                or manifest.get("adapter_sha256") != adapter_hashes()):
            raise SystemExit("Perseus differs from its installation manifest; rebuild it.")
        print(f"Verified {len(manifest['files'])} local Perseus files.")
        return
    for pin in PINS["integration_sources"]:
        obtain(pin, SOURCE / "upstream", args.offline)
    for pin in PINS["static_assets"]:
        obtain(pin, SOURCE / "static", args.offline)
    for pin in PINS["source_archives"]:
        path = obtain(pin, SOURCE / "third-party", args.offline)
        # Read only the exact, pinned notice; never extract arbitrary archive paths.
        with tarfile.open(path) as archive:
            member = archive.getmember(pin["license_path"])
            if not member.isfile() or member.size > 256 * 1024:
                raise SystemExit("Invalid source archive license entry")
            (SOURCE / "third-party/MathQuill-MPL-2.0.txt").write_bytes(archive.extractfile(member).read())
    command = ["npm", "ci", "--ignore-scripts", "--no-audit", "--no-fund"]
    if args.offline:
        command.append("--offline")
    if args.npm_cache:
        command.extend(["--cache", str(args.npm_cache.resolve())])
    subprocess.run(command, cwd=SOURCE, check=True)
    subprocess.run(["node", "build.mjs"], cwd=SOURCE, check=True)
    (OUTPUT / "nomad-installation.json").write_text(json.dumps({
        "pins": PINS, "package_lock_sha256": sha(SOURCE / "package-lock.json"),
        "adapter_sha256": adapter_hashes(), "files": hashes(),
    }, indent=2) + "\n")
    print(f"Bundled {len(hashes())} local Perseus files; exercise packages are imported separately.")


if __name__ == "__main__":
    main()
