import SwiftUI
import UniformTypeIdentifiers
import AVKit
import PDFKit

struct CourseLibraryView: View {
    private struct Review: Identifiable { let id = UUID(); let channels: [StagedCourse] }
    @State private var store = CourseStore()
    @State private var learnerID: UUID?
    @State private var importer = false
    @State private var busy = false
    @State private var importTask: Task<Void, Never>?
    @State private var review: Review?
    @State private var newLearner = false
    @State private var learnerName = ""
    @State private var deletingCourse: InstalledCourse?
    @State private var deletingLearner: CourseLearner?
    @State private var export: CollectionExportDocument?
    @State private var exporting = false

    var body: some View {
        List {
            Section {
                Text("Offline courses").font(.title2.bold())
                Text("Import a real Kolibri KOLIBRI_DATA folder from Files. Channels, source files, and license information stay on this device. Each local learner has separate progress.").foregroundStyle(.secondary)
                if !store.ready {
                    Text("Saved course records are unavailable. Changes are disabled to preserve them.").foregroundStyle(.orange)
                    Button("Reload records") { store.reload() }
                }
                if busy { ProgressView("Validating metadata and copying course files…"); Button("Cancel import", role: .cancel) { importTask?.cancel() } }
            }
            Section("Learners") {
                Picker("Current learner", selection: $learnerID) {
                    Text("Choose a learner").tag(UUID?.none)
                    ForEach(store.state.learners) { Text($0.name).tag(Optional($0.id)) }
                }
                Button("Add learner", systemImage: "person.badge.plus") { learnerName = ""; newLearner = true }.disabled(!store.ready)
                if let current = store.state.learners.first(where: { $0.id == learnerID }) {
                    Button("Delete \(current.name)’s local profile", role: .destructive) { deletingLearner = current }.font(.caption)
                }
                Text("These are local learning profiles on a shared device, not password-protected Kolibri accounts. Classroom and facility synchronization are not connected.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Imported channels") {
                if store.state.courses.isEmpty { Text("No channels imported yet.").foregroundStyle(.secondary) }
                ForEach(store.state.courses) { course in
                    NavigationLink {
                        CourseBrowserView(store: store, course: course, learnerID: learnerID)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(course.name).font(.headline)
                            Text("Version \(course.version) · \(course.resourceCount) resources · \(course.copiedFileCount) local files").font(.caption).foregroundStyle(.secondary)
                            if course.missingFileCount > 0 { Text("\(course.missingFileCount) referenced files were absent from the export").font(.caption).foregroundStyle(.orange) }
                        }
                    }.swipeActions { Button("Delete", role: .destructive) { deletingCourse = course }.disabled(busy || !store.ready) }
                }
            }
            Section {
                Text("PDF, audio, video, HTML5 packages, and Perseus exercises use local content. H5P, QTI, Bloom, and full classroom tools still need their respective integrations.").font(.caption).foregroundStyle(.secondary)
                Link("Export channels from Kolibri", destination: URL(string: "https://kolibri.readthedocs.io/en/latest/manage/resources.html#export-from-kolibri-to-local-drive")!)
            }
        }
        .navigationTitle("Course Library")
        .toolbar {
            Button("Import Kolibri folder", systemImage: "folder.badge.plus") { importer = true }.disabled(!store.ready || busy || review != nil)
            Button("Export learner records", systemImage: "square.and.arrow.up") {
                do { export = CollectionExportDocument(data: try store.exportProgress()); exporting = true }
                catch { store.error = error.localizedDescription }
            }.disabled(!store.ready)
        }
        .fileImporter(isPresented: $importer, allowedContentTypes: [.folder]) { result in
            switch result { case .success(let url): prepare(url); case .failure(let error): store.error = error.localizedDescription }
        }
        .fileExporter(isPresented: $exporting, document: export, contentType: .json, defaultFilename: "NOMAD-learner-records") { result in
            if case .failure(let error) = result { store.error = error.localizedDescription }
        }
        .sheet(item: $review) { item in
            NavigationStack {
                List {
                    Section {
                        Text("Install \(item.channels.count) channel(s)?").font(.headline)
                        Text("Matching channel IDs replace their previous imported version. Existing learner history is retained by Kolibri content ID. Original exports are never changed.")
                    }
                    ForEach(item.channels) { channel in
                        VStack(alignment: .leading) {
                            Text(channel.course.name)
                            Text("\(channel.course.copiedFileCount) files copied · \(channel.course.missingFileCount) unavailable").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.navigationTitle("Review channel import")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { discardReview() } }
                        ToolbarItem(placement: .confirmationAction) { Button("Install") {
                            do { try store.install(item.channels); review = nil }
                            catch { store.error = error.localizedDescription; discardReview() }
                        } }
                    }
            }.interactiveDismissDisabled()
        }
        .sheet(isPresented: $newLearner) {
            NavigationStack {
                Form { TextField("Learner name", text: $learnerName) }.navigationTitle("New learner")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { newLearner = false } }
                        ToolbarItem(placement: .confirmationAction) { Button("Add") {
                            do { learnerID = try store.addLearner(learnerName); newLearner = false }
                            catch { store.error = error.localizedDescription; newLearner = false }
                        }.disabled(learnerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                    }
            }
        }
        .confirmationDialog("Delete this channel’s local files? Learner history will be retained.", isPresented: Binding(get: { deletingCourse != nil }, set: { if !$0 { deletingCourse = nil } }), titleVisibility: .visible) {
            Button("Delete channel", role: .destructive) {
                if let deletingCourse { do { try store.remove(deletingCourse) } catch { store.error = error.localizedDescription } }
                deletingCourse = nil
            }
        }
        .confirmationDialog("Delete this learner and all their local progress and attempts?", isPresented: Binding(get: { deletingLearner != nil }, set: { if !$0 { deletingLearner = nil } }), titleVisibility: .visible) {
            Button("Delete learner", role: .destructive) {
                if let deletingLearner {
                    do { try store.removeLearner(deletingLearner); if learnerID == deletingLearner.id { learnerID = nil } }
                    catch { store.error = error.localizedDescription }
                }
                deletingLearner = nil
            }
        }
        .alert("Course Library", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("OK") { store.error = nil } } message: { Text(store.error ?? "") }
        .onDisappear { importTask?.cancel() }
    }

    private func prepare(_ url: URL) {
        guard store.ready, !busy, review == nil else { return }
        busy = true
        let root = store.root
        importTask = Task { @MainActor in
            defer { busy = false; importTask = nil }
            var staged: [StagedCourse] = []
            do {
                let worker = Task.detached(priority: .userInitiated) { try CourseChannelImporter.prepare(selected: url, storageRoot: root) }
                staged = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                review = Review(channels: staged)
            } catch {
                staged.forEach { try? FileManager.default.removeItem(at: $0.directory) }
                if !Task.isCancelled { store.error = error.localizedDescription }
            }
        }
    }
    private func discardReview() {
        review?.channels.forEach { try? FileManager.default.removeItem(at: $0.directory) }
        review = nil
    }
}

private struct CourseBrowserView: View {
    let store: CourseStore
    let course: InstalledCourse
    let learnerID: UUID?
    @State private var package: CoursePackage?
    @State private var error: String?
    var body: some View {
        Group {
            if let package { CourseTopicView(store: store, package: package, parentID: course.rootID, title: course.name, learnerID: learnerID) }
            else if let error { ContentUnavailableView("Channel could not be opened", systemImage: "exclamationmark.triangle", description: Text(error)) }
            else { ProgressView("Reading channel…") }
        }.task { do { package = try store.package(for: course) } catch { self.error = error.localizedDescription } }
    }
}

private struct CourseTopicView: View {
    let store: CourseStore
    let package: CoursePackage
    let parentID: String
    let title: String
    let learnerID: UUID?
    var body: some View {
        List {
            if parentID == package.course.rootID {
                Section {
                    if !package.course.author.isEmpty { Text("By \(package.course.author)") }
                    if !package.course.summary.isEmpty { Text(package.course.summary).font(.subheadline) }
                    Text(learnerID == nil ? "Select a learner in Course Library to save progress." : "Progress is saved for the selected local learner.").font(.caption).foregroundStyle(.secondary)
                    ShareLink("Export original channel package", item: store.directory(for: package.course))
                    Text("The exported folder retains the original channel database and resources. Native learner records are exported separately.").font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(package.nodes.filter { $0.parentID == parentID }.sorted { $0.order == $1.order ? $0.title < $1.title : $0.order < $1.order }) { node in
                NavigationLink {
                    if node.kind == "topic" { CourseTopicView(store: store, package: package, parentID: node.id, title: node.title, learnerID: learnerID) }
                    else { CourseResourceView(store: store, course: package.course, node: node, learnerID: learnerID) }
                } label: {
                    HStack {
                        Image(systemName: node.kind == "topic" ? "folder" : "doc.text")
                        VStack(alignment: .leading) {
                            Text(node.title)
                            if node.supportMessage != nil { Text(node.primaryResource == nil ? "File unavailable" : "Renderer not integrated").font(.caption).foregroundStyle(.orange) }
                        }
                        Spacer()
                        if let learnerID, store.progress(learner: learnerID, contentID: node.contentID).completed { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                    }
                }
            }
        }.navigationTitle(title)
    }
}

private struct CourseResourceView: View {
    let store: CourseStore
    let course: InstalledCourse
    let node: CourseNode
    let learnerID: UUID?
    @State private var url: URL?
    @State private var player: AVPlayer?
    @State private var error: String?
    @State private var launchHTML = false
    @State private var launchExercise = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(node.title).font(.title2.bold())
                if !node.summary.isEmpty { Text(node.summary) }
                if let message = node.supportMessage { Label(message, systemImage: "info.circle").foregroundStyle(.orange) }
                else if let url, let resource = node.primaryResource {
                    if resource.fileExtension == "perseus" {
                        Button("Open exercises", systemImage: "pencil.and.list.clipboard") { launchExercise = true }.buttonStyle(.borderedProminent).disabled(learnerID == nil)
                        Text("The official Perseus engine checks each answer. Answers, hints, and results are saved for the selected learner; Kolibri’s course mastery policy is not inferred from individual scores.").font(.caption).foregroundStyle(.secondary)
                        if let learnerID, let attempt = store.state.exerciseAttempts?.last(where: { $0.learnerID == learnerID && $0.contentID == node.contentID }) {
                            Text(attempt.scoreType == "points" ? "Last score: \((attempt.earned ?? 0).formatted()) / \((attempt.total ?? 0).formatted())" : "Last answer was not ready to score.").font(.caption)
                        }
                    }
                    else if resource.fileExtension == "pdf" { CoursePDFView(url: url).frame(minHeight: 600) }
                    else if ["html5", "zip"].contains(resource.fileExtension) {
                        Button("Open interactive content", systemImage: "play.rectangle") { launchHTML = true }.buttonStyle(.borderedProminent).disabled(learnerID == nil)
                        Text("HTML5 packages run without network access. The limited progress bridge saves package-reported status, scores, and resume data; full SCORM certification is not claimed.").font(.caption).foregroundStyle(.secondary)
                    } else if let player { VideoPlayer(player: player).frame(height: 360) }
                }
                if let error { Text(error).foregroundStyle(.orange) }
                if let learnerID, node.kind != "exercise", node.supportMessage == nil {
                    let progress = store.progress(learner: learnerID, contentID: node.contentID)
                    Button(progress.completed ? "Mark incomplete" : "Mark completed", systemImage: progress.completed ? "checkmark.circle.fill" : "circle") {
                        do { try store.setCompleted(!progress.completed, learner: learnerID, contentID: node.contentID) }
                        catch { self.error = error.localizedDescription }
                    }.buttonStyle(.bordered)
                    if let attempt = store.state.attempts.last(where: { $0.learnerID == learnerID && $0.contentID == node.contentID }) {
                        Text("Package-reported status: \(attempt.reportedStatus ?? "not reported") · score: \(attempt.reportedScore ?? "not reported")").font(.caption)
                    }
                }
                Divider()
                Text("Attribution & license").font(.headline)
                Text(node.author.isEmpty ? course.author : node.author)
                Text(node.licenseName.isEmpty ? "No license name was included in the channel metadata." : node.licenseName)
                if !node.licenseOwner.isEmpty { Text(node.licenseOwner) }
                if !node.licenseDescription.isEmpty { Text(node.licenseDescription).font(.caption) }
                if let url { ShareLink("Export original resource", item: url) }
            }.padding()
        }.navigationTitle(node.title)
            .task {
                guard let resource = node.primaryResource else { return }
                do {
                    let file = try store.resourceURL(resource, course: course); url = file
                    if ["mp4", "m4v", "mov", "mp3", "m4a", "wav"].contains(resource.fileExtension) {
                        guard try await AVURLAsset(url: file).load(.isPlayable) else { throw CourseError.invalid("This device cannot play the resource’s media codec.") }
                        player = AVPlayer(url: file)
                    }
                    if resource.fileExtension == "pdf", PDFDocument(url: file) == nil { throw CourseError.invalid("The PDF could not be opened.") }
                } catch { self.error = error.localizedDescription }
            }
            .onDisappear { player?.pause() }
            .sheet(isPresented: $launchHTML) {
                if let url, let learnerID { CourseHTMLPlayer(store: store, url: url, node: node, learnerID: learnerID) }
            }
            .sheet(isPresented: $launchExercise) {
                if let url, let learnerID, let renderer = CoursePaths.perseusBundle {
                    CourseExercisePlayer(store: store, url: url, rendererRoot: renderer, node: node, learnerID: learnerID)
                }
            }
    }
}

private struct CourseExercisePlayer: View {
    @Environment(\.dismiss) private var dismiss
    let store: CourseStore
    let url: URL
    let rendererRoot: URL
    let node: CourseNode
    let learnerID: UUID
    @State private var itemID: String?
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let assessment = node.assessment, !assessment.itemIDs.isEmpty {
                    Picker("Question", selection: $itemID) {
                        Text("Choose a question").tag(String?.none)
                        ForEach(Array(assessment.itemIDs.enumerated()), id: \.element) { index, id in Text("Question \(index + 1)").tag(Optional(id)) }
                    }.pickerStyle(.menu).padding(.horizontal)
                    if let itemID {
                        CourseExerciseQuestion(store: store, url: url, rendererRoot: rendererRoot, node: node, learnerID: learnerID, itemID: itemID).id(itemID)
                    } else { ContentUnavailableView("Choose a question", systemImage: "pencil") }
                } else { ContentUnavailableView("No assessment catalog", systemImage: "exclamationmark.triangle") }
            }
            .navigationTitle(node.title)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { if itemID == nil { itemID = node.assessment?.itemIDs.first } }
        }
    }
}

