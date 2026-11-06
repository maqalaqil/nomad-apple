#!/usr/bin/env python3
"""Download and verify the exact native dependency source inventory; execute nothing."""
import argparse
import hashlib
import json
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=Path, default=ROOT.parent / "artifacts/open-source")
parser.add_argument("--verify", action="store_true", help="check existing archives without network access")
args = parser.parse_args()
manifest = json.loads((ROOT / "native-source-manifest.json").read_text())
args.output.mkdir(parents=True, exist_ok=True)
for item in manifest["archives"]:
    destination = args.output / item["filename"]
    if not destination.exists() and not args.verify:
        temporary = destination.with_suffix(destination.suffix + ".partial")
        try:
            request = urllib.request.Request(item["url"], headers={"User-Agent": "NOMAD-Apple-source-fetch"})
            with urllib.request.urlopen(request, timeout=120) as response, temporary.open("wb") as output:
                while chunk := response.read(1024 * 1024):
                    output.write(chunk)
            if hashlib.sha256(temporary.read_bytes()).hexdigest() != item["sha256"]:
                raise SystemExit("Checksum mismatch: " + item["filename"])
            temporary.replace(destination)
        finally:
            temporary.unlink(missing_ok=True)
    if not destination.exists() or hashlib.sha256(destination.read_bytes()).hexdigest() != item["sha256"]:
        raise SystemExit("Missing or invalid source: " + item["filename"])
    print("Verified " + item["filename"])
