import Foundation
import Observation

@MainActor @Observable
final class CourseStore {
    private(set) var state = CourseState()
    private(set) var ready = false
    var error: String?
    let root: URL
    @ObservationIgnored private var manifest: LocalManifestFile

    init(root: URL = CoursePaths.root) {
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
        manifest = LocalManifestFile(url: self.root.appendingPathComponent("learners-and-channels.json"))
        reload()
    }

    func reload() {
        guard !ready else { return }
        do {
            state = try manifest.load(CourseState.self) { state in
                guard state.formatVersion == 1,
                      Set(state.courses.map(\.id)).count == state.courses.count,
                      Set(state.courses.map(\.channelID)).count == state.courses.count,
                      state.courses.allSatisfy({ CoursePaths.validID($0.channelID) && CoursePaths.validID($0.rootID) && $0.version >= 0 }),
                      Set(state.learners.map(\.id)).count == state.learners.count,
                      state.learners.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
                      Set(state.progress.map(\.id)).count == state.progress.count,
                      Set(state.attempts.map(\.id)).count == state.attempts.count else { throw CocoaError(.fileReadCorruptFile) }
                let learners = Set(state.learners.map(\.id))
                guard state.progress.allSatisfy({ learners.contains($0.learnerID) && CoursePaths.validID($0.contentID) &&
                    $0.scormValues.keys.allSatisfy({ Self.scormKeys.contains($0) }) && $0.scormValues.values.allSatisfy({ $0.utf8.count <= 64 * 1_024 }) }),
                      state.attempts.allSatisfy({ learners.contains($0.learnerID) && CoursePaths.validID($0.contentID) }) else { throw CocoaError(.fileReadCorruptFile) }
                let exerciseStates = state.exerciseStates ?? [], exerciseAttempts = state.exerciseAttempts ?? []
                guard Set(exerciseStates.map(\.id)).count == exerciseStates.count, Set(exerciseAttempts.map(\.id)).count == exerciseAttempts.count,
                      exerciseStates.allSatisfy({ learners.contains($0.learnerID) && CoursePaths.validID($0.contentID) && CoursePaths.validItemID($0.itemID) && Self.validAnswerState($0.answerStateJSON) && (0...10_000).contains($0.hintsVisible) }),
                      exerciseAttempts.allSatisfy({ learners.contains($0.learnerID) && CoursePaths.validID($0.contentID) && CoursePaths.validItemID($0.itemID) && (0...10_000).contains($0.hintsVisible) && Self.validScore(type: $0.scoreType, earned: $0.earned, total: $0.total) && ($0.message?.utf8.count ?? 0) <= 64 * 1_024 }) else { throw CocoaError(.fileReadCorruptFile) }
            } ?? CourseState()
            ready = true; error = nil
        } catch { self.error = "Course and learner records could not be read. Changes are disabled and original files are preserved. \(error.localizedDescription)" }
    }

    private func save(_ updated: CourseState) throws {
        guard ready else { throw CourseError.invalid("Reload the saved course records successfully before making changes.") }
        try manifest.save(updated); state = updated
    }
    func directory(for course: InstalledCourse) -> URL { root.appendingPathComponent("Packages/\(course.folder)") }

    func package(for course: InstalledCourse) throws -> CoursePackage {
        guard state.courses.contains(where: { $0.id == course.id && $0.channelID == course.channelID }) else { throw CourseError.invalid("This channel is no longer installed.") }
        return try readPackage(directory: directory(for: course), expected: course)
    }
    private func readPackage(directory: URL, expected: InstalledCourse) throws -> CoursePackage {
        let url = directory.appendingPathComponent("course.json")
        var file = LocalManifestFile(url: url)
        guard let package = try file.load(CoursePackage.self, validate: { package in
            guard package.formatVersion == 1, package.course.id == expected.id, package.course.channelID == expected.channelID,
                  package.nodes.allSatisfy({ CoursePaths.validID($0.id) && CoursePaths.validID($0.contentID) &&
                      $0.resources.allSatisfy({ CoursePaths.validID($0.checksum) && CoursePaths.validExtension($0.fileExtension) && $0.byteCount >= 0 }) &&
                      ($0.assessment.map { $0.itemIDs.count <= 10_000 && Set($0.itemIDs).count == $0.itemIDs.count && $0.itemIDs.allSatisfy(CoursePaths.validItemID) } ?? true)
                  }) else { throw CocoaError(.fileReadCorruptFile) }
            try CourseChannelImporter.validateTree(package.nodes, rootID: expected.rootID)
        }) else { throw CourseError.invalid("The channel catalog is missing.") }
        return package
    }

