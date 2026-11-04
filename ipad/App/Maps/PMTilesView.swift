import SwiftUI
import UniformTypeIdentifiers

struct PMTilesView: View {
    @StateObject private var store = PMTilesStore.shared
    @StateObject private var controller = PMTilesMapController()
    @State private var importing = false
    @State private var managing = false
    @State private var adding = false
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var placeName = ""
    @State private var notes = ""
    @State private var pendingDelete: PMTilesArchive?
    @State private var pendingPlaceDelete: PMTilesSavedPlace?

    private var assets: URL? {
        guard let root = Bundle.main.resourceURL else { return nil }
        let directory = root.appendingPathComponent("WebTools/Maps", isDirectory: true)
        return FileManager.default.fileExists(atPath: directory.appendingPathComponent("index.html").path) ? directory : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if let assets {
                PMTilesWebView(assets: assets, store: store, controller: controller)
            } else {
                ContentUnavailableView("Map assets not bundled", systemImage: "map", description: Text("Run ipad/scripts/fetch-map-assets.py, then rebuild the app. Imported map archives stay on this iPad."))
            }
            HStack {
                if store.importing { ProgressView(); Text("Copying archive…") }
                else { Text(controller.status).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if let lat = controller.selectedLatitude, let lon = controller.selectedLongitude {
                    Button("Save tapped place") { latitude = String(format: "%.6f", lat); longitude = String(format: "%.6f", lon); adding = true }
                }
            }.padding(10).background(.bar)
        }
        .navigationTitle("Offline Map Archives")
        .toolbar {
            Button("Coordinates", systemImage: "mappin.and.ellipse") { adding = true }
            Button("Archives & Places", systemImage: "map") { managing = true }
            Button("Import", systemImage: "square.and.arrow.down") { importing = true }.disabled(store.importing)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            do { let urls = try result.get(); Task { await store.importFiles(urls) } }
            catch { store.error = error.localizedDescription }
        }
        .sheet(isPresented: $managing) { management }
        .sheet(isPresented: $adding) { coordinateForm }
        .alert("Map issue", isPresented: Binding(get: { store.error != nil || controller.error != nil }, set: { if !$0 { store.error = nil; controller.error = nil } })) {
            Button("OK") { store.error = nil; controller.error = nil }
        } message: { Text(store.error ?? controller.error ?? "") }
    }

    private var management: some View {
        NavigationStack {
            List {
                Section {
                    Text("Import PMTiles version 3 archives from Files. NOMAD/Protomaps vector maps and raster maps render locally. Enable a world archive and regional archives together for broader coverage. Map content is not included with the app.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Import archive files", systemImage: "square.and.arrow.down") { managing = false; importing = true }
                }
                Section("Imported archives") {
                    if store.archives.isEmpty { Text("No imported archives").foregroundStyle(.secondary) }
                    ForEach(store.archives) { archive in
                        HStack {
                            Toggle(isOn: Binding(get: { archive.enabled }, set: { store.setEnabled(archive.id, enabled: $0) })) {
                                VStack(alignment: .leading) {
                                    Text(archive.name)
                                    Text("\(ByteCountFormatter.string(fromByteCount: Int64(archive.byteCount), countStyle: .file)) · zoom \(archive.header.minZoom)–\(archive.header.maxZoom)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Button { controller.fly(latitude: archive.header.centerLatitude, longitude: archive.header.centerLongitude); managing = false } label: { Image(systemName: "scope") }.buttonStyle(.borderless).accessibilityLabel("Go to archive center")
                            Button(role: .destructive) { pendingDelete = archive } label: { Image(systemName: "trash") }.buttonStyle(.borderless).accessibilityLabel("Delete imported archive")
                        }
                    }
                }
                Section("Saved places") {
                    if store.places.isEmpty { Text("Tap the map or enter coordinates to save a place.").foregroundStyle(.secondary) }
                    ForEach(store.places) { place in
                        HStack {
                            Button { controller.fly(latitude: place.latitude, longitude: place.longitude); managing = false } label: {
                                VStack(alignment: .leading) {
                                    Text(place.name)
                                    Text(String(format: "%.6f, %.6f", place.latitude, place.longitude)).font(.caption)
                                    if !place.notes.isEmpty { Text(place.notes).font(.caption).foregroundStyle(.secondary) }
                                }
                            }.buttonStyle(.plain)
                            Spacer()
                            Button(role: .destructive) { pendingPlaceDelete = place } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                        }
                    }
                }
                Section("Offline scope") {
                    Text("Coordinate search and saved pins work without internet. Address search, turn-by-turn routing, and automatic region extraction are not included. Other vector schemas need a compatible style. Unsupported compression is reported during import.").font(.footnote).foregroundStyle(.secondary)
                }
            }.navigationTitle("Archives & Places").toolbar { Button("Done") { managing = false } }
        }
        .confirmationDialog("Delete imported archive?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Delete app copy", role: .destructive) { if let archive = pendingDelete { store.remove(archive) }; pendingDelete = nil }
        } message: { Text("The original file in Files is kept. Saved places are kept.") }
        .confirmationDialog("Delete saved place?", isPresented: Binding(get: { pendingPlaceDelete != nil }, set: { if !$0 { pendingPlaceDelete = nil } }), titleVisibility: .visible) {
            Button("Delete place", role: .destructive) { if let place = pendingPlaceDelete { store.removePlace(place.id) }; pendingPlaceDelete = nil }
        } message: { Text("This removes the saved pin and its notes from this iPad.") }
    }

    private var coordinateForm: some View {
        NavigationStack {
            Form {
                Section("Coordinates") {
                    TextField("Latitude, −90 to 90", text: $latitude).keyboardType(.numbersAndPunctuation)
                    TextField("Longitude, −180 to 180", text: $longitude).keyboardType(.numbersAndPunctuation)
                    Button("Go to coordinates") {
                        guard let point = validPoint else { store.error = "Enter a valid latitude and longitude."; return }
                        controller.fly(latitude: point.0, longitude: point.1); adding = false
                    }.disabled(validPoint == nil)
                }
                Section("Save place") {
                    TextField("Name", text: $placeName)
                    TextField("Notes", text: $notes, axis: .vertical).lineLimit(3...7)
                    Button("Save on this iPad") {
                        guard let point = validPoint else { return }
                        store.addPlace(name: placeName, notes: notes, latitude: point.0, longitude: point.1)
                        controller.fly(latitude: point.0, longitude: point.1); placeName = ""; notes = ""; adding = false
                    }.disabled(validPoint == nil)
                }
            }.navigationTitle("Coordinates").toolbar { Button("Cancel") { adding = false } }
        }
    }

    private var validPoint: (Double, Double)? {
        guard let lat = Double(latitude.trimmingCharacters(in: .whitespacesAndNewlines)), let lon = Double(longitude.trimmingCharacters(in: .whitespacesAndNewlines)), (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        return (lat, lon)
    }
}