private struct CourseExerciseQuestion: View {
    let store: CourseStore
    let url: URL
    let rendererRoot: URL
    let node: CourseNode
    let learnerID: UUID
    let itemID: String
    @State private var controller = CoursePerseusController()
    @State private var saveError: String?
    var body: some View {
        VStack(spacing: 0) {
            if let error = controller.error ?? saveError { Text(error).foregroundStyle(.orange).padding() }
            if let feedback = controller.feedback { Text(feedback).font(.headline).padding(.horizontal) }
            CoursePerseusView(controller: controller, archiveURL: url, rendererRoot: rendererRoot, itemID: itemID, locale: node.languageCode ?? "en",
                              initial: store.exerciseState(learner: learnerID, contentID: node.contentID, itemID: itemID)) { json, hints in
                do { try store.recordExerciseState(learner: learnerID, contentID: node.contentID, itemID: itemID, answerStateJSON: json, hintsVisible: hints); saveError = nil }
                catch { saveError = "The answer could not be saved: \(error.localizedDescription)" }
            } onResult: { type, earned, total, message, hints in
                do { try store.recordExerciseResult(learner: learnerID, contentID: node.contentID, itemID: itemID, scoreType: type, earned: earned, total: total, message: message, hintsVisible: hints) }
                catch { saveError = "The result could not be saved: \(error.localizedDescription)" }
            }
            HStack {
                Button("Show hint", systemImage: "lightbulb") { controller.showHint() }.buttonStyle(.bordered)
                Spacer()
                Button("Check answer", systemImage: "checkmark.circle") { controller.checkAnswer() }.buttonStyle(.borderedProminent)
            }.disabled(!controller.ready).padding()
            Text("Question scores are recorded as reported by Perseus. Course mastery and classroom synchronization are not applied.").font(.caption).foregroundStyle(.secondary).padding([.horizontal, .bottom])
        }
    }
}

