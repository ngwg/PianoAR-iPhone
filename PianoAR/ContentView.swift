import SwiftUI

/// Pure SwiftUI shell over the AR view. Real-piano mode only: on launch the
/// app goes straight into 4-corner calibration — tap the screen at each corner
/// of the real keyboard (raycast against LiDAR-detected surfaces). Everything
/// after calibration (song library, playback controls, recalibrate) lives in
/// the AR menu panel.
struct ContentView: View {
    @StateObject private var session       = ARSessionModel()
    @StateObject private var calibration   = CalibrationManager()
    @StateObject private var handTracker   = HandTracker()
    @StateObject private var songPlayer    = SongPlayer()
    @StateObject private var pressDetector = PressDetector()
    @StateObject private var audioDetector = AudioPitchDetector()
    @StateObject private var keyTuning     = KeyTuning()

    @State private var showDebug = false
    @State private var importedSongs: [Song] = []

    private var allSongs: [Song] { BuiltInSongs.all + importedSongs }

    var body: some View {
        ARPassthroughView(
            session: session,
            calibration: calibration, handTracker: handTracker,
            songPlayer: songPlayer, pressDetector: pressDetector,
            audioDetector: audioDetector, keyTuning: keyTuning,
            onMenuAction: handleMenuAction,
            showDebug: showDebug,
            availableSongs: allSongs
        )
        .ignoresSafeArea()
        .background(Color.black)
        .onAppear {
            if songPlayer.song == nil { songPlayer.load(BuiltInSongs.first) }
            if calibration.state == .idle { calibration.startCalibration() }
            audioDetector.start()
        }
        .onDisappear { audioDetector.stop() }
    }

    // MARK: - AR menu routing

    private func handleMenuAction(_ action: MenuAction) {
        switch action {
        case .playStop:
            songPlayer.isPlaying ? songPlayer.stop() : songPlayer.play()
        case .restart:
            songPlayer.restart()
        case .loadAndPlay(let song):
            songPlayer.load(song ?? BuiltInSongs.first)
            songPlayer.play()
        case .toggleDebug:
            showDebug.toggle()
        case .recalibrate:
            if songPlayer.isPlaying { songPlayer.stop() }
            calibration.startCalibration()
        }
    }
}
