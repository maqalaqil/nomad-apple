#!/usr/bin/env python3
"""Read-only local release checks. Does not upload or establish Store clearance."""
from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
import re
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def command(*args):
    result = subprocess.run([str(a) for a in args], capture_output=True, timeout=180)
    require(result.returncode == 0, f"{args[0]} failed: {result.stderr.decode(errors='replace')}")
    return result.stdout


def plist(path):
    return plistlib.loads(path.read_bytes())


def product_errors(value):
    errors = []
    if isinstance(value, dict):
        for key, child in value.items():
            if key == "product-errors" and child:
                errors.append(child)
            errors.extend(product_errors(child))
    elif isinstance(value, list):
        for child in value:
            errors.extend(product_errors(child))
    return errors


def uuids(path):
    result = command("dwarfdump", "--uuid", path).decode()
    pairs = re.findall(r"UUID: ([\w-]+) \(([^)]+)\)", result)
    require(bool(pairs), f"Missing dSYM UUIDs: {path.name}")
    return sorted(pairs)


def boolean_entitlements(app):
    raw = command("codesign", "-d", "--entitlements", "-", app)
    if raw.startswith((b"<?xml", b"bplist")):
        return plistlib.loads(raw)
    # Current codesign prints its DER-backed abstract representation by default.
    # --xml may have no representation for a DER-only signature.
    text = raw.decode()
    require(text.startswith("[Dict]"), "Unrecognized entitlement representation")
    return {key: value == "true" for key, value in re.findall(
        r"^\t\[Key\] (.+)\n\t\[Value\]\n\t\t\[Bool\] (true|false)$", text, re.M)}


