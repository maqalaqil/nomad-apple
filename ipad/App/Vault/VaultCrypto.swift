import Foundation
import Security
import CryptoKit
import CommonCrypto

struct VaultEntry: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var title = ""
    var username = ""
    var password = ""
    var website = ""
    var notes = ""
}

enum VaultFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

enum VaultRandom {
    static func bytes(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw VaultFailure.message("The system could not generate secure random bytes.") }
        return data
    }

    static func index(below upperBound: Int) throws -> Int {
        guard upperBound > 0, upperBound <= 256 else { throw VaultFailure.message("Invalid password alphabet.") }
        let limit = 256 - 256 % upperBound
        while true {
            let byte = Int(try bytes(count: 1)[0])
            if byte < limit { return byte % upperBound }
        }
    }
}

struct VaultPasswordOptions: Sendable {
    var length = 24
    var uppercase = true
    var lowercase = true
    var digits = true
    var symbols = true
    var excludeAmbiguous = true

    var groups: [[Character]] {
        let excluded = Set("Il1O0o")
        return [(uppercase, "ABCDEFGHIJKLMNOPQRSTUVWXYZ"), (lowercase, "abcdefghijklmnopqrstuvwxyz"),
                (digits, "0123456789"), (symbols, "!#$%&()*+,-./:;<=>?@[]^_{|}~")]
            .filter(\.0).map { Array($0.1).filter { !excludeAmbiguous || !excluded.contains($0) } }
    }

    func generate() throws -> String {
        let groups = groups, alphabet = groups.flatMap { $0 }
        guard (8...128).contains(length), !alphabet.isEmpty else { throw VaultFailure.message("Choose at least one character group and a length from 8 to 128.") }
        // Rejection sampling is uniform over the alphabet and over passwords that
        // contain every selected group. No modulo bias or predictable PRNG is used.
        for _ in 0..<1_024 {
            let candidate = try (0..<length).map { _ in alphabet[try VaultRandom.index(below: alphabet.count)] }
            if groups.allSatisfy({ group in candidate.contains(where: group.contains) }) { return String(candidate) }
        }
        throw VaultFailure.message("Could not generate a password meeting these options. Try again.")
    }
}

enum VaultBackupCodec {
    static let maximumFileBytes = 4 * 1_024 * 1_024
    static let maximumEntries = 5_000
    static let rounds: UInt32 = 600_000
    private static let magic = Data("NMVLTBK1".utf8)
    private static let saltBytes = 32
    private static let headerBytes = 8 + 4 + saltBytes
    private struct Payload: Codable { let version: Int; let createdAt: Date; let entries: [VaultEntry] }

    static func validatePassphrase(_ passphrase: String) throws {
        let normalized = passphrase.precomposedStringWithCanonicalMapping
        guard normalized.count >= 20, normalized.utf8.count <= 1_024,
              normalized.trimmingCharacters(in: .whitespacesAndNewlines).count >= 20 else {
            throw VaultFailure.message("Use a backup passphrase of at least 20 characters (up to 1,024 UTF-8 bytes). Prefer several randomly chosen words. Spaces alone do not count.")
        }
    }

    static func validateEntries(_ entries: [VaultEntry]) throws {
        guard entries.count <= maximumEntries else { throw VaultFailure.message("This backup exceeds the 5,000-credential limit.") }
        guard Set(entries.map(\.id)).count == entries.count else { throw VaultFailure.message("This backup contains duplicate credential IDs and cannot be imported.") }
        var totalTextBytes = 0
        for entry in entries {
            guard [entry.title, entry.username, entry.password, entry.website].allSatisfy({ $0.utf8.count <= 16_384 }), entry.notes.utf8.count <= 65_536 else {
                throw VaultFailure.message("A credential exceeds the supported field size.")
            }
            totalTextBytes += [entry.title, entry.username, entry.password, entry.website, entry.notes].reduce(0) { $0 + $1.utf8.count }
            guard totalTextBytes <= maximumFileBytes else { throw VaultFailure.message("The vault exceeds the supported backup size. Reduce large notes before saving.") }
        }
    }

    static func validateExportable(_ entries: [VaultEntry]) throws {
        try validateEntries(entries)
        var plaintext = try JSONEncoder().encode(Payload(version: 1, createdAt: Date(), entries: entries))
        defer { plaintext.resetBytes(in: plaintext.startIndex..<plaintext.endIndex) }
        guard plaintext.count <= maximumFileBytes - headerBytes - 28 else { throw VaultFailure.message("The vault exceeds the 4 MB encrypted backup limit. Reduce large notes before saving.") }
    }

