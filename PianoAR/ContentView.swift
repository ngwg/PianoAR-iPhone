import SwiftUI

enum AppMode { case virtualPiano, realPiano }

/// Minimal SwiftUI shell. Every interactive surface — mode selection, keyboard
/// placement, real-piano calibration, the song library, playback controls — is
/// hand-driven and rendered in AR (see LaunchSelectOverlay / ARMenuOverlay /
/// GestureDetector.pointAndConfirm). The phone is inside a headset shell during
/// normal use, so the touchscreen was never reachable; the only 2-D SwiftUI
/// surface left is a small always-safe setup hint at the bottom.
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

    // The AR launch picker is active until a mode is chosen; re-openable later
    // via the top-left chip.
    @State private var modeSelectionActive = true

    private var allSongs: [Song] { BuiltInSongs.all + importedSongs }

    var body: some View {
        ZStack {
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

            if !modeSelectionActive {
                VStack {
                    HStack {
                        modeButton
                        Spacer()
                    }
                    Spacer()
                    bottomHint
                        .padding(.bottom, 36)
                }
                .padding(.top, 16)
                .padding(.horizontal, 16)
                .transition(.opacity)
            }
        }
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
        withAnimation(.easeOut(duration: 0.25)) { modeSelectionActive = false }
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

    private var modeButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.22)) { modeSelectionActive = true }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: mode == .virtualPiano ? "rectangle.on.rectangle" : "pianokeys")
                    .font(.system(size: 12, weight: .bold))
                Text(mode == .virtualPiano ? "Virtual" : "Real Piano")
                    .font(.system(size: 13, weight: .bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(.black.opacity(0.55))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
        }
    }

    // MARK: - Setup hint

    @ViewBuilder
    private var bottomHint: some View {
        switch mode {
        case .virtualPiano:
            switch placement.state {
            case .scanning:
                pill("Looking for a flat surface…")
            case .readyToPlace:
                pill("Point at the table, pinch your other hand to place")
            case .placed:
                EmptyView()
            }
        case .realPiano:
            switch calibration.state {
            case .idle:
                actionPill("Start calibration", "viewfinder") { calibration.startCalibration() }
            case .collecting(let n):
                let labels = [
                    "Point at corner 1/4 (near-left) — pinch other hand to confirm",
                    "Point at corner 2/4 (near-right) — pinch other hand to confirm",
                    "Point at corner 3/4 (far-right) — pinch other hand to confirm",
                    "Point at corner 4/4 (far-left) — pinch other hand to confirm",
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
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.10), lineWidth: 1))
            .multilineTextAlignment(.center)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func actionPill(_ label: String, _ icon: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 22).padding(.vertical, 12)
                .background(Color(red: 0.13, green: 0.46, blue: 0.96).opacity(0.9))
                .cornerRadius(14)
        }
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
        }
    }
}
