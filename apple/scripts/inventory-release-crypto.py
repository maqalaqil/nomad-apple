#!/usr/bin/env python3
"""Extract review evidence from pinned assets; does not classify export controls."""
import argparse
import hashlib
import json
import re
import tarfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WEB = ROOT / "apple/Resources/WebTools"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inventory():
    main = WEB / "CyberChef/assets/main.js"
    pinned = json.loads((WEB / "CyberChef/nomad-installation.json").read_text())
    if digest(main) != pinned["files"]["assets/main.js"]:
        raise ValueError("CyberChef bundle does not match its pinned installation inventory")
    pairs = set(re.findall(r'"([^"\\]+)":\{"module":"([^"\\]+)"', main.read_text()))
    if len(pairs) != 505:
        raise ValueError("CyberChef catalog changed; review extraction and module coverage")
    modules = ("Ciphers", "Crypto", "PublicKey", "PGP", "Hashing", "Bletchley")
    groups = {module: sorted(name for name, group in pairs if group == module) for module in modules}
    # Related operations outside the main cryptography modules, including archive
    # operations which must be inspected for password/encryption capabilities.
    related = {"Bacon Cipher Decode", "Bacon Cipher Encode", "Fernet Decrypt", "Fernet Encrypt",
               "ROT13", "ROT13 Brute Force", "XOR", "XOR Brute Force", "Zip", "Unzip"}
    groups["Related operations in other modules"] = sorted(name for name, _ in pairs if name in related)
    if len(groups["Related operations in other modules"]) != len(related):
        raise ValueError("Related-operation extraction is incomplete")
    source = WEB / "ITTools/it-tools-source.tar.gz"
    it_pin = json.loads((WEB / "ITTools/nomad-installation.json").read_text())
    if digest(source) != it_pin["source_sha256"]:
        raise ValueError("IT Tools source archive differs from pin")
    with tarfile.open(source) as archive:
        def read(suffix):
            matches = [m for m in archive.getmembers() if m.isfile() and m.name.endswith("/src/tools/" + suffix)]
            if len(matches) != 1:
                raise ValueError(f"Missing or ambiguous source: {suffix}")
            return archive.extractfile(matches[0]).read().decode()
        encryption = read("encryption/encryption.vue")
        algorithms = re.search(r"const algos = \{ ([^}]+) \}", encryption)
        if not algorithms:
            raise ValueError("IT Tools encryption selector changed")
        paths = ["encryption/encryption.vue", "rsa-key-pair-generator/rsa-key-pair-generator.service.ts",
                 "rsa-key-pair-generator/rsa-key-pair-generator.vue", "bcrypt/bcrypt.vue",
                 "hash-text/hash-text.vue", "hmac-generator/hmac-generator.vue"]
        evidence = {p: hashlib.sha256(read(p).encode()).hexdigest() for p in paths}
    vault = ROOT / "apple/App/Vault/VaultCrypto.swift"
    return {
        "scope": "NOMAD Apple 1.0 (9) pinned crypto review inventory; operation names are not export classifications or proof of runtime coverage",
        "native_vault": {"source": str(vault.relative_to(ROOT)), "sha256": digest(vault),
                         "reviewed_implementation": "Apple CryptoKit AES-256-GCM; CommonCrypto PBKDF2-HMAC-SHA256, 600000 iterations, 32-byte salt; Security SecRandomCopyBytes"},
        "cyberchef": {"version": pinned["version"], "main_js_sha256": digest(main),
                      "catalog_operation_count": len(pairs), "review_groups": groups},
        "it_tools": {"version": it_pin["version"], "source_archive_sha256": digest(source),
                     "encryption_selector": [name.strip() for name in algorithms[1].split(",")],
                     "additional_review": ["RSA key generation via node-forge", "bcrypt", "hash and HMAC tools"],
                     "source_file_sha256": evidence},
        "limitations": ["Review browser cryptography in other dependencies and archive/password operations separately.",
                        "No ECCN, CCATS, proprietary-algorithm determination or exemption is asserted.",
                        "Native implementation description must be rereviewed whenever its source hash changes."]}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    data = inventory()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(data, indent=2) + "\n")
    print("Extracted pinned crypto review inventory; classification remains separate")
