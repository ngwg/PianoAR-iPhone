import SwiftUI

enum AppMode { case virtualPiano, realPiano }

/// Pure SwiftUI shell — every interactive surface lives in AR: mode selection
/// (LaunchSelectOverlay), keyboard placement / real-piano calibration
/// (GestureDetector.dwellPick + HandPointReticle + HintBarOverlay), the song
/// library, and playback controls (ARMenuOverlay). The phone is inside a
/// headset shell during normal use, so the touchscreen was never reachable —
/// there is no 2-D overlay drawn over the video feed at all.
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
    @State private var modeSelectionActive = true

    private var allSongs: [Song] { BuiltInSongs.all + importedSongs }

    var body: some View {
        ARPassthroughView(
            session: session, placement: placement,
            calibration: calibration, handTracker: handTracker,
            songPlayer: songPlayer, pressDetector: pressDetector,
            audioDetector: audioDetector, keyTuning: keyTuning,
            onMenuAction: handleMenuAction,
            showDebug: showDebug,
            availableSongs: allSongs,
            modeSelectionActive: modeSelectionActive,
            onModeSelected: selectMode
        )
        .ignoresSafeArea()
        .background(Color.black)
        .onAppear {
            if songPlayer.song == nil { songPlayer.load(BuiltInSongs.first) }
            audioDetector.start()
        }
        .onDisappear { audioDetector.stop() }
    }

    // MARK: - Mode selection

    private func selectMode(_ newMode: AppMode) {
        switchMode(to: newMode)
        modeSelectionActive = false
    }

    /// Tears down any existing keyboard placement and (re)initialises the chosen
    /// mode. Removing the old anchors here is what prevents a virtual keyboard and
    /// a calibrated overlay from coexisting after a mode change.
    private func switchMode(to newMode: AppMode) {
        if songPlayer.isPlaying { songPlayer.stop() }
        placement.reset(session: session)
        calibration.reset()
        mode = newMode
        if newMode == .realPiano { calibration.startCalibration() }
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
        case .changeMode:
            modeSelectionActive = true
        }
    }
}
