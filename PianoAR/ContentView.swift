import SwiftUI
import UniformTypeIdentifiers

enum AppMode { case virtualPiano, realPiano }

struct ContentView: View {
    @StateObject private var session       = ARSessionModel()
    @StateObject private var placement     = PlacementManager()
    @StateObject private var calibration   = CalibrationManager()
    @StateObject private var handTracker   = HandTracker()
    @StateObject private var songPlayer    = SongPlayer()
    @StateObject private var pressDetector = PressDetector()
    @StateObject private var audioDetector = AudioPitchDetector()
    @StateObject private var keyTuning     = KeyTuning()

    @State private var mode: AppMode = .virtualPiano
    @State private var vrMode        = false   // collapses to minimal HUD for headset use
    @State private var showDebug     = false
    @State private var showMIDIImporter = false
    @State private var showSongPicker   = false
    @State private var importedSongs: [Song] = []

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Full-screen AR passthrough
            ARPassthroughView(
                session: session, placement: placement,
                calibration: calibration, handTracker: handTracker,
                songPlayer: songPlayer, pressDetector: pressDetector,
                audioDetector: audioDetector, keyTuning: keyTuning,
                onTap: handleTap, onMenuAction: handleMenuAction
            )
            .ignoresSafeArea()

            // Left-side HUD panel (overlaid on AR)
            leftPanel
                .frame(width: 192)

            // Tuning panel — shown in setup mode only, at bottom-center
            if !vrMode && keyTuning.panelVisible {
                VStack {
                    Spacer()
                    tuningPanel
                        .padding(.leading, 200)
                        .padding(.bottom, 50)
                }
            }

            // Setup instructions — bottom-center in setup mode
            if !vrMode {
                VStack {
                    Spacer()
                    HStack { Spacer(); bottomInstructions; Spacer() }
                        .padding(.bottom, keyTuning.panelVisible ? 110 : 44)
                }
            }