    static func encrypt(_ entries: [VaultEntry], passphrase: String) throws -> Data {
        try Task.checkCancellation()
        try validatePassphrase(passphrase)
        try validateEntries(entries)
        var plaintext = try JSONEncoder().encode(Payload(version: 1, createdAt: Date(), entries: entries))
        defer { plaintext.resetBytes(in: plaintext.startIndex..<plaintext.endIndex) }
        guard plaintext.count <= maximumFileBytes - headerBytes - 28 else { throw VaultFailure.message("The encrypted backup would exceed 4 MB. Reduce large notes before exporting.") }
        let salt = try VaultRandom.bytes(count: saltBytes)
        let header = magic + Data([UInt8((rounds >> 24) & 255), UInt8((rounds >> 16) & 255), UInt8((rounds >> 8) & 255), UInt8(rounds & 255)]) + salt
        let key = try deriveKey(passphrase: passphrase, salt: salt)
        try Task.checkCancellation()
        let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: header)
        guard let combined = sealed.combined else { throw VaultFailure.message("Could not encode the encrypted backup.") }
        return header + combined
    }

    static func decrypt(_ file: Data, passphrase: String) throws -> [VaultEntry] {
        try Task.checkCancellation()
        guard file.count >= headerBytes + 28, file.count <= maximumFileBytes else { throw VaultFailure.message("Choose a complete NOMAD encrypted vault backup no larger than 4 MB.") }
        let file = Data(file) // Rebase any Data slice before fixed-offset parsing.
        guard file.prefix(8) == magic else { throw VaultFailure.message("This is not a supported NOMAD encrypted vault backup (version 1).") }
        let encodedRounds = file[8..<12].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard encodedRounds == rounds else { throw VaultFailure.message("This backup uses unsupported key-derivation parameters.") }
        try validatePassphrase(passphrase)
        let salt = file.subdata(in: 12..<headerBytes)
        let key = try deriveKey(passphrase: passphrase, salt: salt)
        try Task.checkCancellation()
        var plaintext: Data
        do {
            let sealed = try AES.GCM.SealedBox(combined: file.subdata(in: headerBytes..<file.count))
            plaintext = try AES.GCM.open(sealed, using: key, authenticating: file.prefix(headerBytes))
        } catch { throw VaultFailure.message("The passphrase is incorrect or this backup is damaged. Nothing was imported.") }
        defer { plaintext.resetBytes(in: plaintext.startIndex..<plaintext.endIndex) }
        let payload: Payload
        do { payload = try JSONDecoder().decode(Payload.self, from: plaintext) }
        catch { throw VaultFailure.message("The authenticated backup contains invalid credential data. Nothing was imported.") }
        guard payload.version == 1 else { throw VaultFailure.message("Unsupported credential payload version.") }
        try validateEntries(payload.entries)
        try Task.checkCancellation()
        return payload.entries
    }

    static func readEncryptedFile(_ url: URL) throws -> Data {
        var coordinationError: NSError?
        var outcome: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { coordinated in
            outcome = Result {
                let metadata = try coordinated.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard metadata.isRegularFile == true, metadata.isSymbolicLink != true, let size = metadata.fileSize, size >= headerBytes + 28, size <= maximumFileBytes else {
                    throw VaultFailure.message("Choose a regular encrypted vault backup no larger than 4 MB.")
                }
                let handle = try FileHandle(forReadingFrom: coordinated)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: maximumFileBytes + 1) ?? Data()
                guard data.count <= maximumFileBytes else { throw VaultFailure.message("This backup exceeds 4 MB.") }
                return data
            }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else { throw VaultFailure.message("Files could not provide this backup for reading.") }
        return try outcome.get()
    }

    static func merge(existing: [VaultEntry], imported: [VaultEntry]) throws -> (entries: [VaultEntry], added: Int, kept: Int) {
        try validateEntries(existing); try validateEntries(imported)
        let ids = Set(existing.map(\.id))
        let additions = imported.filter { !ids.contains($0.id) }
        let merged = existing + additions
        try validateExportable(merged)
        return (merged, additions.count, imported.count - additions.count)
    }

    private static func deriveKey(passphrase: String, salt: Data) throws -> SymmetricKey {
        var passwordBytes = Array(passphrase.precomposedStringWithCanonicalMapping.utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        defer {
            _ = passwordBytes.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
            _ = derived.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
        }
        let result = passwordBytes.withUnsafeBytes { password in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password.baseAddress!.assumingMemoryBound(to: CChar.self), password.count,
                    saltBytes.baseAddress!.assumingMemoryBound(to: UInt8.self), saltBytes.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, &derived, derived.count)
            }
        }
        guard result == kCCSuccess else { throw VaultFailure.message("Backup key derivation failed.") }
        return SymmetricKey(data: derived)
    }
}
