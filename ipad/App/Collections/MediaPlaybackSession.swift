import AVFoundation
import Foundation
import Observation

struct MediaPlaybackRequest: Identifiable {
    let id = UUID()
    let itemIDs: [UUID]
    let startID: UUID
}

@MainActor @Observable
final class MediaPlaybackSession {
    let store: MediaLibraryStore
    let itemIDs: [UUID]
    private(set) var index: Int
    private(set) var player: AVPlayer?
    private(set) var preparing = false
    private(set) var error: String?
    private(set) var saveWarning: String?
    var autoAdvance = true
    @ObservationIgnored private var preparation: Task<Void, Never>?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var token = UUID()
    @ObservationIgnored private var readyForProgress = false
    @ObservationIgnored private var started = false
    var currentItem: LocalMediaItem? { itemIDs.indices.contains(index) ? store.item(itemIDs[index]) : nil }
    var hasNext: Bool { index + 1 < itemIDs.count }
    var hasPrevious: Bool { index > 0 }
    init(store: MediaLibraryStore, request: MediaPlaybackRequest) {
        self.store = store; itemIDs = request.itemIDs
        index = request.itemIDs.firstIndex(of: request.startID) ?? 0
    }
    func start() { guard !started else { return }; started = true; open(index) }
    func next() { if hasNext { open(index + 1) } }
    func previous() { if hasPrevious { open(index - 1) } }
    func restart() { open(index, restart: true) }
    func fail(_ message: String, observedPlayer: AVPlayer) { guard player === observedPlayer else { return }; error = message; player?.pause(); save() }
    func pauseAndSave() { player?.pause(); save() }
    func save(completed: Bool? = nil) {
        guard readyForProgress, let player, let item = currentItem else { return }
        let seconds = completed == true ? (item.duration ?? CMTimeGetSeconds(player.currentTime())) : CMTimeGetSeconds(player.currentTime())
        do { try store.recordPlayback(item.id, position: seconds, completed: completed) }
        catch { saveWarning = "Playback progress could not be saved: \(error.localizedDescription)" }
    }
    func close() {
        pauseAndSave(); preparation?.cancel(); preparation = nil; token = UUID()
        cleanup(); preparing = false
    }
    private func open(_ nextIndex: Int, restart: Bool = false) {
        guard itemIDs.indices.contains(nextIndex) else { return }
        pauseAndSave(); preparation?.cancel(); cleanup()
        index = nextIndex; error = nil; saveWarning = nil; preparing = true
        let attempt = UUID(); token = attempt
        preparation = Task {
            do {
                guard let item = currentItem else { throw CollectionStorage.StorageError.invalidDocument("This playlist item was removed from the library.") }
                let url = try store.fileURL(item)
                let metadata = try await LocalMediaMetadata.read(url)
                try Task.checkCancellation()
                guard token == attempt else { return }
                do { try store.updateMetadata(item.id, metadata: metadata) }
                catch { saveWarning = "Media metadata could not be saved: \(error.localizedDescription)" }
                let next = AVPlayer(url: url)
                next.allowsExternalPlayback = false
                player = next
                let position = restart || item.completed ? 0 : min(item.position, max(0, metadata.duration - 0.1))
                if position > 0 {
                    let moved = await next.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                    guard moved else { throw CollectionStorage.StorageError.invalidDocument("The saved playback position could not be restored.") }
                }
                try Task.checkCancellation()
                guard token == attempt else { return }
                readyForProgress = true; preparing = false
                do { try store.recordPlayback(item.id, position: position, completed: false) }
                catch { saveWarning = "Playback progress could not be saved: \(error.localizedDescription)" }
                timeObserver = next.addPeriodicTimeObserver(forInterval: CMTime(seconds: 5, preferredTimescale: 600), queue: .main) { [weak self] _ in
                    Task { @MainActor in guard let self, self.token == attempt else { return }; self.save() }
                }
                endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: next.currentItem, queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.token == attempt else { return }
                        self.save(completed: true)
                        if self.autoAdvance && self.hasNext { self.next() }
                    }
                }
                next.play()
            } catch is CancellationError {
                if token == attempt { preparing = false }
            } catch {
                if token == attempt { self.error = error.localizedDescription; preparing = false; cleanup() }
            }
        }
    }
    private func cleanup() {
        readyForProgress = false
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player?.pause(); player?.replaceCurrentItem(with: nil); player = nil
    }
}
