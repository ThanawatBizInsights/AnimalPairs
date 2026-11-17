import AVFoundation
import Combine
import SwiftUI
import UIKit

/// The approved opening video (Resources/Video/opening_video.mp4,
/// 720×1280 portrait, 8 s, H.264 + AAC). It has no text baked in; the title
/// and Play button stay native on Home.
enum OpeningVideo {
    static let resource = "opening_video"
    static let fileExtension = "mp4"
    /// Letterbox colour sampled from the video's own edges, so the bars blend in.
    static let backdrop = Color(red: 238 / 255, green: 223 / 255, blue: 215 / 255)
    /// Safety net: whatever happens, the child reaches Home after this long.
    static let maximumDuration: TimeInterval = 15

    static func url(in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: resource, withExtension: fileExtension)
    }
}

/// Plays the opening video once per app launch, then hands over to Home.
/// Always skippable; any failure simply continues.
struct OpeningVideoView: View {
    @Environment(AppModel.self) private var model
    @State private var player: AVPlayer?
    @State private var item: AVPlayerItem?
    @State private var finished = false

    var body: some View {
        let t = model.localizer
        ZStack(alignment: .topTrailing) {
            OpeningVideo.backdrop.ignoresSafeArea()

            if let player {
                PlayerLayerView(player: player)
                    .ignoresSafeArea()
                    .accessibilityElement()
                    .accessibilityLabel(Text(t["opening.a11y"]))
                    .accessibilityAddTraits(.isImage)
            }

            Button(action: finish) {
                Label(t["opening.skip"], systemImage: "forward.end.fill")
            }
            .buttonStyle(PillowButtonStyle(kind: .secondary))
            .padding(24)
            .accessibilityHint(Text(t["opening.skip.hint"]))
        }
        .onAppear(perform: start)
        .onDisappear { player?.pause() }
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { note in
            if let item, note.object as? AVPlayerItem === item { finish() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.failedToPlayToEndTimeNotification)) { note in
            if let item, note.object as? AVPlayerItem === item { finish() }
        }
        .task(id: item != nil) {
            // Playback that fails to load goes straight on to Home.
            guard let item else { return }
            for await status in item.publisher(for: \.status).values where status == .failed {
                finish()
                break
            }
        }
        .task {
            try? await Task.sleep(nanoseconds: UInt64(OpeningVideo.maximumDuration * 1_000_000_000))
            finish()
        }
    }

    private func start() {
        guard player == nil, !finished else { return }
        guard let url = OpeningVideo.url() else {
            finish()
            return
        }
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        // Video audio follows the Sound Effects / Music switches (and the
        // ambient session already respects the silent switch).
        player.isMuted = !model.openingVideoAudible
        player.volume = AudioManager.masterVolume
        player.preventsDisplaySleepDuringVideoPlayback = true
        self.item = item
        self.player = player
        model.audio.stopAll()            // nothing else plays over the video
        player.play()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        player?.pause()
        model.finishOpening()
    }
}

/// AVPlayerLayer host with aspect-fit scaling: the whole frame is always
/// visible, so no animal is cropped in any iPad orientation or window size.
private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: PlayerContainerView, context: Context) {
        view.playerLayer.player = player
    }
}

private final class PlayerContainerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