private struct CoursePDFView: PlatformViewRepresentable {
    let url: URL
    func makePlatformView(context: Context) -> PDFView { let view = PDFView(); view.autoScales = true; view.document = PDFDocument(url: url); return view }
    func updatePlatformView(_ uiView: PDFView, context: Context) {}
}

private struct CourseHTMLPlayer: View {
    @Environment(\.dismiss) private var dismiss
    let store: CourseStore
    let url: URL
    let node: CourseNode
    let learnerID: UUID
    @State private var sessionID = UUID()
    @State private var started = Date()
    @State private var error: String?
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let error { Text(error).foregroundStyle(.orange).padding() }
                CourseHTMLView(archiveURL: url, initialValues: store.progress(learner: learnerID, contentID: node.contentID).scormValues) { values in
                    do { try store.recordSCORM(values: values, sessionID: sessionID, startedAt: started, learner: learnerID, contentID: node.contentID) }
                    catch { self.error = "Progress could not be saved: \(error.localizedDescription)" }
                } onError: { error = $0 }
            }.navigationTitle(node.title).toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

#if os(macOS)
extension CoursePDFView {
    func makeNSView(context: Context) -> PDFView { makePlatformView(context: context) }
    func updateNSView(_ view: PDFView, context: Context) { updatePlatformView(view, context: context) }
}
#else
extension CoursePDFView {
    func makeUIView(context: Context) -> PDFView { makePlatformView(context: context) }
    func updateUIView(_ view: PDFView, context: Context) { updatePlatformView(view, context: context) }
}
#endif
