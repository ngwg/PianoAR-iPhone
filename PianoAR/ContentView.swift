import SwiftUI

enum AppMode { case virtualPiano, realPiano }

/// Minimal SwiftUI shell. The AR scene carries all in-session UI; the only
/// 2-D SwiftUI surfaces are the launch mode-select screen and a small setup
/// hint shown while placing the keyboard or tapping calibration corners.
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

    // Launch / mode selection
    @State private var showModeSelect = true
    @State private var everSelected   = false

    private var allSongs: [Song] { BuiltInSongs.all + importedSongs }

    var body: some View {
        ZStack {
            ARPassthroughView(
                session: session, placement: placement,
                calibration: calibration, handTracker: handTracker,
                songPlayer: songPlayer, pressDetector: pressDetector,
                audioDetector: audioDetector, keyTuning: keyTuning,
                onTap: handleTap, onMenuAction: handleMenuAction,
                showDebug: showDebug,
                availableSongs: allSongs
            )
            .ignoresSafeArea()

            // Setup hint (placement / calibration) — hidden during mode select
            if !showModeSelect {
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

            // Launch / mode-select screen
            if showModeSelect {
                ModeSelectView(
                    canCancel: everSelected,
                    onSelect: { selectMode($0) },
                    onCancel: { withAnimation(.easeOut(duration: 0.28)) { showModeSelect = false } }
                )
                .transition(.opacity)
                .zIndex(10)
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
        everSelected = true
        withAnimation(.easeOut(duration: 0.30)) { showModeSelect = false }
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
            withAnimation(.easeOut(duration: 0.28)) { showModeSelect = true }
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
            case .scanning:     pill("Looking for a flat surface…")
            case .readyToPlace: pill("Tap a flat surface to place the keyboard")
            case .placed:       EmptyView()
            }
        case .realPiano:
            switch calibration.state {
            case .idle:
                actionPill("Start calibration", "viewfinder") { calibration.startCalibration() }
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
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.10), lineWidth: 1))
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

    // MARK: - Routing

    private func handleTap(at point: CGPoint) {
        guard !showModeSelect else { return }
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
            songPlayer.load(song ?? BuiltInSongs.first)
            songPlayer.play()
        case .toggleDebug:
            showDebug.toggle()
        }
    }
}

// MARK: - Mode-select launch screen

private struct ModeSelectView: View {
    let canCancel: Bool
    let onSelect: (AppMode) -> Void
    let onCancel: () -> Void

    @State private var appeared = false

    var body: some View {
        ZStack {
            // Dim + gradient backdrop over the live camera feed
            LinearGradient(
                colors: [.black.opacity(0.92), Color(red: 0.05, green: 0.03, blue: 0.16).opacity(0.92)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Title
                VStack(spacing: 8) {
                    Image(systemName: "pianokeys.inverse")
                        .font(.system(size: 44, weight: .regular))
                        .foregroundStyle(.white)
                    Text("PianoAR")
                        .font(.system(size: 34, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Choose how you want to play")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : -16)

                Spacer().frame(height: 44)

                // Mode cards
                HStack(spacing: 18) {
                    card(
                        mode: .virtualPiano,
                        icon: "rectangle.on.rectangle.angled",
                        title: "Virtual Piano",
                        blurb: "Place a full 88-key keyboard on a desk or table. No real piano needed.",
                        tint: Color(red: 0.20, green: 0.55, blue: 1.0),
                        delay: 0.05
                    )
                    card(
                        mode: .realPiano,
                        icon: "pianokeys",
                        title: "Real Piano",
                        blurb: "Tap the 4 corners of your real keyboard to overlay the note guide on it.",
                        tint: Color(red: 0.70, green: 0.35, blue: 1.0),
                        delay: 0.13
                    )
                }
                .padding(.horizontal, 28)

                Spacer()

                if canCancel {
                    Button(action: onCancel) {
                        Text("Cancel")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.6))
                            .padding(.vertical, 10).padding(.horizontal, 28)
                    }
                    .opacity(appeared ? 1 : 0)
                    .padding(.bottom, 18)
                }
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.8)) { appeared = true }
        }
    }

    private func card(mode: AppMode, icon: String, title: String, blurb: String,
                      tint: Color, delay: Double) -> some View {
        Button { onSelect(mode) } label: {
            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(tint.opacity(0.20))
                        .frame(width: 84, height: 84)
                    Image(systemName: icon)
                        .font(.system(size: 36, weight: .medium))
                        .foregroundStyle(tint)
                }
                Text(title)
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(.white)
                Text(blurb)
                    .font(.system(size: 12.5, weight: .regular))
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 26).padding(.horizontal, 16)
            .background(
                RoundedRectangle(cornerRadius: 22)
                    .fill(.white.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 22)
                        .stroke(tint.opacity(0.45), lineWidth: 1.5))
            )
        }
        .buttonStyle(PressableCardStyle())
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 26)
        .animation(.spring(response: 0.5, dampingFraction: 0.78).delay(delay), value: appeared)
    }
}

/// Scales a card down briefly while pressed for a tactile feel.
private struct PressableCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
