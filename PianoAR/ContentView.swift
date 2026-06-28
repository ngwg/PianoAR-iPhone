import SwiftUI

enum AppMode { case virtualPiano, realPiano }

/// Minimal SwiftUI shell — everything user-facing happens in the AR scene.
/// The only on-screen UI is a setup hint at the bottom that appears while
/// the user is placing the keyboard or tapping corners during calibration.
struct ContentView: View {
    @StateObject private var session       = ARSessionModel()
    @StateObject private var placement     = PlacementManager()
    @StateObject private var calibration   = CalibrationManager()
    @StateObject private var handTracker   = HandTracker()
    @StateObject private var songPlayer    = SongPlayer()
    @StateObject private var pressDetector = PressDetector()
    @StateObject private var audioDetector = AudioPitchDetector()
    @StateObject private var keyTuning     = KeyTuning()

    @State private var mode: AppMode  = .virtualPiano
    @State private var showDebug      = false
    @State private var importedSongs: [Song] = []

    var body: some View {
        ZStack {
            ARPassthroughView(
                session: session, placement: placement,
                calibration: calibration, handTracker: handTracker,
                songPlayer: songPlayer, pressDetector: pressDetector,
                audioDetector: audioDetector, keyTuning: keyTuning,
                onTap: handleTap, onMenuAction: handleMenuAction,
                showDebug: showDebug,
                availableSongs: importedSongs
            )
            .ignoresSafeArea()

            // Setup-only hint — fades out as soon as setup is complete
            VStack {
                Spacer()
                bottomHint
                    .padding(.bottom, 36)
            }
        }
        .background(Color.black)
        .onAppear {
            if songPlayer.song == nil { loadBuiltInLesson() }
            audioDetector.start()
        }
        .onDisappear { audioDetector.stop() }
    }

    // MARK: - Setup hint (only shown during placement / calibration)

    @ViewBuilder
    private var bottomHint: some View {
        switch mode {
        case .virtualPiano:
            switch placement.state {
            case .scanning:    pill("Looking for a flat surface…")
            case .readyToPlace: pill("Tap a flat surface to place the keyboard")
            case .placed:      EmptyView()
            }
        case .realPiano:
            switch calibration.state {
            case .idle:
                button("Start calibration", "viewfinder", .blue) {
                    calibration.startCalibration()
                }
            case .collecting(let n):
                let labels = [
                    "Tap corner 1/4 — near-left",
                    "Tap corner 2/4 — near-right",
                    "Tap corner 3/4 — far-right",
                    "Tap corner 4/4 — far-left",
                ]
                pill(labels[min(n, 3)])
            case .done:
                EmptyView()
            }
        }
    }

    private func pill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 22).padding(.vertical, 12)
            .background(.black.opacity(0.72))
            .cornerRadius(14)
            .overlay(RoundedRectangle(cornerRadius: 14)
                .stroke(.white.opacity(0.10), lineWidth: 1))
    }

    private func button(_ label: String, _ icon: String, _ tint: Color,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 22).padding(.vertical, 12)
                .background(tint.opacity(0.85))
                .cornerRadius(14)
        }
    }

    // MARK: - Songs

    private func loadBuiltInLesson() {
        let bundled  = MIDIFileImporter.loadBundled(named: "right_hand_practice",
                                                     title: "Right Hand Primer")
        let fallback = Song.load(named: "right_hand_practice")
                    ?? Song.load(named: "sample_song")
        if let song = bundled ?? fallback { songPlayer.load(song) }
    }

    // MARK: - Tap & AR-menu routing

    private func handleTap(at point: CGPoint) {
        switch mode {
        case .virtualPiano: placement.handleTap(at: point)
        case .realPiano:    calibration.handleTap(at: point)
        }
    }

    private func handleMenuAction(_ action: MenuAction) {
        switch action {
        case .playStop:
            songPlayer.isPlaying ? songPlayer.stop() : songPlayer.play()
        case .restart:
            songPlayer.restart()
        case .loadAndPlay(let song):
            if let song { songPlayer.load(song) } else { loadBuiltInLesson() }
            songPlayer.play()
        case .toggleDebug:
            showDebug.toggle()
        }
    }
}