            // Debug overlay — bottom-left, offset past the HUD panel
            if showDebug { debugOverlay }
        }
        .background(Color.black)
        .onAppear {
            if songPlayer.song == nil { loadBuiltInLesson() }
            audioDetector.start()
        }
        .onDisappear { audioDetector.stop() }
        .fileImporter(isPresented: $showMIDIImporter,
                      allowedContentTypes: Self.midiTypes,
                      allowsMultipleSelection: false,
                      onCompletion: importMIDI)
        .sheet(isPresented: $showSongPicker) {
            SongPickerView(
                importedSongs: importedSongs,
                loadBuiltIn:  { loadBuiltInLesson(); showSongPicker = false },
                loadImported: { song in songPlayer.load(song); showSongPicker = false },
                importMIDI:   { showSongPicker = false; showMIDIImporter = true }
            )
        }
    }

    // MARK: - Left panel

    private var leftPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusSection
                .padding(.top, 52)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)

            divider

            feedbackSection
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

            divider

            if !vrMode {
                setupSection
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)

                divider
            }

            Spacer(minLength: 0)

            bottomStrip
                .padding(.horizontal, 12)
                .padding(.bottom, 20)
        }
        .frame(maxHeight: .infinity)
        .background(.black.opacity(0.80))
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 14,
                topTrailingRadius: 14
            )
        )
        .ignoresSafeArea(edges: .top)
    }

    private var divider: some View {
        Rectangle()
            .fill(.white.opacity(0.12))
            .frame(height: 1)
    }

    // MARK: Status section

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("PianoAR")
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(.white.opacity(0.40))
                .kerning(2)

            statusRow(icon: "scope",
                      text: session.trackingStateDescription,
                      ok: session.trackingStateDescription.lowercased().contains("normal"))
            statusRow(icon: "sensor.tag.radiowaves.forward",
                      text: "LiDAR \(session.lidarAvailable ? "ON" : "off")",
                      ok: session.lidarAvailable)
            statusRow(icon: "hand.raised.fill",
                      text: handTracker.detectedHandCount > 0
                            ? "Hands: \(handTracker.detectedHandCount)"
                            : "No hands",
                      ok: handTracker.detectedHandCount > 0)
            statusRow(icon: "mic.fill",
                      text: audioDetector.microphoneState,
                      ok: audioDetector.microphoneState == "mic listening")
        }
    }

    private func statusRow(icon: String, text: String, ok: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundStyle(ok ? .green : .orange)
                .frame(width: 14)
            Text(text)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.90))
                .lineLimit(1)
        }
    }

    // MARK: Feedback section

    private var feedbackSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Song title
            Text(songPlayer.song?.title ?? "No song loaded")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.50))
                .lineLimit(2)

            // Progress row
            if !songPlayer.notes.isEmpty {
                HStack(spacing: 8) {
                    Label("\(songPlayer.acceptedCount)/\(songPlayer.notes.count)", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.green)
                    if songPlayer.mistakeCount > 0 {
                        Label("\(songPlayer.mistakeCount)", systemImage: "xmark.circle.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.red)
                    }
                }
            }

            // Current chord hint (large — most important during practice)
            if !songPlayer.chordLine.isEmpty {
                Text(songPlayer.chordLine)
                    .font(.system(size: 22, weight: .black, design: .rounded))
                    .foregroundStyle(.yellow)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
            }

            // Feedback line (correct / wrong)
            if !songPlayer.feedbackLine.isEmpty {
                Text(songPlayer.feedbackLine)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(songPlayer.feedbackLine.contains("✓") ? .green : .red)
                    .lineLimit(2)
            } else if !songPlayer.scoreLine.isEmpty {
                Text(songPlayer.scoreLine)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
            }

            // Press detection echo
            let echo = pressDetector.lastDetected.isEmpty ? audioDetector.lastDetected : pressDetector.lastDetected
            if !echo.isEmpty {
                Text(pressDetector.lastDetected.isEmpty ? "Mic: \(echo)" : "Vision: \(echo)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.cyan.opacity(0.75))
                    .lineLimit(1)
            }
        }
    }

    // MARK: Setup section (hidden in VR mode)

    private var setupSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SETUP")
                .font(.system(size: 9, weight: .black))
                .foregroundStyle(.white.opacity(0.35))
                .kerning(1.5)

            // Mode selector
            HStack(spacing: 0) {
                modeButton("Virtual", active: mode == .virtualPiano) {
                    mode = .virtualPiano
                }
                modeButton("Real Piano", active: mode == .realPiano) {
                    mode = .realPiano
                    if calibration.state == .idle { calibration.startCalibration() }
                }
            }
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.20), lineWidth: 1))

            // Play / Stop — largest button
            Button {
                if songPlayer.isPlaying { songPlayer.stop() } else { songPlayer.play() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: songPlayer.isPlaying ? "stop.fill" : "play.fill")
                        .font(.system(size: 14, weight: .bold))
                    Text(songPlayer.isPlaying ? "Stop" : "Practice")
                        .font(.system(size: 14, weight: .bold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(songPlayer.isPlaying ? Color.red.opacity(0.80) : Color.blue.opacity(0.80))
                .foregroundStyle(.white)
                .cornerRadius(10)
            }

            // Utility buttons row
            HStack(spacing: 6) {
                iconButton(icon: "music.note.list", label: "Songs")   { showSongPicker   = true }
                iconButton(icon: "square.and.arrow.down", label: "MIDI") { showMIDIImporter = true }
                iconButton(icon: "slider.horizontal.3", label: "Tune",
                           active: keyTuning.panelVisible)             { keyTuning.panelVisible.toggle() }
            }
        }
    }

    // MARK: Bottom strip (always visible)

    private var bottomStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Debug toggle
            Button {
                showDebug.toggle()
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(showDebug ? Color.green : Color.white.opacity(0.25))
                        .frame(width: 7, height: 7)
                    Text(showDebug ? "Debug ON" : "Debug")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }

            // VR mode toggle — prominent
            Button {
                withAnimation(.easeInOut(duration: 0.22)) { vrMode.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: vrMode ? "eye.slash.fill" : "eye.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text(vrMode ? "Exit VR" : "Enter VR")
                        .font(.system(size: 13, weight: .bold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(vrMode ? Color.purple.opacity(0.80) : Color.white.opacity(0.16))
                .foregroundStyle(.white)
                .cornerRadius(10)
            }
        }
    }

    // MARK: Helpers

    private func modeButton(_ label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity)
                .background(active ? Color.white.opacity(0.25) : Color.clear)
                .foregroundStyle(.white)
        }
    }

    private func iconButton(icon: String, label: String, active: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                Text(label)
                    .font(.system(size: 8, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(active ? Color.green.opacity(0.45) : Color.white.opacity(0.13))
            .foregroundStyle(.white)
            .cornerRadius(8)
        }
    }

    // MARK: Tuning panel

    private var tuningPanel: some View {
        let keyIndex = songPlayer.expectedKeyIndexNow()
        return VStack(spacing: 6) {
            Text(keyTuning.status(for: keyIndex))
                .font(.caption.bold())
            HStack(spacing: 6) {
                tuneButton("◀ Left")  { keyTuning.adjustX(for: keyIndex, by: -0.002) }
                tuneButton("Right ▶") { keyTuning.adjustX(for: keyIndex, by: 0.002) }
                tuneButton("Narrow")  { keyTuning.adjustWidth(for: keyIndex, by: -0.0015) }
                tuneButton("Wider")   { keyTuning.adjustWidth(for: keyIndex, by: 0.0015) }
                tuneButton("Reset")   { keyTuning.reset(keyIndex: keyIndex) }
            }
        }
        .padding(10)
        .background(.black.opacity(0.82))
        .foregroundStyle(.white)
        .cornerRadius(10)
    }

    private func tuneButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption2.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.18))
                .foregroundStyle(.white)
                .cornerRadius(6)
        }
    }

    // MARK: Debug overlay

    private var debugOverlay: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("── Press ──")
                .font(.caption.bold())
            ForEach(pressDetector.fingerDebugLines, id: \.self) {
                Text($0).font(.system(size: 9, design: .monospaced))
            }
            Text("── Mic ──")
                .font(.caption.bold())
                .padding(.top, 4)
            ForEach(audioDetector.fingerDebugLines, id: \.self) {
                Text($0).font(.system(size: 9, design: .monospaced))
            }
        }
        .padding(8)
        .background(.black.opacity(0.78))
        .foregroundStyle(.green)
        .cornerRadius(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(.leading, 200)
        .padding(.bottom, 8)
    }

    // MARK: Bottom instructions (setup mode, real/virtual paths)

    @ViewBuilder
    private var bottomInstructions: some View {
        switch mode {
        case .virtualPiano: virtualPianoInstructions
        case .realPiano:    realPianoInstructions
        }
    }

    @ViewBuilder
    private var virtualPianoInstructions: some View {
        switch placement.state {
        case .scanning:
            instructionLabel("Scanning for flat surface…")
        case .readyToPlace:
            instructionLabel("Tap a flat surface to place the keyboard")
        case .placed:
            Button { placement.reset(session: session) } label: {
                Text("Remove keyboard")
                    .font(.caption.bold())
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(.red.opacity(0.78))
                    .foregroundStyle(.white)
                    .cornerRadius(10)
            }
        }
    }

    @ViewBuilder
    private var realPianoInstructions: some View {
        switch calibration.state {
        case .idle:
            Button { calibration.startCalibration() } label: {
                Text("Start calibration")
                    .font(.caption.bold())
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(.red.opacity(0.78))
                    .foregroundStyle(.white)
                    .cornerRadius(10)
            }
        case .collecting(let count):
            let labels = [
                "Tap corner 1/4 — near-left",
                "Tap corner 2/4 — near-right",
                "Tap corner 3/4 — far-right",
                "Tap corner 4/4 — far-left",
            ]
            instructionLabel(labels[min(count, 3)])
        case .done:
            Button { calibration.reset() } label: {
                Text("Redo calibration")
                    .font(.caption.bold())
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(.orange.opacity(0.78))
                    .foregroundStyle(.white)
                    .cornerRadius(10)
            }
        }
    }

    private func instructionLabel(_ text: String) -> some View {
        Text(text)
            .font(.headline)
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.black.opacity(0.62))
            .cornerRadius(10)
    }

    // MARK: MIDI import

    private static var midiTypes: [UTType] {
        [
            UTType(filenameExtension: "mid")  ?? .data,
            UTType(filenameExtension: "midi") ?? .data,
        ]
    }

    private func importMIDI(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let data  = try Data(contentsOf: url)
            let title = url.deletingPathExtension().lastPathComponent
            let song  = try MIDIFileImporter.song(from: data, title: title)
            importedSongs.append(song)
            songPlayer.load(song)
        } catch {
            songPlayer.feedbackLine = error.localizedDescription
        }
    }

    private func loadBuiltInLesson() {
        let bundled  = MIDIFileImporter.loadBundled(named: "right_hand_practice",
                                                     title: "Right Hand Primer")
        let fallback = Song.load(named: "right_hand_practice")
                    ?? Song.load(named: "sample_song")
        if let song = bundled ?? fallback { songPlayer.load(song) }
    }

    // MARK: Tap / menu routing

    private func handleTap(at point: CGPoint) {
        switch mode {
        case .virtualPiano: placement.handleTap(at: point)
        case .realPiano:    calibration.handleTap(at: point)
        }
    }

    private func handleMenuAction(_ action: MenuAction) {
        switch action {
        case .playStop: songPlayer.isPlaying ? songPlayer.stop() : songPlayer.play()
        case .restart:  songPlayer.restart()
        case .nextSong: advanceToNextSong()
        }
    }

    private func advanceToNextSong() {
        let allSongs: [Song?] = [nil] + importedSongs.map { Optional($0) }
        let currentTitle = songPlayer.song?.title
        let currentIdx   = allSongs.firstIndex { $0?.title == currentTitle } ?? 0
        let nextIdx      = (currentIdx + 1) % allSongs.count
        if let next = allSongs[nextIdx] { songPlayer.load(next) } else { loadBuiltInLesson() }
    }
}

// MARK: - Song picker sheet

private struct SongPickerView: View {
    let importedSongs: [Song]
    let loadBuiltIn:  () -> Void
    let loadImported: (Song) -> Void
    let importMIDI:   () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("Built in") {
                    Button("Right Hand Primer") { loadBuiltIn() }
                }
                Section("Imported MIDI") {
                    if importedSongs.isEmpty {
                        Text("No imported MIDI yet").foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(importedSongs.enumerated()), id: \.offset) { item in
                            Button(item.element.title ?? "Imported MIDI") { loadImported(item.element) }
                        }
                    }
                    Button { importMIDI() } label: {
                        Label("Import MIDI", systemImage: "square.and.arrow.down")
                    }
                }
            }
            .navigationTitle("Songs")
        }
    }
}
