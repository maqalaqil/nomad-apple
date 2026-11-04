#if NOMAD_COURSE_ENGINE_TESTS
import Foundation
import Darwin

@main @MainActor
private enum CourseEngineTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw CourseError.invalid("TEST FAILURE: " + message) }; checks += 1
    }
    static func rejects(_ message: String, _ action: () throws -> Void) throws {
        do { try action() } catch { checks += 1; return }
        throw CourseError.invalid("TEST FAILURE: expected rejection: " + message)
    }
    static func main() {
        do { try run() } catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func run() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
        let storage = root.appendingPathComponent("native-store")
        for name in ["stored", "deflated"] {
            let zip = try CourseZipArchive(url: root.appendingPathComponent(name + ".zip"))
            try check(try zip.entryPoint() == "index.html", "ZIP entry point")
            try check(try String(data: zip.read("index.html"), encoding: .utf8)?.contains("TEST-ONLY") == true, "ZIP payload round trip")
            try rejects("Missing ZIP path") { _ = try zip.read("absent") }
        }
        for name in ["traversal", "symlink", "truncated"] {
            try rejects("Unsafe ZIP \(name)") { _ = try CourseZipArchive(url: root.appendingPathComponent(name + ".zip")) }
        }
        try rejects("ZIP checksum mismatch") { _ = try CourseZipArchive(url: root.appendingPathComponent("bad-crc.zip")).read("index.html") }
        try rejects("Missing HTML entry") { _ = try CourseZipArchive(url: root.appendingPathComponent("no-entry.zip")).entryPoint() }
        try rejects("Remote SCORM entry") { _ = try CourseZipArchive(url: root.appendingPathComponent("external-scorm.zip")).entryPoint() }
        try check(try CourseZipArchive(url: root.appendingPathComponent("scorm.zip")).entryPoint() == "lesson/start.html", "SCORM local launch path")
        let valid = root.appendingPathComponent("valid-export")
        let sourceDB = valid.appendingPathComponent("databases/" + String(repeating: "a", count: 32) + ".sqlite3")
        let original = try Data(contentsOf: sourceDB)
        let prepared = try CourseChannelImporter.prepare(selected: valid, storageRoot: storage)
        try check(prepared.count == 1 && prepared[0].course.copiedFileCount == 1 && prepared[0].course.missingFileCount == 0, "Real exported-folder shape imports files")
        try check(try Data(contentsOf: sourceDB) == original, "Import leaves original metadata unchanged")
        let store = CourseStore(root: storage)
        try check(store.ready && store.state.courses.isEmpty, "Staging must not activate channels")
        try store.install(prepared)
        try check(store.state.courses.count == 1, "Confirmed channel installation")
        let installed = store.state.courses[0], package = try store.package(for: installed)
        try check(package.nodes.count == 2, "Topic and lesson hierarchy preserved")
        let lesson = package.nodes.first { $0.kind == "html5" }!
        try check(lesson.licenseName == "TEST-ONLY license" && lesson.licenseOwner == "TEST-ONLY owner", "License fields preserved")
        try check(try FileManager.default.fileExists(atPath: store.resourceURL(lesson.primaryResource!, course: installed).path), "Imported asset resolves inside local package")
        let activeManifest = try Data(contentsOf: storage.appendingPathComponent("learners-and-channels.json"))
        for name in ["missing-schema", "view-schema", "missing-parent", "cycle", "wrong-channel", "missing-file-record", "unsafe-checksum", "checksum-mismatch", "symlink-resource"] {
            try rejects("Invalid exported channel \(name)") { _ = try CourseChannelImporter.prepare(selected: root.appendingPathComponent(name), storageRoot: storage) }
            try check(try Data(contentsOf: storage.appendingPathComponent("learners-and-channels.json")) == activeManifest, "Failed import keeps active manifest")
        }
        let partial = try CourseChannelImporter.prepare(selected: root.appendingPathComponent("partial-export"), storageRoot: storage)
        try check(partial[0].course.missingFileCount == 1 && partial[0].course.copiedFileCount == 0, "Partial exports report missing content honestly")
        partial.forEach { try? FileManager.default.removeItem(at: $0.directory) }
        let alice = try store.addLearner("TEST-ONLY Alice"), bob = try store.addLearner("TEST-ONLY Bob")
        let exercise = try CourseChannelImporter.prepare(selected: root.appendingPathComponent("exercise-export"), storageRoot: storage)
        let exercisePackage = try JSONDecoder().decode(CoursePackage.self, from: Data(contentsOf: exercise[0].directory.appendingPathComponent("course.json")))
        let exerciseNode = exercisePackage.nodes.first { $0.kind == "exercise" }!
        try check(exerciseNode.assessment?.itemIDs == ["test-item"] && exerciseNode.assessment?.randomize == true && exerciseNode.languageCode == "ar", "Original assessment IDs, randomization setting, and locale preserved")
        try check(exerciseNode.assessment?.masteryModelJSON == "{\"type\":\"m_of_n\",\"m\":3,\"n\":5}", "Mastery policy is preserved verbatim without approximated grading")
        exercise.forEach { try? FileManager.default.removeItem(at: $0.directory) }
        try rejects("Unsafe assessment paths") { _ = try CourseChannelImporter.prepare(selected: root.appendingPathComponent("unsafe-items"), storageRoot: storage) }
        try store.recordExerciseState(learner: alice, contentID: lesson.contentID, itemID: "test-item", answerStateJSON: "{\"TEST-ONLY\":true}", hintsVisible: 2)
        try check(store.exerciseState(learner: alice, contentID: lesson.contentID, itemID: "test-item")?.hintsVisible == 2 && store.exerciseState(learner: bob, contentID: lesson.contentID, itemID: "test-item") == nil, "Exercise answers and hints remain learner-specific")
        try store.recordExerciseResult(learner: alice, contentID: lesson.contentID, itemID: "test-item", scoreType: "points", earned: 1, total: 1, message: nil, hintsVisible: 2)
        try check(store.state.exerciseAttempts?.last?.earned == 1 && !store.progress(learner: alice, contentID: lesson.contentID).completed, "Scorer result is saved exactly and never implies course completion")
        try rejects("Malformed exercise JSON") { try store.recordExerciseState(learner: alice, contentID: lesson.contentID, itemID: "test-item", answerStateJSON: "not JSON", hintsVisible: 0) }
        try rejects("Invalid score range") { try store.recordExerciseResult(learner: alice, contentID: lesson.contentID, itemID: "test-item", scoreType: "points", earned: 2, total: 1, message: nil, hintsVisible: 0) }
        for pair: (Double?, Double?) in [(.nan, 1), (1, .infinity), (-1, 1), (1, -1), (nil, 1)] {
            try rejects("Nonfinite, missing, or negative score") { try store.recordExerciseResult(learner: alice, contentID: lesson.contentID, itemID: "test-item", scoreType: "points", earned: pair.0, total: pair.1, message: nil, hintsVisible: 0) }
        }
        try rejects("Invalid result must not carry points") { try store.recordExerciseResult(learner: alice, contentID: lesson.contentID, itemID: "test-item", scoreType: "invalid", earned: 1, total: 1, message: nil, hintsVisible: 0) }
        let bridge: [String: Any] = ["type": "result", "itemId": "test-item", "answerState": ["widgets": [:]], "hintsVisible": 0, "score": ["type": "points", "earned": 1, "total": 1]]
        if case .result(_, 0, "points", 1, 1, nil) = try CoursePerseusMessage.decode(bridge, itemID: "test-item") { checks += 1 }
        else { throw CourseError.invalid("TEST FAILURE: Official bridge score shape") }
        try rejects("Cross-question bridge result") { _ = try CoursePerseusMessage.decode(bridge, itemID: "another-item") }
        for change: [String: Any] in [["hintsVisible": -1], ["hintsVisible": true], ["hintsVisible": 0.5], ["answerState": "not object"], ["score": ["type": "points", "earned": true, "total": 1]], ["score": ["type": "points", "earned": 5, "total": 1]], ["score": ["type": "points", "earned": Double.nan, "total": 1]], ["score": ["type": "points", "earned": 1, "total": Double.infinity]], ["score": ["type": "points", "earned": 1, "total": 1, "message": ["not a string"]]]] {
            var invalid = bridge; invalid.merge(change) { _, new in new }
            try rejects("Invalid bridge state/score") { _ = try CoursePerseusMessage.decode(invalid, itemID: "test-item") }
        }
        try store.setCompleted(true, learner: alice, contentID: lesson.contentID)
        try check(store.progress(learner: alice, contentID: lesson.contentID).completed && !store.progress(learner: bob, contentID: lesson.contentID).completed, "Learner progress remains separate")
        let session = UUID()
        try store.recordSCORM(values: ["cmi.core.lesson_status": "completed", "cmi.core.score.raw": "7", "cmi.suspend_data": "TEST-ONLY resume"], sessionID: session, startedAt: Date(), learner: alice, contentID: lesson.contentID)
        try check(store.state.attempts.count == 1 && store.state.attempts[0].reportedScore == "7", "SCORM reports are recorded verbatim")
        try store.recordSCORM(values: ["cmi.core.lesson_status": "completed", "cmi.core.score.raw": "8"], sessionID: session, startedAt: Date(), learner: alice, contentID: lesson.contentID)
        try check(store.state.attempts.count == 1 && store.state.attempts[0].reportedScore == "8", "One session updates one attempt")
        try rejects("Unsupported SCORM fields") { try store.recordSCORM(values: ["unexpected": "x"], sessionID: UUID(), startedAt: Date(), learner: alice, contentID: lesson.contentID) }
        let reopened = CourseStore(root: storage)
        try check(reopened.ready && reopened.state.learners.count == 2 && reopened.progress(learner: alice, contentID: lesson.contentID).completed, "Profiles/progress survive reopening")
        try check(reopened.exerciseState(learner: alice, contentID: lesson.contentID, itemID: "test-item")?.hintsVisible == 2 && reopened.state.exerciseAttempts?.last?.earned == 1, "Exercise answers, hints, and actual scores survive reopening")
        let replacement = try CourseChannelImporter.prepare(selected: valid, storageRoot: storage)
        try reopened.install(replacement)
        try check(reopened.state.courses.count == 1 && reopened.state.courses[0].id != installed.id && reopened.progress(learner: alice, contentID: lesson.contentID).completed, "Channel replacement preserves content-ID progress")
        try check(!FileManager.default.fileExists(atPath: reopened.directory(for: installed).path), "Replaced package removed only after successful commit")
        let exported = try JSONDecoder().decode(CourseState.self, from: reopened.exportProgress())
        try check(exported.learners.count == 2 && exported.attempts.count == 1, "Native learner export includes profiles and recorded attempts")
        try reopened.remove(reopened.state.courses[0])
        try check(reopened.state.courses.isEmpty && !reopened.state.progress.isEmpty, "Channel deletion preserves learner history")
        try reopened.removeLearner(reopened.state.learners.first { $0.id == alice }!)
        try check(reopened.state.learners.count == 1 && reopened.state.learners[0].id == bob && reopened.state.attempts.isEmpty && reopened.state.progress.isEmpty, "Learner deletion removes only that learner’s records")
        try check(reopened.state.exerciseStates?.isEmpty == true && reopened.state.exerciseAttempts?.isEmpty == true, "Learner deletion removes their exercise state and results")
        let manifestURL = storage.appendingPathComponent("learners-and-channels.json")
        let corrupt = Data("{ TEST-ONLY malformed manifest".utf8)
        try corrupt.write(to: manifestURL)
        let failed = CourseStore(root: storage)
        try check(!failed.ready, "Corrupt manifest disables changes")
        try rejects("Corrupt manifest overwrite") { _ = try failed.addLearner("Should not save") }
        try check(try Data(contentsOf: manifestURL) == corrupt, "Corrupt manifest remains byte-for-byte intact")
        let upstream = root.appendingPathComponent("upstream-export")
        if FileManager.default.fileExists(atPath: upstream.path) {
            let channel = try CourseChannelImporter.prepare(selected: upstream, storageRoot: root.appendingPathComponent("upstream-store"))
            try check(channel.count == 1 && channel[0].course.name == "testing" && channel[0].course.resourceCount == 5, "Official Kolibri import-fixture metadata maps without changing its original fields")
            try check(channel[0].course.missingFileCount == 5, "Upstream metadata-only fixture correctly reports absent resource bytes")
        }
        print("PASS: \(checks) native course checks. Synthetic exports and optional official Kolibri test metadata only; no learner or production course data was used.")
    }
}
#endif