    func install(_ staged: [StagedCourse]) throws {
        guard ready, !staged.isEmpty, Set(staged.map { $0.course.channelID }).count == staged.count else { throw CourseError.invalid("No valid staged channel import is available.") }
        let packageRoot = root.appendingPathComponent("Packages")
        try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: true)
        var moved: [(URL, URL)] = []
        let replaced = state.courses.filter { existing in staged.contains { $0.course.channelID == existing.channelID } }
        do {
            for candidate in staged {
                guard candidate.directory.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path,
                      candidate.directory.lastPathComponent.hasPrefix(".import-"),
                      UUID(uuidString: String(candidate.directory.lastPathComponent.dropFirst(8))) != nil else { throw CourseError.invalid("The staged channel path is invalid.") }
                _ = try readPackage(directory: candidate.directory, expected: candidate.course)
                let destination = directory(for: candidate.course)
                try FileManager.default.moveItem(at: candidate.directory, to: destination)
                moved.append((candidate.directory, destination))
            }
            var updated = state
            updated.courses.removeAll { old in replaced.contains { $0.id == old.id } }
            updated.courses.append(contentsOf: staged.map(\.course))
            updated.courses.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            try save(updated)
        } catch {
            for (source, destination) in moved.reversed() { try? FileManager.default.moveItem(at: destination, to: source) }
            throw error
        }
        for old in replaced {
            do { try FileManager.default.removeItem(at: directory(for: old)) }
            catch { self.error = "The new channel was installed, but an old package could not be removed. It remains in local storage." }
        }
    }
    func remove(_ course: InstalledCourse) throws {
        var updated = state; updated.courses.removeAll { $0.id == course.id }
        try save(updated)
        do { try FileManager.default.removeItem(at: directory(for: course)) }
        catch { self.error = "The channel was removed from the catalog, but some local files could not be removed. Learner history is retained." }
    }
    func addLearner(_ name: String) throws -> UUID {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 100 else { throw CourseError.invalid("Enter a learner name of 1–100 characters.") }
        let learner = CourseLearner(id: UUID(), name: name)
        var updated = state; updated.learners.append(learner); try save(updated)
        return learner.id
    }
    func removeLearner(_ learner: CourseLearner) throws {
        var updated = state
        updated.learners.removeAll { $0.id == learner.id }
        updated.progress.removeAll { $0.learnerID == learner.id }
        updated.attempts.removeAll { $0.learnerID == learner.id }
        updated.exerciseStates?.removeAll { $0.learnerID == learner.id }
        updated.exerciseAttempts?.removeAll { $0.learnerID == learner.id }
        try save(updated)
    }
    func progress(learner: UUID, contentID: String) -> CourseProgress {
        state.progress.first { $0.learnerID == learner && $0.contentID == contentID } ?? CourseProgress(learnerID: learner, contentID: contentID)
    }
    func setCompleted(_ completed: Bool, learner: UUID, contentID: String) throws {
        guard state.learners.contains(where: { $0.id == learner }), CoursePaths.validID(contentID) else { throw CourseError.invalid("Select a valid learner before recording progress.") }
        var value = progress(learner: learner, contentID: contentID)
        value.completed = completed; value.updatedAt = Date()
        var updated = state
        updated.progress.removeAll { $0.id == value.id }; updated.progress.append(value)
        try save(updated)
    }

    nonisolated static let scormKeys: Set<String> = ["cmi.core.lesson_status", "cmi.core.score.raw", "cmi.core.score.min", "cmi.core.score.max", "cmi.core.lesson_location", "cmi.suspend_data", "cmi.completion_status", "cmi.success_status", "cmi.score.raw", "cmi.score.min", "cmi.score.max", "cmi.score.scaled", "cmi.location"]
    func recordSCORM(values: [String: String], sessionID: UUID, startedAt: Date, learner: UUID, contentID: String) throws {
        guard state.learners.contains(where: { $0.id == learner }), CoursePaths.validID(contentID),
              values.keys.allSatisfy({ Self.scormKeys.contains($0) }), values.values.allSatisfy({ $0.utf8.count <= 64 * 1_024 }) else { throw CourseError.invalid("The learning package reported unsupported progress data.") }
        var value = progress(learner: learner, contentID: contentID)
        value.scormValues = values; value.updatedAt = Date()
        let status = values["cmi.completion_status"] ?? values["cmi.core.lesson_status"]
        if status == "completed" || status == "passed" { value.completed = true }
        // Scores/statuses are recorded exactly as the package reports them, never inferred or graded here.
        let attempt = CourseAttempt(id: sessionID, learnerID: learner, contentID: contentID, startedAt: startedAt, updatedAt: Date(), reportedStatus: status, reportedScore: values["cmi.score.raw"] ?? values["cmi.core.score.raw"])
        var updated = state
        updated.progress.removeAll { $0.id == value.id }; updated.progress.append(value)
        updated.attempts.removeAll { $0.id == sessionID }; updated.attempts.append(attempt)
        try save(updated)
    }

    func resourceURL(_ resource: CourseResource, course: InstalledCourse) throws -> URL {
        guard CoursePaths.validID(resource.checksum), CoursePaths.validExtension(resource.fileExtension) else { throw CourseError.invalid("The resource path is invalid.") }
        let url = directory(for: course).appendingPathComponent(resource.relativePath)
        guard url.resolvingSymlinksInPath().standardizedFileURL == url.standardizedFileURL else { throw CourseError.invalid("The local resource path contains a symbolic link.") }
        try CoursePaths.regularFile(url)
        return url
    }
    func exerciseState(learner: UUID, contentID: String, itemID: String) -> CourseExerciseState? {
        state.exerciseStates?.first { $0.learnerID == learner && $0.contentID == contentID && $0.itemID == itemID }
    }
    private static func validAnswerState(_ value: String) -> Bool {
        guard value.utf8.count <= 1_024 * 1_024, let data = value.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
    }
    private static func validScore(type: String, earned: Double?, total: Double?) -> Bool {
        if type == "invalid" { return earned == nil && total == nil }
        guard type == "points", let earned, let total else { return false }
        return earned.isFinite && total.isFinite && total >= 0 && earned >= 0 && earned <= total
    }
    func recordExerciseState(learner: UUID, contentID: String, itemID: String, answerStateJSON: String, hintsVisible: Int) throws {
        guard state.learners.contains(where: { $0.id == learner }), CoursePaths.validID(contentID), CoursePaths.validItemID(itemID),
              Self.validAnswerState(answerStateJSON), (0...10_000).contains(hintsVisible) else {
            throw CourseError.invalid("The exercise renderer returned invalid or oversized answer state.")
        }
        let value = CourseExerciseState(learnerID: learner, contentID: contentID, itemID: itemID, answerStateJSON: answerStateJSON, hintsVisible: hintsVisible, updatedAt: Date())
        var updated = state, values = state.exerciseStates ?? []
        values.removeAll { $0.id == value.id }; values.append(value); updated.exerciseStates = values
        try save(updated)
    }
    func recordExerciseResult(learner: UUID, contentID: String, itemID: String, scoreType: String, earned: Double?, total: Double?, message: String?, hintsVisible: Int) throws {
        guard state.learners.contains(where: { $0.id == learner }), CoursePaths.validID(contentID), CoursePaths.validItemID(itemID),
              Self.validScore(type: scoreType, earned: earned, total: total), (0...10_000).contains(hintsVisible), (message?.utf8.count ?? 0) <= 64 * 1_024 else {
            throw CourseError.invalid("The exercise renderer returned an invalid result.")
        }
        let attempt = CourseExerciseAttempt(id: UUID(), learnerID: learner, contentID: contentID, itemID: itemID, recordedAt: Date(), scoreType: scoreType, earned: earned, total: total, message: message, hintsVisible: hintsVisible)
        var updated = state, attempts = state.exerciseAttempts ?? []
        attempts.append(attempt); updated.exerciseAttempts = attempts
        // This is the official renderer's individual-item result. Course mastery is
        // deliberately not inferred from a percentage or from a single correct item.
        try save(updated)
    }
    func exportProgress() throws -> Data {
        guard ready else { throw CourseError.invalid("The learner records must load before they can be exported.") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(state)
    }
}
