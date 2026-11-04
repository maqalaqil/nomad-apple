import SwiftUI
import CryptoKit
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct ToolTextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText, .json] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let value = String(data: data, encoding: .utf8) else {
            throw ToolFailure.message("This file is not valid UTF-8 text.")
        }
        text = value
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

enum ToolFailure: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case let .message(message) = self { return message }
        return nil
    }
}

enum ToolOperation: String, CaseIterable, Identifiable {
    case base64Encode = "Base64 encode"
    case base64Decode = "Base64 decode"
    case urlEncode = "URL component encode"
    case urlDecode = "URL component decode"
    case jsonFormat = "Format JSON"
    case jsonCompact = "Compact JSON"
    case hexEncode = "Hex encode"
    case hexDecode = "Hex decode"
    case sha256 = "SHA-256"
    case sha512 = "SHA-512"
    case uuid = "Generate UUID"
    var id: String { rawValue }

    func process(_ input: String) throws -> String {
        switch self {
        case .base64Encode: return Data(input.utf8).base64EncodedString()
        case .base64Decode:
            guard let data = Data(base64Encoded: input.filter { !$0.isWhitespace }),
                  let text = String(data: data, encoding: .utf8) else {
                throw ToolFailure.message("Enter valid Base64 that decodes to UTF-8 text. Binary output is not supported by this text tool.")
            }
            return text
        case .urlEncode:
            let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
            guard let result = input.addingPercentEncoding(withAllowedCharacters: allowed) else {
                throw ToolFailure.message("The input could not be encoded.")
            }
            return result
        case .urlDecode:
            guard let result = input.removingPercentEncoding else {
                throw ToolFailure.message("The input has an invalid percent escape or is not valid UTF-8.")
            }
            return result
        case .jsonFormat, .jsonCompact:
            _ = try JSONSerialization.jsonObject(with: Data(input.utf8), options: [.fragmentsAllowed])
            return ToolFormatJSON(input, pretty: self == .jsonFormat)
        case .hexEncode: return Data(input.utf8).map { String(format: "%02x", $0) }.joined()
        case .hexDecode:
            let bytes = Array(input.filter { !$0.isWhitespace }.utf8)
            guard bytes.count.isMultiple(of: 2) else { throw ToolFailure.message("Hex must contain an even number of digits.") }
            var data = Data()
            for index in stride(from: 0, to: bytes.count, by: 2) {
                guard let byte = UInt8(String(decoding: bytes[index...index + 1], as: UTF8.self), radix: 16) else {
                    throw ToolFailure.message("Hex accepts digits 0–9 and letters A–F only.")
                }
                data.append(byte)
            }
            guard let result = String(data: data, encoding: .utf8) else { throw ToolFailure.message("Decoded bytes are not valid UTF-8 text.") }
            return result
        case .sha256: return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
        case .sha512: return SHA512.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
        case .uuid: return UUID().uuidString.lowercased()
        }
    }
}

