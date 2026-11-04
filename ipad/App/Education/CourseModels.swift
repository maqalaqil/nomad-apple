import Foundation

enum CourseError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

struct CourseResource: Codable, Identifiable {
    let checksum: String
    let fileExtension: String
    let preset: String
    let thumbnail: Bool
    let supplementary: Bool
    let byteCount: Int64
    var available: Bool
    var id: String { checksum + "." + fileExtension + ":" + preset }
    var filename: String { checksum + "." + fileExtension }
    var relativePath: String { "storage/\(checksum.prefix(1))/\(checksum.dropFirst().prefix(1))/\(filename)" }
}

struct CourseNode: Codable, Identifiable {
    let id: String
    let contentID: String
    let parentID: String?
    let title: String
    let summary: String
    let kind: String
    let author: String
    let licenseName: String
    let licenseOwner: String
    let licenseDescription: String
    let order: Double
    let assessmentCount: Int
    var resources: [CourseResource]
    var assessment: CourseAssessment?
    var languageCode: String?
    var primaryResource: CourseResource? { resources.first { !$0.thumbnail && !$0.supplementary && $0.available } }
    var supportMessage: String? {
        if kind == "topic" { return nil }
        guard let resource = primaryResource else { return "The exported folder does not include this resource’s content file." }
        if resource.fileExtension == "perseus" {
            guard let assessment, !assessment.itemIDs.isEmpty else { return "This exercise has no readable assessment-item catalog in its channel metadata." }
            return CoursePaths.perseusBundle == nil ? "The official Perseus renderer has not been bundled in this build." : nil
        }
        if ["perseus", "h5p", "bloompub", "bloomd"].contains(resource.fileExtension) || kind == "exercise" {
            return "This resource requires a Perseus, H5P, QTI, or Bloom renderer. Its original package is preserved; this app does not grade or approximate these exercises."
        }
        if ["pdf", "mp4", "m4v", "mov", "mp3", "m4a", "wav", "html5", "zip"].contains(resource.fileExtension) { return nil }
        return "The \(resource.fileExtension) renderer is not integrated yet. The original resource is preserved in the imported channel."
    }
}

struct CourseAssessment: Codable {
    let itemIDs: [String]
    let masteryModelJSON: String
    let randomize: Bool
}

struct InstalledCourse: Codable, Identifiable {
    let id: UUID
    let channelID: String
    let name: String
    let summary: String
    let author: String
    let version: Int
    let schemaVersion: String
    let rootID: String
    let importedAt: Date
    let resourceCount: Int
    let copiedFileCount: Int
    let missingFileCount: Int
    let byteCount: Int64
    var folder: String { id.uuidString }
}

struct CoursePackage: Codable {
    let formatVersion: Int
    let course: InstalledCourse
    let nodes: [CourseNode]
}

struct StagedCourse: Identifiable {
    var id: UUID { course.id }
    let course: InstalledCourse
    let directory: URL
}

struct CourseLearner: Codable, Identifiable { let id: UUID; var name: String }

struct CourseProgress: Codable, Identifiable {
    let learnerID: UUID
    let contentID: String
    var completed = false
    var updatedAt = Date()
    var scormValues: [String: String] = [:]
    var id: String { learnerID.uuidString + ":" + contentID }
}

struct CourseAttempt: Codable, Identifiable {
    let id: UUID
    let learnerID: UUID
    let contentID: String
    let startedAt: Date
    var updatedAt: Date
    var reportedStatus: String?
    var reportedScore: String?
}

struct CourseExerciseState: Codable, Identifiable {
    let learnerID: UUID
    let contentID: String
    let itemID: String
    let answerStateJSON: String
    let hintsVisible: Int
    let updatedAt: Date
    var id: String { learnerID.uuidString + ":" + contentID + ":" + itemID }
}

struct CourseExerciseAttempt: Codable, Identifiable {
    let id: UUID
    let learnerID: UUID
    let contentID: String
    let itemID: String
    let recordedAt: Date
    let scoreType: String
    let earned: Double?
    let total: Double?
    let message: String?
    let hintsVisible: Int
}

struct CourseState: Codable {
    var formatVersion = 1
    var courses: [InstalledCourse] = []
    var learners: [CourseLearner] = []
    var progress: [CourseProgress] = []
    var attempts: [CourseAttempt] = []
    var exerciseStates: [CourseExerciseState]?
    var exerciseAttempts: [CourseExerciseAttempt]?
}

enum CoursePaths {
    static var root: URL { URL.applicationSupportDirectory.appending(path: "NomadPad/Courses") }
    static func validID(_ text: String) -> Bool {
        text.count == 32 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func validExtension(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 16 && text.utf8.allSatisfy { (48...57).contains($0) || (97...122).contains($0) }
    }
    static func validItemID(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= 128 && text != "." && text != ".." &&
        !text.contains("/") && !text.contains("\\") && !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
    static var perseusBundle: URL? {
        guard let root = Bundle.main.resourceURL else { return nil }
        return [root.appendingPathComponent("WebTools/Perseus"), root.appendingPathComponent("Resources/WebTools/Perseus")]
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("index.html").path) }
    }
    static func regularFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard url.isFileURL, values.isRegularFile == true, values.isSymbolicLink != true else {
            throw CourseError.invalid("A course file is a folder or symbolic link. The import was stopped.")
        }
    }
}
