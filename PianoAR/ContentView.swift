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
    @State private var vrMode        = false
    @State private var showDebug     = false
    @State private var showMIDIImporter = false
    @State private var showSongPicker   = false
    @State private var importedSongs: [Song] = []

    var body: some View {
        ZStack(alignment: .trailing) {
            // ── Full-screen AR ─────────────────────────────────────────────
            ARPassthroughView(
                session: session, placement: placement,
                calibration: calibration, handTracker: handTracker,
                songPlayer: songPlayer, pressDetector: pressDetector,
                audioDetector: audioDetector, keyTuning: keyTuning,
                onTap: handleTap, onMenuAction: handleMenuAction
            )
            .ignoresSafeArea()

            // ── Right control panel ─────────────────────────────────────────
            if !vrMode {
                rightPanel
                    .frame(width: 220)
                    .transition(.move(edge: .trailing))
            }

            // ── Setup instructions (bottom centre, clear of panel) ──────────
            if !vrMode {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        bottomInstructions
                        Spacer(minLength: 230)
                    }
                    .padding(.bottom, 44)
                }
            }

            // ── VR minimal overlay (top-left, tiny) ─────────────────────────
            if vrMode {
                VStack(alignment: .leading, spacing: 4) {
                    vrStatusBar
                    if !songPlayer.chordLine.isEmpty {
                        Text(songPlayer.chordLine)
                            .font(.system(size: 24, weight: .black, design: .rounded))
                            .foregroundStyle(.yellow)
                    }
                    if !songPlayer.feedbackLine.isEmpty {
                        Text(songPlayer.feedbackLine)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(songPlayer.feedbackLine.contains("✓") ? .green : .red)
                    }
                }
                .padding(12)
                .background(.black.opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.top, 52)
                .padding(.leading, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            // ── Debug overlay ───────────────────────────────────────────────
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

    // MARK: - Right panel

    private var rightPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Header / status ──────────────────────────────────────────
            panelHeader
                .padding(.top, 54)
                .padding(.horizontal, 14)
                .padding(.bottom, 12)

            panelDivider

            // ── Song info + feedback ─────────────────────────────────────
            songSection
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

            panelDivider

            // ── Primary action ────────────────────────────────────────────
            actionSection
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

            panelDivider

            // ── Utility buttons ───────────────────────────────────────────
            utilitySection
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

            panelDivider

            // ── Mode selector ─────────────────────────────────────────────
            modeSection
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

            if keyTuning.panelVisible {
                panelDivider
                tuningSection
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }

            Spacer(minLength: 0)

            panelDivider

            // ── Footer ────────────────────────────────────────────────────
            footerSection
                .padding(.horizontal, 14)
                .padding(.bottom, 28)
                .padding(.top, 10)
        }
        .frame(maxHeight: .infinity)
        .background(.black.opacity(0.82))
        .overlay(
            Rectangle()
                .fill(.white.opacity(0.10))
                .frame(width: 1),
            alignment: .leading
        )
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 16,
                bottomLeadingRadius: 16,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0
            )
        )
        .ignoresSafeArea(edges: .vertical)
    }

    private var panelDivider: some View {
        Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
    }

    // MARK: Header

    private var panelHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "pianokeys")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.50))
                Text("PianoAR")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(.white.opacity(0.50))
                    .kerning(1)
            }
            // Compact status row
            HStack(spacing: 10) {
                statusDot(
                    icon: "scope",
                    ok: session.trackingStateDescription.lowercased().contains("normal")
                )
                statusDot(icon: "sensor.tag.radiowaves.forward", ok: session.lidarAvailable)
                statusDot(
                    icon: "hand.raised.fill",
                    ok: handTracker.detectedHandCount > 0
                )
                statusDot(
                    icon: "mic.fill",
                    ok: audioDetector.microphoneState == "mic listening"
                )
                Spacer()
                if handTracker.detectedHandCount > 0 {
                    Text("\(handTracker.detectedHandCount)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.green)
                }
            }
        }
    }

    private func statusDot(icon: String, ok: Bool) -> some View {
        Image(systemName: icon)
            .font(.system(size: 12))
            .foregroundStyle(ok ? .green : .orange)
    }

    private var vrStatusBar: some View {
        HStack(spacing: 8) {
            statusDot(icon: "scope", ok: session.trackingStateDescription.lowercased().contains("normal"))
            statusDot(icon: "hand.raised.fill", ok: handTracker.detectedHandCount > 0)
            statusDot(icon: "mic.fill", ok: audioDetector.microphoneState == "mic listening")
            if !songPlayer.notes.isEmpty {
                Text("\(songPlayer.acceptedCount)/\(songPlayer.notes.count)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.green)
            }
        }
    }

    // MARK: Song section

    private var songSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Title
            Text(songPlayer.song?.title ?? "No song")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)

            // Progress bar + count
            if !songPlayer.notes.isEmpty {
                let progress = Double(songPlayer.acceptedCount) / Double(songPlayer.notes.count)
                VStack(alignment: .leading, spacing: 3) {
                    ProgressView(value: progress)
                        .tint(.green)
                        .scaleEffect(x: 1, y: 1.4, anchor: .center)
                    HStack {
                        Text("\(songPlayer.acceptedCount)/\(songPlayer.notes.count) notes")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.45))
                        Spacer()
                        if songPlayer.mistakeCount > 0 {
                            Label("\(songPlayer.mistakeCount)", systemImage: "xmark.circle.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.red.opacity(0.80))
                        }
                    }
                }
            }

            // Current chord (large — the most important thing to see)
            if !songPlayer.chordLine.isEmpty {
                Text(songPlayer.chordLine)
                    .font(.system(size: 19, weight: .black, design: .rounded))
                    .foregroundStyle(.yellow)
                    .lineLimit(2)
                    .minimumScaleFactor(0.65)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Feedback / score
            if !songPlayer.feedbackLine.isEmpty {
                Text(songPlayer.feedbackLine)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(songPlayer.feedbackLine.contains("✓") ? .green : .red)
                    .lineLimit(2)
            } else if !songPlayer.scoreLine.isEmpty {
                Text(songPlayer.scoreLine)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35))
                    .lineLimit(2)
            }
        }
    }

    // MARK: Action section

    private var actionSection: some View {
        VStack(spacing: 8) {
            // Play / Stop — the main action
            Button {
                if songPlayer.isPlaying { songPlayer.stop() } else { songPlayer.play() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: songPlayer.isPlaying ? "stop.fill" : "play.fill")
                        .font(.system(size: 16, weight: .bold))
                    Text(songPlayer.isPlaying ? "Stop" : "Play")
                        .font(.system(size: 16, weight: .bold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(songPlayer.isPlaying
                    ? Color(red: 0.85, green: 0.12, blue: 0.12).opacity(0.90)
                    : Color(red: 0.10, green: 0.47, blue: 0.95).opacity(0.90))
                .foregroundStyle(.white)
                .cornerRadius(12)
            }

            // Secondary actions
            HStack(spacing: 8) {
                secondaryButton(icon: "arrow.counterclockwise", label: "Restart") {
                    songPlayer.restart()
                }
                secondaryButton(icon: "forward.end.fill", label: "Next") {
                    advanceToNextSong()
                }
            }
        }
    }

    private func secondaryButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(.white.opacity(0.10))
            .foregroundStyle(.white)
            .cornerRadius(10)
        }
    }

    // MARK: Utility section

    private var utilitySection: some View {
        HStack(spacing: 8) {
            utilityButton(icon: "music.note.list", label: "Songs") {
                showSongPicker = true
            }
            utilityButton(icon: "square.and.arrow.down", label: "MIDI") {
                showMIDIImporter = true
            }
            utilityButton(icon: "slider.horizontal.3", label: "Tune",
                          active: keyTuning.panelVisible) {
                keyTuning.panelVisible.toggle()
            }
        }
    }

    private func utilityButton(icon: String, label: String,
                               active: Bool = false,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                Text(label)
                    .font(.system(size: 9, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(active
                ? Color(red: 0.10, green: 0.47, blue: 0.95).opacity(0.35)
                : .white.opacity(0.09))
            .foregroundStyle(active ? .blue : .white)
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(active ? Color.blue.opacity(0.55) : .clear, lineWidth: 1)
            )
        }
    }

    // MARK: Mode section

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("MODE")
                .font(.system(size: 9, weight: .black))
                .foregroundStyle(.white.opacity(0.30))
                .kerning(1.5)

            HStack(spacing: 0) {
                modeButton("Virtual", active: mode == .virtualPiano) {
                    mode = .virtualPiano
                }
                modeButton("Real Piano", active: mode == .realPiano) {
                    mode = .realPiano
                    if calibration.state == .idle { calibration.startCalibration() }
                }
            }
            .background(.white.opacity(0.07))
            .cornerRadius(10)
        }
    }

    private func modeButton(_ label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .bold))
                .padding(.horizontal, 6)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(active
                    ? Color(red: 0.10, green: 0.47, blue: 0.95).opacity(0.75)
                    : .clear)
                .foregroundStyle(active ? .white : .white.opacity(0.50))
                .cornerRadius(10)
        }
    }

    // MARK: Tuning section

    private var tuningSection: some View {
        let keyIndex = songPlayer.expectedKeyIndexNow()
        return VStack(alignment: .leading, spacing: 6) {
            Text(keyTuning.status(for: keyIndex))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.65))

            // X position row
            HStack(spacing: 5) {
                tuneButton("◀", color: .blue) { keyTuning.adjustX(for: keyIndex, by: -0.002) }
                Text("X pos").font(.system(size: 9)).foregroundStyle(.white.opacity(0.45))
                tuneButton("▶", color: .blue) { keyTuning.adjustX(for: keyIndex, by: 0.002) }
            }
            // Width row
            HStack(spacing: 5) {
                tuneButton("−", color: .orange) { keyTuning.adjustWidth(for: keyIndex, by: -0.0015) }
                Text("Width").font(.system(size: 9)).foregroundStyle(.white.opacity(0.45))
                tuneButton("+", color: .orange) { keyTuning.adjustWidth(for: keyIndex, by: 0.0015) }
            }
            Button { keyTuning.reset(keyIndex: keyIndex) } label: {
                Text("Reset")
                    .font(.system(size: 10, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.10))
                    .foregroundStyle(.white)
                    .cornerRadius(7)
            }
        }
    }

    private func tuneButton(_ label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .bold))
                .frame(width: 32, height: 28)
                .background(color.opacity(0.25))
                .foregroundStyle(color)
                .cornerRadius(7)
        }
    }

    // MARK: Footer

    private var footerSection: some View {
        VStack(spacing: 8) {
            // Debug toggle
            Button { showDebug.toggle() } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(showDebug ? Color.green : .white.opacity(0.22))
                        .frame(width: 7, height: 7)
                    Text(showDebug ? "Debug ON" : "Debug")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                    Spacer()
                }
            }

            // VR mode toggle
            Button {
                withAnimation(.easeInOut(duration: 0.22)) { vrMode.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: vrMode ? "eye.slash.fill" : "eye.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text(vrMode ? "Exit VR Mode" : "Enter VR Mode")
                        .font(.system(size: 12, weight: .bold))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.30))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(vrMode
                    ? Color.purple.opacity(0.45)
                    : .white.opacity(0.08))
                .foregroundStyle(.white)
                .cornerRadius(11)
                .overlay(
                    RoundedRectangle(cornerRadius: 11)
                        .stroke(vrMode ? Color.purple.opacity(0.60) : .white.opacity(0.12), lineWidth: 1)
                )
            }
        }
    }

    // MARK: Debug overlay

    private var debugOverlay: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("── Press ──").font(.caption.bold())
            ForEach(pressDetector.fingerDebugLines, id: \.self) {
                Text($0).font(.system(size: 9, design: .monospaced))
            }
            Text("── Mic ──").font(.caption.bold()).padding(.top, 3)
            ForEach(audioDetector.fingerDebugLines, id: \.self) {
                Text($0).font(.system(size: 9, design: .monospaced))
            }
        }
        .padding(8)
        .background(.black.opacity(0.80))
        .foregroundStyle(.green)
        .cornerRadius(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(.leading, 12)
        .padding(.bottom, 8)
    }

    // MARK: Setup instructions

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
                Label("Remove keyboard", systemImage: "trash")
                    .font(.caption.bold())
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(.red.opacity(0.80))
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
                Label("Start calibration", systemImage: "viewfinder")
                    .font(.caption.bold())
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(Color(red: 0.10, green: 0.47, blue: 0.95).opacity(0.85))
                    .foregroundStyle(.white)
                    .cornerRadius(10)
            }
        case .collecting(let count):
            let labels = [
                "Tap corner 1/4 — near-left (low notes, front)",
                "Tap corner 2/4 — near-right (high notes, front)",
                "Tap corner 3/4 — far-right (high notes, back)",
                "Tap corner 4/4 — far-left (low notes, back)",
            ]
            instructionLabel(labels[min(count, 3)])
        case .done:
            Button { calibration.reset() } label: {
                Label("Redo calibration", systemImage: "arrow.counterclockwise")
                    .font(.caption.bold())
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(.orange.opacity(0.85))
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
            .background(.black.opacity(0.65))
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

    // MARK: Tap / gesture routing

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
                        Label("Import MIDI file", systemImage: "square.and.arrow.down")
                    }
                }
            }
            .navigationTitle("Songs")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
