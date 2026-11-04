import SwiftUI
import UniformTypeIdentifiers

struct MedicalReferenceView: View {
    private enum SearchMode: String, CaseIterable { case names = "Drug name", indications = "Indications", situations = "Situations" }
    private struct SearchKey: Hashable { let dataset: UUID?; let mode: SearchMode; let query: String; let otc: Bool; let selection: DrugSituationSelection }
    @State private var repository = DrugReferenceRepository()
    @State private var dataset: DrugDatasetInfo?
    @State private var candidate: DrugDatasetInfo?
    @State private var query = ""
    @State private var mode = SearchMode.names
    @State private var otcOnly = false
    @State private var situations = DrugSituationSelection()
    @State private var choosingSituations = false
    @State private var results: [DrugLabelSummary] = []
    @State private var searching = false
    @State private var importing = false
    @State private var processing = false
    @State private var importTask: Task<Void, Never>?
    @State private var detail: DrugLabelDetail?
    @State private var comparison: [DrugLabelDetail] = []
    @State private var showingComparison = false
    @State private var showingUninstall = false
    @State private var error: String?
    @State private var notice: String?

    private var searchID: SearchKey { .init(dataset: dataset?.id, mode: mode, query: query, otc: otcOnly, selection: situations) }
    private var hasSearch: Bool { mode == .situations ? situations.count > 0 : !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        List {
            Section {
                Text("Read the manufacturer's label text. This reference does not diagnose conditions, recommend treatment, or establish whether medicines are safe together.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if processing {
                Section {
                    HStack { ProgressView(); Text("Reading and validating the selected data…") }
                    Text("Large datasets take time and need free space for a new database. Your installed reference stays intact until you approve the replacement.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Cancel import", role: .cancel) { importTask?.cancel() }
                }
            }
            if let notice { Section { Text(notice).font(.footnote).foregroundStyle(.secondary) } }
            if let dataset {
                datasetSection(dataset)
                searchControls
                if searching { HStack { ProgressView(); Text("Searching local labels…") } }
                if !hasSearch {
                    ContentUnavailableView("Search your imported labels", systemImage: "magnifyingglass",
                        description: Text("Search a brand or generic name, or find words in the indications section. A situation search finds matching label text; it is not a treatment recommendation."))
                } else if results.isEmpty && !searching {
                    ContentUnavailableView("No matching labels", systemImage: "doc.text.magnifyingglass",
                        description: Text("Try another spelling or import more dataset parts. No result does not establish that a medicine or interaction is absent."))
                } else {
                    Section(mode == .situations ? "Labels matching every group · up to 100 products" : "Matching products · up to 100") {
                        ForEach(results) { item in
                            HStack(spacing: 12) {
                                Button { openDetail(item.id) } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(item.title).font(.headline).foregroundStyle(.primary)
                                        if !item.generic.isEmpty && item.generic != item.brand {
                                            Text(item.generic).font(.subheadline).foregroundStyle(.secondary)
                                        }
                                        Text([item.productType, item.manufacturer].filter { !$0.isEmpty }.joined(separator: " · "))
                                            .font(.caption).foregroundStyle(.secondary)
                                        if item.labelCount > 1 {
                                            Text("\(item.labelCount) matching labels share this brand and generic name; opens one matching label.")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(.plain)
                                Button { addComparison(item.id) } label: {
                                    Image(systemName: comparison.contains { $0.id == item.id } ? "checkmark.circle.fill" : "plus.circle")
                                }.buttonStyle(.borderless)
                                    .disabled(comparison.count >= 5 || comparison.contains { $0.id == item.id })
                                    .accessibilityLabel("Add \(item.title) to label comparison")
                            }.padding(.vertical, 4)
                        }
                    }
                }
            } else if !processing {
                ContentUnavailableView {
                    Label("No drug-label dataset installed", systemImage: "cross.case")
                } description: {
                    Text("Import official openFDA JSON data or a compatible SQLite database. No sample medical records are included.")
                } actions: {
                    Button("Import dataset", systemImage: "square.and.arrow.down") { importing = true }.buttonStyle(.borderedProminent)
                }
            }
            setupSection
        }
        .navigationTitle("Drug Reference")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Import", systemImage: "square.and.arrow.down") { importing = true }.disabled(processing)
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("Compare \(comparison.count)", systemImage: "rectangle.split.2x1") { showingComparison = true }
                    .disabled(comparison.isEmpty)
            }
            if dataset != nil {
                ToolbarItem(placement: .secondaryAction) {
                    Button("Remove dataset", systemImage: "trash", role: .destructive) { showingUninstall = true }.disabled(processing)
                }
            }
        }
        .task {
            do { dataset = try await repository.current() }
            catch { self.error = error.localizedDescription }
        }
        .task(id: searchID) { await performSearch() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .json], allowsMultipleSelection: true) { result in
            do { beginImport(try result.get()) } catch { self.error = error.localizedDescription }
        }
        .sheet(item: $candidate) { prepared in
            NavigationStack {
                Form {
                    Section("Prepared dataset") {
                        LabeledContent("Labels", value: prepared.labelCount.formatted())
                        LabeledContent("Declared source", value: prepared.source)
                        Text("The imported data passed structural validation. Its clinical content and completeness are not independently verified. This replaces the current reference; choose all desired JSON parts together.")
                    }
                    Section {
                        Button(dataset == nil ? "Install dataset" : "Replace installed dataset") { activate(prepared) }
                        Button("Cancel", role: .cancel) { discard(prepared) }
                    }
                }.navigationTitle("Use this dataset?")
            }.interactiveDismissDisabled().presentationDetents([.medium, .large])
        }
        .confirmationDialog("Remove the installed drug reference?", isPresented: $showingUninstall, titleVisibility: .visible) {
            Button("Remove dataset", role: .destructive) {
                Task {
                    do { try await repository.uninstall(); dataset = nil; results = []; comparison = []; notice = "The local drug dataset was removed." }
                    catch { self.error = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: { Text("The imported copy will be deleted. The original files in Files are kept.") }
        .sheet(item: $detail) { label in
            DrugLabelDetailView(label: label, dataset: dataset) { addComparison(label.id) }
        }
        .sheet(isPresented: $showingComparison) {
            DrugLabelComparisonView(labels: $comparison)
        }
        .sheet(isPresented: $choosingSituations) { DrugSituationPicker(selection: $situations) }
        .alert("Drug Reference", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
        .onDisappear {
            importTask?.cancel()
            if let candidate { discard(candidate) }
        }
    }

    @ViewBuilder private func datasetSection(_ info: DrugDatasetInfo) -> some View {
        Section("Installed reference") {
            LabeledContent("Labels", value: info.labelCount.formatted())
            DisclosureGroup("Dataset source and dates") {
                LabeledContent("Declared source", value: info.source)
                LabeledContent("Dataset date", value: (info.exportDate?.isEmpty == false ? info.exportDate : nil) ?? "Not supplied")
                LabeledContent("Imported", value: info.importedAt.formatted(date: .abbreviated, time: .shortened))
                if let note = info.importNote { Text(note).font(.caption).foregroundStyle(.secondary) }
                ForEach(Array(info.originalFiles.enumerated()), id: \.offset) { _, name in Text(name).font(.caption).textSelection(.enabled) }
                if let text = info.sourceURL, let url = URL(string: text), ["https", "http"].contains(url.scheme ?? "") {
                    Link("Source website (internet required)", destination: url)
                }
            }
        }
    }

    private var searchControls: some View {
        Section("Search local label text") {
            Picker("Search", selection: $mode) {
                ForEach(SearchMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            if mode == .situations {
                Button("Choose situation or custom text groups (\(situations.count)/8)", systemImage: "checklist") { choosingSituations = true }
                ForEach(situations.conditions) { condition in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(condition.label)
                            Text(condition.searchTerms.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove \(condition.label)", systemImage: "xmark.circle") { situations.conditionIDs.remove(condition.id) }.labelStyle(.iconOnly)
                    }
                }
                ForEach(situations.customTerms, id: \.self) { term in
                    HStack {
                        Text("Custom text: \(term)")
                        Spacer()
                        Button("Remove \(term)", systemImage: "xmark.circle") { situations.customTerms.removeAll { $0 == term } }.labelStyle(.iconOnly)
                    }
                }
                if situations.count > 0 { Button("Clear selected groups", role: .cancel) { situations = DrugSituationSelection() } }
                Text("Each result is an OTC label whose indications contain at least one term from every selected group. Matches are literal text, including negated statements; they do not establish suitability, combined treatment or safety. Catalog: \(DrugConditionCatalog.version).")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                TextField(mode == .indications ? "Words in label indications" : "Brand or generic name", text: $query)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Toggle("Over-the-counter labels only", isOn: $otcOnly)
            }
        }
    }

    private var setupSection: some View {
        Section {
            DisclosureGroup("Get and prepare a dataset") {
                Text("NOMAD's upstream source is the openFDA drug-label bulk export. Download the desired .json.zip parts while online, expand them in Files, then import the extracted .json files together here. Keep enough free space for those files, a new indexed copy, and any currently installed reference.")
                Text("Compatible .sqlite, .sqlite3 and .db snapshots with the documented drug_labels columns can also be imported. The app validates the schema and copies a consistent snapshot; it never edits your original database.")
                Text("A new import replaces the previous dataset after validation and your confirmation. Background download, ZIP extraction, automatic content updates and clinical interaction calculation are not provided by this screen.")
                Link("Official drug-label downloads", destination: URL(string: "https://open.fda.gov/apis/drug/label/download/")!)
                Link("Official download manifest", destination: URL(string: "https://api.fda.gov/download.json")!)
            }.font(.footnote)
        }
    }

    @MainActor private func performSearch() async {
        let requestedID = searchID
        guard dataset != nil, hasSearch else { results = []; searching = false; return }
        searching = true
        results = []
        defer { if requestedID == searchID { searching = false } }
        do {
            try await Task.sleep(for: .milliseconds(250))
            let found = try await mode == .situations ? repository.searchSituations(situations) : repository.search(query, indications: mode == .indications, otcOnly: otcOnly)
            try Task.checkCancellation()
            if requestedID == searchID { results = found }
        } catch is CancellationError { }
        catch { if requestedID == searchID { results = []; self.error = error.localizedDescription } }
    }

    private func beginImport(_ urls: [URL]) {
        guard !processing else { return }
        processing = true
        notice = nil
        importTask = Task {
            defer { processing = false; importTask = nil }
            do {
                let prepared = try await repository.prepareImport(urls)
                if Task.isCancelled { try await repository.discard(prepared); notice = "Import cancelled. Your installed reference was kept." }
                else { candidate = prepared }
            } catch is CancellationError { notice = "Import cancelled. Your installed reference was kept." }
            catch { self.error = error.localizedDescription }
        }
    }

    private func activate(_ info: DrugDatasetInfo) {
        candidate = nil
        Task {
            do {
                let warning = try await repository.activate(info)
                dataset = info
                results = []
                comparison = []
                notice = warning ?? "\(info.labelCount.formatted()) labels installed for offline use."
            } catch {
                self.error = error.localizedDescription
                try? await repository.discard(info)
            }
        }
    }

    private func discard(_ info: DrugDatasetInfo) {
        candidate = nil
        Task { do { try await repository.discard(info) } catch { self.error = error.localizedDescription } }
    }

    private func openDetail(_ id: Int64) {
        Task { do { detail = try await repository.detail(id: id) } catch { self.error = error.localizedDescription } }
    }

    private func addComparison(_ id: Int64) {
        guard comparison.count < 5, !comparison.contains(where: { $0.id == id }) else { return }
        Task {
            do {
                let label = try await repository.detail(id: id)
                if comparison.count < 5, !comparison.contains(where: { $0.id == id }) { comparison.append(label) }
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct DrugLabelDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let label: DrugLabelDetail
    let dataset: DrugDatasetInfo?
    let onCompare: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("Label identity") {
                    ForEach(["generic_name", "manufacturer", "product_type", "route", "product_ndc", "set_id", "spl_id", "version", "source_updated_at"], id: \.self) { key in
                        if let value = label.fields[key], !value.isEmpty {
                            LabeledContent(key.replacingOccurrences(of: "_", with: " ").capitalized) { Text(value).textSelection(.enabled) }
                        }
                    }
                    if let dataset { Text("Dataset source: \(dataset.source)").font(.caption).foregroundStyle(.secondary) }
                }
                Section {
                    Text("These are imported label sections, shown without generated advice. Confirm that the product, formulation, route and label date match the medicine you have. Missing text does not establish safety.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                let matching = DrugConditionCatalog.matching(indications: label.fields["indications"] ?? "")
                if !matching.isEmpty {
                    Section("Situation terms found in this label") {
                        ForEach(matching) { condition in Text(condition.label) }
                        Text("Text matches only. Review the complete indications and warnings; a mention can be negated or qualified.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(DrugLabelDetail.sections, id: \.key) { section in
                    Section(section.title) {
                        if let text = label.fields[section.key], !text.isEmpty {
                            Text(text).textSelection(.enabled)
                        } else { Text("This section was not supplied in this label.").foregroundStyle(.secondary) }
                    }
                }
            }
            .navigationTitle(label.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("Add to comparison", systemImage: "rectangle.split.2x1") { onCompare(); dismiss() } }
            }
        }
    }
}

private struct DrugLabelComparisonView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var labels: [DrugLabelDetail]
    private let sections = DrugLabelDetail.sections.filter { ["boxed_warning", "warnings", "contraindications", "drug_interactions"].contains($0.key) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                Text("Compare the labels' own warning and interaction sections. This does not calculate interactions or tell you whether a combination is safe. A pharmacist or clinician can interpret the actual products and your circumstances.")
                    .font(.footnote).padding().foregroundStyle(.secondary)
                if labels.isEmpty {
                    ContentUnavailableView("No labels selected", systemImage: "rectangle.split.2x1",
                        description: Text("Use the plus button beside a search result to compare up to five labels."))
                } else {
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 16) {
                            ForEach(labels) { label in
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 16) {
                                        HStack(alignment: .top) {
                                            Text(label.title).font(.headline)
                                            Spacer()
                                            Button("Remove", systemImage: "xmark.circle") { labels.removeAll { $0.id == label.id } }.labelStyle(.iconOnly)
                                        }
                                        Text("Label date: \(label.fields["source_updated_at"].flatMap { $0.isEmpty ? nil : $0 } ?? "Not supplied")")
                                            .font(.caption).foregroundStyle(.secondary)
                                        ForEach(sections, id: \.key) { section in
                                            Text(section.title).font(.subheadline.bold())
                                            Text(label.fields[section.key].flatMap { $0.isEmpty ? nil : $0 } ?? "This section was not supplied in the selected label.")
                                                .font(.callout).textSelection(.enabled)
                                        }
                                    }.padding()
                                }.frame(width: 360).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                            }
                        }.padding()
                    }
                }
            }
            .navigationTitle("Compare label warnings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
