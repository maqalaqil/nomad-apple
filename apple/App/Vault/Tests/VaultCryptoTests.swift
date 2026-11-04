#if NOMAD_VAULT_TESTS
import Foundation
import CryptoKit
import CommonCrypto

@main struct VaultCryptoTests {
    static var assertions = 0
    static func check(_ value: Bool, _ label: String) {
        precondition(value, label); assertions += 1
    }
    static func rejects(_ label: String, _ operation: () throws -> Void) {
        do { try operation(); fatalError("Accepted \(label)") } catch { assertions += 1 }
    }
    static func main() async throws {
        let passphrase = "lantern café river orbit marble 937!"
        let original = VaultEntry(title: "Synthetic test credential", username: "example-test-user", password: "TEST-SECRET-NEVER-REAL", website: "https://example.invalid", notes: "Offline recovery fixture")
        let cipher = try VaultBackupCodec.encrypt([original], passphrase: passphrase)
        let decoded = try VaultBackupCodec.decrypt(cipher, passphrase: passphrase)
        check(decoded == [original], "authenticated round trip")
        check(cipher.range(of: Data(original.password.utf8)) == nil, "no plaintext password in backup")
        let cipher2 = try VaultBackupCodec.encrypt([original], passphrase: passphrase)
        check(cipher != cipher2, "fresh salt/nonce")
        check(cipher.subdata(in: 12..<44) != cipher2.subdata(in: 12..<44), "fresh salt")
        check(cipher.subdata(in: 44..<56) != cipher2.subdata(in: 44..<56), "fresh nonce")
        let normalized = try VaultBackupCodec.decrypt(cipher, passphrase: passphrase.decomposedStringWithCanonicalMapping)
        check(normalized == [original], "NFC passphrase normalization")
        rejects("wrong passphrase") { _ = try VaultBackupCodec.decrypt(cipher, passphrase: "a completely different strong test passphrase") }
        for index in [12, 44, 58, cipher.count - 1] {
            var changed = cipher; changed[index] ^= 1
            rejects("tampered salt/nonce/ciphertext/tag") { _ = try VaultBackupCodec.decrypt(changed, passphrase: passphrase) }
        }
        var changedRounds = cipher; changedRounds[8] ^= 1
        rejects("unsupported KDF parameters") { _ = try VaultBackupCodec.decrypt(changedRounds, passphrase: passphrase) }
        rejects("truncation") { _ = try VaultBackupCodec.decrypt(cipher.prefix(40), passphrase: passphrase) }
        rejects("oversized data") { _ = try VaultBackupCodec.decrypt(Data(count: VaultBackupCodec.maximumFileBytes + 1), passphrase: passphrase) }
        rejects("short passphrase") { try VaultBackupCodec.validatePassphrase("too short") }
        rejects("only spaces") { try VaultBackupCodec.validatePassphrase(String(repeating: " ", count: 30)) }
        rejects("oversized passphrase") { try VaultBackupCodec.validatePassphrase(String(repeating: "a", count: 1_025)) }
        rejects("duplicate IDs on export") { _ = try VaultBackupCodec.encrypt([original, original], passphrase: passphrase) }
        let duplicateCipher = try forgedValidEnvelope(entries: [original, original], passphrase: passphrase)
        rejects("authenticated duplicate IDs on import") { _ = try VaultBackupCodec.decrypt(duplicateCipher, passphrase: passphrase) }
        var oversized = original; oversized.notes = String(repeating: "n", count: 65_537)
        let largeFieldCipher = try forgedValidEnvelope(entries: [oversized], passphrase: passphrase)
        rejects("authenticated oversized field") { _ = try VaultBackupCodec.decrypt(largeFieldCipher, passphrase: passphrase) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nomad-vault-test-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("backup.nomadvault")
        try cipher.write(to: file)
        check(try VaultBackupCodec.readEncryptedFile(file) == cipher, "bounded file reading")
        let link = folder.appendingPathComponent("linked.nomadvault")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        rejects("symbolic-link backup") { _ = try VaultBackupCodec.readEncryptedFile(link) }
        try Data(count: VaultBackupCodec.maximumFileBytes + 1).write(to: file)
        rejects("oversized file") { _ = try VaultBackupCodec.readEncryptedFile(file) }
        var escaped = original; escaped.notes = String(repeating: "\u{1}", count: 65_536)
        let escapedEntries = (0..<12).map { _ -> VaultEntry in var entry = escaped; entry.id = UUID(); return entry }
        rejects("oversized JSON-escaped vault before Keychain write") { try VaultBackupCodec.validateExportable(escapedEntries) }
        var oldCopy = original; oldCopy.password = "obsolete fixture password"
        let addition = VaultEntry(title: "New fixture", password: "another fake secret")
        let merge = try VaultBackupCodec.merge(existing: [original], imported: [oldCopy, addition])
        check(merge.added == 1 && merge.kept == 1, "merge counts")
        check(merge.entries == [original, addition], "existing ID retains current password")
        var persisted = [original], writes = 0
        // This is the recovery transaction boundary: a writer receives only a
        // fully authenticated, validated, reviewed merge, never partial decode.
        for invalid in [duplicateCipher, Data(count: 1), Data(count: VaultBackupCodec.maximumFileBytes + 1)] {
            do {
                let imported = try VaultBackupCodec.decrypt(invalid, passphrase: passphrase)
                let plan = try VaultBackupCodec.merge(existing: persisted, imported: imported)
                writes += 1; persisted = plan.entries
            } catch {}
        }
        check(writes == 0 && persisted == [original], "failed import preserves writer state")
        var options = VaultPasswordOptions()
        var passwords = Set<String>()
        for _ in 0..<200 {
            let password = try options.generate()
            check(password.count == 24 && options.groups.allSatisfy { group in password.contains(where: group.contains) }, "password meets selected groups")
            check(password.allSatisfy { !Set("Il1O0o").contains($0) }, "ambiguous exclusion")
            passwords.insert(password)
        }
        check(passwords.count == 200, "independent generated samples")
        options.uppercase = false; options.lowercase = false; options.symbols = false; options.length = 32
        check(try options.generate().allSatisfy(\.isNumber), "digits only")
        options.digits = false
        rejects("empty alphabet") { _ = try options.generate() }
        var gate = VaultUnlockGate(); let operation = gate.begin(); gate.invalidate()
        check(!gate.accepts(operation), "lock rejects late crypto completion")
        let second = gate.begin(); let third = gate.begin()
        check(!gate.accepts(second) && gate.accepts(third), "new operation invalidates prior completion")
        let cancelled = Task.detached { () throws -> Data in
            try await Task.sleep(for: .milliseconds(50))
            return try VaultBackupCodec.encrypt([original], passphrase: passphrase)
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; fatalError("Cancelled encryption completed") } catch { assertions += 1 }
        print("PASS vault crypto/generator/lifecycle: \(assertions) assertions")
    }

    // Independent envelope fixture writer bypasses production entry validation
    // so import validation is tested after real authenticated decryption.
    private static func forgedValidEnvelope(entries: [VaultEntry], passphrase: String) throws -> Data {
        struct Payload: Encodable { let version = 1; let createdAt = Date(); let entries: [VaultEntry] }
        let salt = Data(repeating: 0x42, count: 32)
        let rounds: UInt32 = 600_000
        let header = Data("NMVLTBK1".utf8) + Data([0, 9, 39, 192]) + salt
        let password = Array(passphrase.precomposedStringWithCanonicalMapping.utf8)
        var key = [UInt8](repeating: 0, count: 32)
        let status = password.withUnsafeBytes { bytes in salt.withUnsafeBytes { saltBytes in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), bytes.baseAddress!.assumingMemoryBound(to: CChar.self), bytes.count,
                saltBytes.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, &key, key.count)
        } }
        precondition(status == 0)
        return header + (try AES.GCM.seal(JSONEncoder().encode(Payload(entries: entries)), using: SymmetricKey(data: key), authenticating: header).combined!)
    }
}
#endif
