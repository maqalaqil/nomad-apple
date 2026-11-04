import AVKit
import SwiftUI
import Combine

@MainActor
struct LocalMediaPlayer: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var session: MediaPlaybackSession
    init(store: MediaLibraryStore, request: MediaPlaybackRequest) { _session = State(initialValue: MediaPlaybackSession(store: store, request: request)) }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let error = session.error {
                    ContentUnavailableView("Playback unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
                } else if session.preparing { ProgressView("Opening local media and restoring position…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if let player = session.player, let item = player.currentItem {
                    NativeMediaPlayer(player: player)
                        .onReceive(player.publisher(for: \.status)) { status in
                            if status == .failed { session.fail(player.error?.localizedDescription ?? "This media could not be played.", observedPlayer: player) }
                        }
                        .onReceive(item.publisher(for: \.status)) { status in
                            if status == .failed { session.fail(item.error?.localizedDescription ?? "This device could not decode this media.", observedPlayer: player) }
                        }
                        .onReceive(player.publisher(for: \.timeControlStatus)) { status in if status == .paused { session.save() } }
                        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime, object: item)) { notice in
                            session.fail((notice.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription ?? "Playback could not finish.", observedPlayer: player)
                        }
                }
                if let warning = session.saveWarning { Text(warning).font(.caption).foregroundStyle(.orange).padding() }
                HStack {
                    Button { session.previous() } label: { Label("Previous", systemImage: "backward.end") }.disabled(!session.hasPrevious)
                    Button("Start over") { session.restart() }.disabled(session.preparing)
                    Spacer()
                    if session.itemIDs.count > 1 {
                        Toggle("Auto-next", isOn: $session.autoAdvance).fixedSize()
                        Text("\(session.index + 1)/\(session.itemIDs.count)").font(.caption).foregroundStyle(.secondary)
                    }
                    Button { session.next() } label: { Label("Next", systemImage: "forward.end") }.disabled(!session.hasNext)
                }.padding()
                Text("Embedded captions and audio tracks appear in the player's controls when the file provides them. Playback pauses when this screen closes or the app enters the background.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal).padding(.bottom)
            }
            .navigationTitle(session.currentItem?.title ?? "Media playback")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { session.close(); dismiss() } } }
            .task { session.start() }
            .onChange(of: scenePhase) { _, phase in if phase == .background { session.pauseAndSave() } }
            .onDisappear { session.close() }
        }
    }
}

#if os(macOS)
@MainActor private struct NativeMediaPlayer: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = false
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { if view.player !== player { view.player = player } }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player = nil }
}
#else
@MainActor private struct NativeMediaPlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player; controller.showsPlaybackControls = true; controller.allowsPictureInPicturePlayback = false
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) { if controller.player !== player { controller.player = player } }
    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: ()) { controller.player = nil }
}

#endif