def verify_app(app, platform, version, build, bundle_id, distribution=False):
    content = app / "Contents" if platform == "macOS" else app
    resources = content / "Resources" if platform == "macOS" else app
    info = plist(content / "Info.plist")
    require((info["CFBundleShortVersionString"], info["CFBundleVersion"], info["CFBundleIdentifier"])
            == (version, build, bundle_id), f"Unexpected {platform} app identity")
    require((resources / "Assets.car").is_file(), "Missing compiled icons/assets")
    if platform == "iOS":
        require(info["UIDeviceFamily"] == [1, 2], "Expected both iPhone and iPad")
    command("codesign", "--verify", "--deep", "--strict", app)
    entitlements = boolean_entitlements(app)
    if platform == "macOS":
        require(entitlements.get("com.apple.security.app-sandbox") is True, "Mac sandbox is missing")
        executable = content / "MacOS" / info["CFBundleExecutable"]
        require(set(command("lipo", "-archs", executable).decode().split()) == {"arm64", "x86_64"},
                "Expected universal native Mac executable")
    if distribution:
        require(not entitlements.get("get-task-allow", False), "Distribution app allows debugging")
        require(not entitlements.get("com.apple.security.get-task-allow", False), "Mac app allows debugging")
    for folder in ("SampleLibrary", "ThirdPartyLicenses", "Catalogs"):
        source = ROOT / "apple/Resources" / folder
        require(any(source.iterdir()), f"Empty {folder} source")
        for file in source.rglob("*"):
            if file.is_file():
                require(sha256(file) == sha256(resources / folder / file.relative_to(source)),
                        f"Bundled {folder}/{file.name} differs")
    require(sha256(resources / "PRIVACY_POLICY.md") == sha256(ROOT / "docs/PRIVACY_POLICY.md"),
            "Bundled privacy policy differs")
    require(sha256(resources / "PrivacyInfo.xcprivacy") == sha256(ROOT / "apple/App/Platform/PrivacyInfo.xcprivacy"),
            "Bundled privacy manifest differs")
    manifests = []
    for file in sorted(app.rglob("PrivacyInfo.xcprivacy")):
        data = plist(file)
        manifests.append({"file": str(file.relative_to(app)), "declarations": data})
    require(bool(manifests), "Missing privacy manifest")
    bundles = {}
    for name in ("CyberChef", "ITTools", "Excalidraw", "Maps", "Perseus"):
        source = ROOT / "apple/Resources/WebTools" / name
        installed = resources / "WebTools" / name
        manifest = source / "nomad-installation.json"
        require(sha256(manifest) == sha256(installed / manifest.name), f"{name} inventory differs")
        files = json.loads(manifest.read_text())["files"]
        require(bool(files), f"Empty {name} inventory")
        for relative, digest in files.items():
            target = installed / relative
            require(target.resolve().is_relative_to(installed.resolve()), "Unsafe inventory path")
            require(sha256(target) == digest, f"{name}/{relative} hash mismatch")
        bundles[name] = len(files)
    require(not (resources / "WebTools/ITTools/nomad-build-integration.py").exists(),
            "Superseded loose IT Tools build script found")
    return {"signature": "deep/strict passed", "web_resource_files_verified": bundles,
            "samples_notices_catalogs_policy": "matched source", "privacy_manifest_inventory": manifests}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", default="1.0")
    parser.add_argument("--build", default="10")
    parser.add_argument("--bundle-id", default="org.projectnomad.ipad.native")
    parser.add_argument("--artifacts", type=Path, default=ROOT / "artifacts")
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    store = args.artifacts / "app-store"
    report = {"version": args.version, "build": args.build,
              "scope": "Local artifact integrity only; no upload, Apple validation, privacy label or licensing clearance",
              "platforms": [], "passed": False}
    try:
        checksums = json.loads((store / f"export-verification-{args.version}-{args.build}.json").read_text())
        require({x["platform"] for x in checksums} == {"iOS", "macOS"} and len(checksums) == 2,
                "Expected one checksum record per platform")
        for platform, extension in (("iOS", "ipa"), ("macOS", "pkg")):
            archive = args.artifacts / f"NomadApple-{platform}-{args.version}-{args.build}.xcarchive"
            app = archive / "Products/Applications/NomadApple.app"
            entry = {"platform": platform, "archive": verify_app(app, platform, args.version, args.build, args.bundle_id)}
            framework = app / ("Contents/Frameworks" if platform == "macOS" else "Frameworks") / "llama.framework/llama"
            require(uuids(framework) == uuids(archive / "dSYMs/llama.dSYM"), "llama dSYM mismatch")
            entry["llama_dsym_uuids"] = uuids(framework)
            export = store / f"{platform}-{args.version}-{args.build}-verified"
            package = export / f"NomadApple.{extension}"
            record = next(x for x in checksums if x["platform"] == platform)
            digest = sha256(package)
            require(digest == record["sha256"] and package.stat().st_size == record["bytes"], "Export checksum mismatch")
            analysis = plist(export / "AppStoreInfo.plist")
            require(bool(analysis.get("product-metadata")) and bool(analysis.get("app-info")), "Empty export analysis")
            require(not product_errors(analysis), "Export analysis contains product errors")
            entry["export_sha256"] = digest
            with tempfile.TemporaryDirectory(prefix="nomad-release-check-") as temporary:
                unpacked = Path(temporary) / "unpacked"
                if platform == "iOS":
                    command("ditto", "-x", "-k", package, unpacked)
                else:
                    command("pkgutil", "--check-signature", package)
                    command("pkgutil", "--expand-full", package, unpacked)
                apps = list(unpacked.rglob("NomadApple.app"))
                require(len(apps) == 1, f"Expected one app in {platform} package")
                entry["export"] = verify_app(apps[0], platform, args.version, args.build, args.bundle_id, True)
            report["platforms"].append(entry)
            print(f"PASS: {platform} archive and exported package", flush=True)
        screenshots = json.loads((ROOT / "docs/APP_STORE_SCREENSHOTS.json").read_text())
        require(screenshots["version"] == args.version
                and args.build in screenshots.get("applicable_builds", [screenshots["build"]]),
                "Screenshot release mismatch")
        report["screenshot_capture_build"] = screenshots["build"]
        counts = {}
        for item in screenshots["screenshots"]:
            screenshot = store / "screenshots" / item["file"]
            require(sha256(screenshot) == item["sha256"], f"Screenshot hash mismatch: {item['file']}")
            dimensions = command("sips", "-g", "pixelWidth", "-g", "pixelHeight", screenshot).decode()
            require(re.search(r"pixelWidth: (\d+)", dimensions)[1] == str(item["width"])
                    and re.search(r"pixelHeight: (\d+)", dimensions)[1] == str(item["height"]), "Screenshot dimensions differ")
            platform = Path(item["file"]).parts[0]
            counts[platform] = counts.get(platform, 0) + 1
        require(counts == {"ipad": 7, "iphone": 7, "mac": 7}, f"Unexpected screenshot counts: {counts}")
        report["screenshots_verified"] = counts
        report["passed"] = True
        print("PASS: 21 screenshot hashes and dimensions; local artifact checks only")
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        report["error"] = str(error)
        raise
    finally:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
