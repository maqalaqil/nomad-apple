#!/usr/bin/env python3
"""Run native CryptoKit/CommonCrypto recovery tests with synthetic data only."""
from pathlib import Path
import subprocess
import tempfile

vault = Path(__file__).resolve().parent.parent
source = (vault / "VaultView.swift").read_text()
begin = source.index("\n", source.index("// BEGIN VAULT_UNLOCK_GATE")) + 1
end = source.index("// END VAULT_UNLOCK_GATE", begin)
with tempfile.TemporaryDirectory(prefix="nomad-vault-tests-") as directory:
    root = Path(directory)
    gate = root / "VaultUnlockGate.swift"
    gate.write_text("import Foundation\n" + source[begin:end])
    binary = root / "vault-tests"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-D", "NOMAD_VAULT_TESTS",
                    "-module-cache-path", str(Path(tempfile.gettempdir()) / "nomad-vault-test-cache"),
                    str(vault / "VaultCrypto.swift"), str(gate),
                    str(vault / "Tests/VaultCryptoTests.swift"), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
