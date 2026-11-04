import SwiftUI

struct DrugSituationPicker: View {
    @Binding var selection: DrugSituationSelection
    @Environment(\.dismiss) private var dismiss
    @State private var filter = ""
    @State private var custom = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Choose up to eight groups. A matching OTC label must contain a term from every selected group in its indications section. Synonyms within a group are alternatives.")
                    Text("Selected: \(selection.count) of 8").font(.headline)
                    if let error { Text(error).foregroundStyle(.orange) }
                }
                Section("Add a literal text group") {
                    TextField("Words to find together, up to 200 characters", text: $custom).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Add text group", systemImage: "plus") {
                        do { try selection.addCustom(custom); custom = ""; error = nil }
                        catch { self.error = error.localizedDescription }
                    }.disabled(custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selection.count >= DrugSituationSelection.maximumGroups)
                    ForEach(selection.customTerms, id: \.self) { term in
                        HStack {
                            Text(term)
                            Spacer()
                            Button("Remove \(term)", systemImage: "xmark.circle") { selection.customTerms.removeAll { $0 == term } }.labelStyle(.iconOnly)
                        }
                    }
                }
                ForEach(DrugConditionCatalog.categories, id: \.self) { category in
                    let conditions = DrugConditionCatalog.conditions.filter { condition in
                        condition.category == category && (filter.isEmpty || ([condition.label] + condition.searchTerms).contains { $0.localizedCaseInsensitiveContains(filter) })
                    }
                    if !conditions.isEmpty {
                        Section(category) {
                            ForEach(conditions) { condition in
                                Button {
                                    do { try selection.toggle(condition.id); error = nil }
                                    catch { self.error = error.localizedDescription }
                                } label: {
                                    HStack(alignment: .top) {
                                        Image(systemName: selection.conditionIDs.contains(condition.id) ? "checkmark.circle.fill" : "circle")
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(condition.label).foregroundStyle(.primary)
                                            Text(condition.searchTerms.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }.disabled(selection.count >= DrugSituationSelection.maximumGroups && !selection.conditionIDs.contains(condition.id))
                                    .accessibilityValue(selection.conditionIDs.contains(condition.id) ? "Selected" : "Not selected")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Situation search groups")
            .searchable(text: $filter, prompt: "Find a situation or search term")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
