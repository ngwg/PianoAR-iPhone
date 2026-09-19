import Combine
import SwiftUI
import UIKit
import simd

/// Pure SwiftUI shell over the AR view. Real-piano mode: on launch the app
/// goes straight into keyboard calibration (auto-detect, fingertips on the
/// two end keys, or 4 corner taps). Everything after that — library,
/// practice controls, comfort settings, setup — lives in the AR menu panel.
///
/// The detector objects deliberately publish nothing per-frame: this view
/// only re-renders on real state changes (menu actions, comfort settings),
/// not 30+ times a second.
struct ContentView: View {
    @StateObject private var session       = ARSessionModel()
    @StateObject private var calibration   = CalibrationManager()
    @StateObject private var handTracker   = HandTracker()
    @StateObject private var songPlayer    = SongPlayer()
    @StateObject private var pressDetector = PressDetector()
    @StateObject private var audioDetector = AudioPitchDetector()
    @StateObject private var keyTuning     = KeyTuning()
    @StateObject private var comfort       = ComfortSettings()

    @State private var showDebug = false
    @AppStorage("ui.keyLabels") private var showKeyLabels = true
    @State private var nudge = SIMD2<Float>(0, 0)
    @State private var importedSongs: [Song] = []
    @State private var savedBrightness: CGFloat?

    private var allSongs: [Song] { BuiltInSongs.all + importedSongs }

    var body: some View {
        ARPassthroughView(
            session: session,
            calibration: calibration, handTracker: handTracker,
            songPlayer: songPlayer, pressDetector: pressDetector,
            audioDetector: audioDetector, keyTuning: keyTuning,
            comfort: comfort.snapshot,
            onMenuAction: handleMenuAction,
            showDebug: showDebug,
            showKeyLabels: showKeyLabels,
            keyboardNudge: nudge,
            availableSongs: allSongs
        )
        .ignoresSafeArea()
        .background(Color.black)
        .onAppear {
            // The phone lives inside a headset shell — never let the screen
            // dim or lock mid-practice, and don't let auto-brightness (which
            // sees darkness inside the shell) dim the passthrough.
            UIApplication.shared.isIdleTimerDisabled = true
            if let screen = currentScreen {
                savedBrightness = screen.brightness
                screen.brightness = max(screen.brightness, 0.85)
            }
            LabelFactory.prewarm()
            importedSongs = SongLibrary.loadImported()
            if songPlayer.song == nil { songPlayer.load(BuiltInSongs.first) }
            if calibration.state == .idle { calibration.startCalibration() }
            audioDetector.start()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            if let b = savedBrightness { currentScreen?.brightness = b }
            audioDetector.stop()
        }
        .onOpenURL { url in
            // "Open in PianoAR" / AirDrop of a MIDI file.
            if SongLibrary.importFile(at: url) {
                importedSongs = SongLibrary.loadImported()
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.willEnterForegroundNotification)) { _ in
            // Picks up files dropped into the app folder via the Files app.
            importedSongs = SongLibrary.loadImported()
        }
    }

    private var currentScreen: UIScreen? {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.screen }
            .first
    }

    // MARK: - AR menu routing

    private func handleMenuAction(_ action: MenuAction) {
        switch action {
        case .playStop:
            if songPlayer.isPlaying {
                songPlayer.stop()
            } else if songPlayer.isComplete || songPlayer.song == nil {
                songPlayer.restart()
            } else {
                songPlayer.play()
            }
        case .restart:
            songPlayer.restart()
        case .skip:
            songPlayer.skipGroup()
        case .loadAndPlay(let song):
            songPlayer.load(song ?? BuiltInSongs.first)
            pressDetector.reset()
            songPlayer.play()
        case .toggleDebug:
            showDebug.toggle()
        case .recalibrate:
            if songPlayer.isPlaying { songPlayer.stop() }
            nudge = .zero
            pressDetector.reset()
            calibration.startCalibration()
        case .tempo(let delta):
            songPlayer.setTempo(scale: songPlayer.tempoScale + delta)
        case .cycleHand:
            songPlayer.setHand(songPlayer.practiceHand.next)
        case .toggleWaitMode:
            songPlayer.setWaitMode(!songPlayer.waitMode)
        case .viewScale(let delta):
            comfort.adjustViewScale(by: delta)
        case .lensSpacing(let delta):
            comfort.adjustLensSpacing(by: delta)
        case .toggleSmoothing:
            comfort.toggleMotionSmoothing()
        case .toggleStereo:
            comfort.toggleStereoMode()
        case .cycleHandStyle:
            comfort.cycleHandStyle()
        case .resetComfort:
            comfort.resetViewDefaults()
        case .nudge(let x, let z):
            nudge += SIMD2<Float>(x, z)
            nudge = simd_clamp(nudge, SIMD2<Float>(repeating: -0.05), SIMD2<Float>(repeating: 0.05))
        case .toggleKeyLabels:
            showKeyLabels.toggle()
        }
    }
}