struct ToolsView: View {
    @State private var operation: ToolOperation = .base64Encode
    @State private var input = ""
    @State private var output = ""
    @State private var error: String?
    @State private var notice = ""
    @State private var importing = false
    @State private var exporting = false

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    CyberChefView()
                } label: {
                    Label("Open complete CyberChef", systemImage: "wrench.and.screwdriver")
                }
                NavigationLink {
                    ITToolsView()
                } label: {
                    Label("Open complete IT Tools", systemImage: "terminal")
                }
                Text("The complete bundled CyberChef and IT Tools catalogs run in offline workspaces. Quick native text tools are below.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Label("Text utilities run entirely on this device.", systemImage: "wifi.slash")
                    .foregroundStyle(.secondary)
                Picker("Operation", selection: $operation) {
                    ForEach(ToolOperation.allCases) { Text($0.rawValue).tag($0) }
                }
                if operation == .urlDecode {
                    Text("Decodes percent escapes in a URL component. A + remains a +; form-urlencoded decoding is a different format.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if operation == .sha256 || operation == .sha512 {
                    Text("Hashes the exact UTF-8 text, including spaces and line breaks. Hashes are not encryption.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if operation != .uuid {
                Section("Input · \(input.utf8.count.formatted()) UTF-8 bytes") {
                    TextEditor(text: $input)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .frame(minHeight: 180)
                        .accessibilityLabel("Input text")
                    HStack {
                        Button("Import text", systemImage: "square.and.arrow.down") { importing = true }
                        Spacer()
                        Button("Clear", role: .destructive) { input = ""; output = ""; notice = "" }
                    }.buttonStyle(.borderless)
                }
            }
            Section {
                Button(operation == .uuid ? "Generate UUID" : "Run \(operation.rawValue)", systemImage: "play.fill") { run() }
                    .buttonStyle(.borderedProminent)
                if !notice.isEmpty { Text(notice).font(.caption).foregroundStyle(.secondary) }
            }
            if !output.isEmpty {
                Section("Output · \(output.utf8.count.formatted()) UTF-8 bytes") {
                    Text(output).font(.system(.body, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    ViewThatFits {
                        HStack { outputActions }
                        VStack(alignment: .leading, spacing: 12) { outputActions }
                    }
                }
            }
            Section {
                Text("These native shortcuts complement the bundled CyberChef and IT Tools workspaces. Work here is temporary until exported.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Offline tools")
        .fileImporter(isPresented: $importing, allowedContentTypes: [.text, .json]) { result in
            do { input = try ToolReadText(result.get()); output = ""; notice = "Imported text." }
            catch { self.error = error.localizedDescription }
        }
        .fileExporter(isPresented: $exporting, document: ToolTextDocument(text: output), contentType: .plainText, defaultFilename: "nomad-\(operation.id.lowercased().replacingOccurrences(of: " ", with: "-"))") { result in
            switch result {
            case .success: notice = "Output exported."
            case .failure(let failure): error = failure.localizedDescription
            }
        }
        .alert("Could not complete the operation", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    @ViewBuilder private var outputActions: some View {
        Button("Copy", systemImage: "doc.on.doc") { NomadClipboard.copy(output); notice = "Copied output." }
            .buttonStyle(.borderless)
        Button("Export", systemImage: "square.and.arrow.up") { exporting = true }
            .buttonStyle(.borderless)
        Button("Use as input", systemImage: "arrow.uturn.up") { input = output; output = ""; notice = "Output moved to input." }
            .buttonStyle(.borderless)
    }

    private func run() {
        do {
            guard input.utf8.count <= 4 * 1_024 * 1_024 else { throw ToolFailure.message("Use text smaller than 4 MB for this interactive tool.") }
            output = try operation.process(input)
            notice = output.isEmpty ? "Done. The result is empty." : "Completed locally."
        } catch { output = ""; self.error = error.localizedDescription }
    }
}

/// Changes only whitespace outside string literals, preserving numeric precision and key order.
private func ToolFormatJSON(_ input: String, pretty: Bool) -> String {
    var tokens: [Character] = []
    var inString = false
    var escaped = false
    for character in input {
        if inString {
            tokens.append(character)
            if escaped { escaped = false }
            else if character == "\\" { escaped = true }
            else if character == "\"" { inString = false }
        } else if character == "\"" {
            inString = true; tokens.append(character)
        } else if !character.isWhitespace { tokens.append(character) }
    }
    guard pretty else { return String(tokens) }
    var result = ""
    var depth = 0
    inString = false; escaped = false
    func newline(_ depth: Int) -> String { "\n" + String(repeating: "  ", count: max(0, depth)) }
    for (index, character) in tokens.enumerated() {
        if inString {
            result.append(character)
            if escaped { escaped = false }
            else if character == "\\" { escaped = true }
            else if character == "\"" { inString = false }
            continue
        }
        switch character {
        case "\"": inString = true; result.append(character)
        case "{", "[":
            result.append(character); depth += 1
            if index + 1 < tokens.count && tokens[index + 1] != "}" && tokens[index + 1] != "]" { result += newline(depth) }
        case "}", "]":
            depth -= 1
            if index > 0 && tokens[index - 1] != "{" && tokens[index - 1] != "[" { result += newline(depth) }
            result.append(character)
        case ",": result.append(character); result += newline(depth)
        case ":": result += ": "
        default: result.append(character)
        }
    }
    return result
}

func ToolReadText(_ url: URL) throws -> String {
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size <= 4 * 1_024 * 1_024 else { throw ToolFailure.message("Choose a UTF-8 text file smaller than 4 MB.") }
    let data = try Data(contentsOf: url)
    guard data.count <= 4 * 1_024 * 1_024, let text = String(data: data, encoding: .utf8) else {
        throw ToolFailure.message("Choose a UTF-8 text file smaller than 4 MB.")
    }
    return text
}
