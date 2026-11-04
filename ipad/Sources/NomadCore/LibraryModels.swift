import Foundation

public enum DocumentKind: String, Codable, CaseIterable, Sendable {
    case text, markdown, pdf, zim, epub, model, image, audio, video, other

    public var label: String {
        switch self {
        case .text: "Text"
        case .markdown: "Markdown"
        case .pdf: "PDF"
        case .zim: "ZIM archive"
        case .epub: "EPUB"
        case .model: "AI model"
        case .image: "Image"
        case .audio: "Audio"
        case .video: "Video"
        case .other: "File"
        }
    }

    public var canSearchContents: Bool { self == .text || self == .markdown || self == .pdf }

    public static func detect(filename: String) -> Self {
        switch (filename as NSString).pathExtension.lowercased() {
        case "txt", "log", "csv", "json": .text
        case "md", "markdown": .markdown
        case "pdf": .pdf
        case "zim": .zim
        case "epub": .epub
        case "gguf", "safetensors": .model
        case "jpg", "jpeg", "png", "heic", "gif", "webp": .image
        case "mp3", "m4a", "wav", "aac", "flac": .audio
        case "mp4", "m4v", "mov", "webm": .video
        default: .other
        }
    }
}

public struct LibraryDocument: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    /// An internal basename, never an absolute or relative path supplied by an archive.
    public let filename: String
    public let kind: DocumentKind
    public let byteCount: Int64
    public let importedAt: Date
    public let indexingStatus: String

    public init(id: UUID, title: String, filename: String, kind: DocumentKind,
                byteCount: Int64, importedAt: Date, indexingStatus: String = "") {
        self.id = id
        self.title = title
        self.filename = filename
        self.kind = kind
        self.byteCount = byteCount
        self.importedAt = importedAt
        self.indexingStatus = indexingStatus
    }
}

public struct SearchHit: Identifiable, Equatable, Sendable {
    public let id: String
    public let documentID: UUID
    public let documentTitle: String
    public let excerpt: String
    public let score: Double
    public let hasSourceText: Bool

    public init(id: String, documentID: UUID, documentTitle: String, excerpt: String, score: Double, hasSourceText: Bool = true) {
        self.id = id
        self.documentID = documentID
        self.documentTitle = documentTitle
        self.excerpt = excerpt
        self.score = score
        self.hasSourceText = hasSourceText
    }
}

public enum LocalStorageError: LocalizedError {
    case invalidManifest(String)
    case unavailable(String)
    case invalidFile
    case missingDocument
    case emptyNote

    public var errorDescription: String? {
        switch self {
        case .invalidManifest(let detail): "The local library metadata could not be read safely. \(detail) Your stored files have not been changed."
        case .unavailable(let detail): "Local storage is unavailable. \(detail)"
        case .invalidFile: "Choose a regular file to import. Folders and symbolic links are not supported."
        case .missingDocument: "This document is no longer in the library."
        case .emptyNote: "Add a title or some text before saving the note."
        }
    }
}

struct LibraryRecord: Codable, Sendable {
    let document: LibraryDocument
    let searchableText: String
}
