#!/usr/bin/env python3
"""Fetch the pinned NOMAD map assets and build the local PMTiles renderer."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "Resources/WebTools/Maps"
SOURCE = ROOT / "scripts/fetch-map-assets"
PIN = json.loads((OUTPUT / "assets-release.json").read_text())

def sha(path):
    return hashlib.file_digest(path.open("rb"), "sha256").hexdigest()

def hashes():
    return {str(p.relative_to(OUTPUT)): sha(p) for p in sorted(OUTPUT.rglob("*")) if p.is_file() and p.name not in {"nomad-installation.json", ".gitignore"}}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, help="Existing verified base-assets.tar.gz")
    parser.add_argument("--npm-offline", action="store_true")
    parser.add_argument("--verify", action="store_true")
    args = parser.parse_args()
    if args.verify:
        manifest = json.loads((OUTPUT / "nomad-installation.json").read_text())
        if manifest["files"] != hashes():
            raise SystemExit("Map assets differ from their installation manifest; rebuild them.")
        print(f"Verified {len(manifest['files'])} bundled map files.")
        return
    with tempfile.TemporaryDirectory(prefix="nomad-map-assets-") as temporary:
        archive = args.archive or Path(temporary) / "base-assets.tar.gz"
        if not args.archive:
            print("Downloading pinned NOMAD fonts, sprites, and map style…")
            urllib.request.urlretrieve(PIN["archive_url"], archive)
        if sha(archive) != PIN["archive_sha256"]:
            raise SystemExit("Map assets SHA-256 mismatch; refusing installation.")
        with tarfile.open(archive) as tar:
            for member in tar:
                parts = Path(member.name).parts
                if not parts or parts[0] != "tozip" or ".." in parts or member.issym() or member.islnk():
                    raise SystemExit(f"Unsafe map archive entry: {member.name}")
                destination = OUTPUT.joinpath(*parts[1:])
                if member.isdir():
                    destination.mkdir(parents=True, exist_ok=True)
                elif member.isfile():
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    with tar.extractfile(member) as source, destination.open("wb") as target:
                        shutil.copyfileobj(source, target)
                else:
                    raise SystemExit(f"Unexpected map archive entry: {member.name}")
    command = ["npm", "ci", "--ignore-scripts", "--no-audit", "--no-fund"]
    if args.npm_offline:
        command.append("--offline")
    subprocess.run(command, cwd=SOURCE, check=True)
    subprocess.run(["node", "build.mjs"], cwd=SOURCE, check=True)
    (OUTPUT / "nomad-installation.json").write_text(json.dumps({"pins": PIN, "package_lock_sha256": sha(SOURCE / "package-lock.json"), "files": hashes()}, indent=2) + "\n")
    print(f"Bundled {len(hashes())} local map assets. Map archives are imported separately on the iPad.")

if __name__ == "__main__":
    main()
