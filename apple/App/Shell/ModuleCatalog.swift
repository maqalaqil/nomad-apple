import SwiftUI

enum NomadModule: String, CaseIterable, Identifiable {
    case home, library, assistant, knowledge, models, education, maps, reference, translation
    case notes, tools, itTools, pdf, files, books, inventory, vault, media, sketch, whiteboard, mesh, downloads, setup, benchmarks, depot, settings

    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: "Command Center"
        case .library: "Knowledge Library"
        case .assistant: "AI Assistant"
        case .models: "Local AI Models"
        case .knowledge: "Knowledge Collections"
        case .education: "Education"
        case .maps: "Offline Maps"
        case .reference: "Drug Reference"
        case .translation: "Translation"
        case .notes: "Notes"
        case .tools: "Data Tools"
        case .itTools: "IT Tools"
        case .pdf: "PDF Workshop"
        case .files: "Files"
        case .books: "Books"
        case .inventory: "Inventory"
        case .vault: "Password Vault"
        case .media: "Media Library"
        case .sketch: "Sketchbook"
        case .whiteboard: "Whiteboard"
        case .mesh: "Mesh Radios"
        case .depot: "Supply Depot"
        case .downloads: "Downloads"
        case .setup: "Offline Preparation"
        case .benchmarks: "Benchmarks"
        case .settings: "Device & Storage"
        }
    }
    var symbol: String {
        switch self {
        case .home: "square.grid.2x2.fill"
        case .library: "books.vertical.fill"
        case .assistant: "sparkles"
        case .models: "cpu"
        case .knowledge: "square.stack.3d.down.right.fill"
        case .education: "graduationcap.fill"
        case .maps: "map.fill"
        case .reference: "cross.case.fill"
        case .translation: "character.bubble.fill"
        case .notes: "note.text"
        case .tools: "wrench.and.screwdriver.fill"
        case .itTools: "terminal.fill"
        case .pdf: "doc.richtext.fill"
        case .files: "folder.fill"
        case .books: "book.closed.fill"
        case .inventory: "shippingbox.fill"
        case .vault: "lock.shield.fill"
        case .media: "play.rectangle.fill"
        case .sketch: "pencil.and.outline"
        case .whiteboard: "rectangle.and.pencil.and.ellipsis"
        case .mesh: "antenna.radiowaves.left.and.right"
        case .depot: "square.stack.3d.up.fill"
        case .downloads: "arrow.down.circle.fill"
        case .setup: "checklist"
        case .benchmarks: "gauge.with.dots.needle.50percent"
        case .settings: "internaldrive.fill"
        }
    }
    var summary: String {
        switch self {
        case .home: "Your knowledge, wherever you go."
        case .library: "Import, search, and read your local documents."
        case .assistant: "Ask about indexed documents with Apple Intelligence when its model is ready."
        case .models: "Import GGUF models and run private conversations on this device."
        case .knowledge: "Choose sources and build a local semantic search index."
        case .education: "Keep courses, lessons, and your progress together."
        case .maps: "Keep places and reference maps available offline."
        case .reference: "Drug labels and reference datasets."
        case .translation: "Translate text with downloaded language models."
        case .notes: "Capture ideas and keep them on your device."
        case .tools: "Encode, format, hash, and transform text."
        case .itTools: "Open the bundled collection of local developer utilities."
        case .pdf: "Read, edit, OCR, redact, and export local PDFs."
        case .files: "Organize folders and copy, move, import, or share local files."
        case .books: "Keep your reading collection close at hand."
        case .inventory: "Track supplies, stock levels, receipts, and warranties."
        case .vault: "Keep credentials protected on this device."
        case .media: "Import and play your own video and audio."
        case .sketch: "Draw, save, and export your ideas."
        case .whiteboard: "Create diagrams with the offline Excalidraw editor."
        case .mesh: "Radio integration is not available in this build."
        case .depot: "Explore modules and their preparation requirements."
        case .downloads: "Prepare archives, models, and other content before going offline."
        case .setup: "Choose content and check it before disconnecting."
        case .benchmarks: "Measure local CPU and storage workloads on this device."
        case .settings: "Inspect storage and offline readiness."
        }
    }
    var group: String {
        switch self {
        case .home: "Workspace"
        case .library, .assistant, .knowledge, .models, .education, .maps, .reference, .translation: "Knowledge"
        case .notes, .tools, .itTools, .pdf, .files, .books, .sketch, .whiteboard: "Create & organize"
        case .inventory, .vault, .media, .mesh: "Everyday essentials"
        case .downloads, .setup, .benchmarks, .depot, .settings: "Manage"
        }
    }
    var needsIntegration: Bool { self == .mesh }
}

enum NomadTheme {
    static let background = Color(red: 0.055, green: 0.085, blue: 0.075)
    static let panel = Color(red: 0.095, green: 0.135, blue: 0.115)
    static let accent = Color(red: 0.78, green: 0.92, blue: 0.48)
    static let muted = Color(red: 0.55, green: 0.66, blue: 0.59)
}
