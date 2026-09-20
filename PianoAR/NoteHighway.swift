import SceneKit
import UIKit
import simd

/// Falling-note waterfall + cues on the keys.
///
/// Keyboard-local frame: +X low→high notes, +Y up, +Z toward the player, key
/// tops at `whiteKeyHeight`. The waterfall is a sheet rising from the BACK
/// edge of the keys (where they meet the fallboard), tilted slightly away;
/// notes fall down it onto a glowing hit line — the PianoVision/Synthesia
/// layout. Nothing covers the real keys except thin cue highlights on the
/// keys to play (the old flat highway laid a dark sheet over the keys).
final class NoteHighway {
    let rootNode = SCNNode()

    // MARK: Layout
    private static let sheetHeight: Float = 0.40
    /// How far ahead the sheet shows, in **seconds** rather than beats.
    ///
    /// It used to be a fixed four beats, which means a fast piece shows less
    /// warning than a slow one — exactly backwards. Dreiton runs at 120 bpm,
    /// so four beats is two seconds; at nearly five notes a second that put
    /// roughly ten notes into forty centimetres of sheet, stacked on top of
    /// each other. Moonlight at 54 bpm got four and a half seconds for the
    /// same space. Now every piece gets the same amount of *time*, with a
    /// floor and a ceiling in beats so the grid never becomes meaningless.
    private static let lookAheadSeconds: Float = 2.6
    private static var lookAheadBeats: Float = 4
    private static var metersPerBeat: Float { sheetHeight / lookAheadBeats }

    private static func updateLookAhead(bpm: Float) {
        let beats = lookAheadSeconds * bpm / 60
        lookAheadBeats = min(10, max(2.5, beats))
    }
    private static let tilt: Float = 0.26               // ~15° back from vertical
    private static let barDepth: Float = 0.006
    private static let barGap: Float = 0.003
    // Eight simultaneous notes over two and a half seconds of a dense piece
    // overflows sixty-four, and the overflow was silently dropped — notes
    // simply missing from the preview.
    private static let barPoolSize = 180
    private static let beatLineCount = 12
    private static let flashDuration: TimeInterval = 0.35
    private static let heardDuration: TimeInterval = 0.18

    private static var leftEdge: Float { -KeyboardLayout.totalWidth / 2 }

    // MARK: Materials
    private static func mat(_ color: UIColor, emission: UIColor? = nil,
                            blend: SCNBlendMode = .alpha) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel        = .constant
        m.diffuse.contents     = color
        if let emission { m.emission.contents = emission }
        m.blendMode            = blend
        m.isDoubleSided        = true
        m.writesToDepthBuffer  = false
        m.readsFromDepthBuffer = false     // overlays never z-fight (see CODEX §6)
        return m
    }

    private static let rightColor = UIColor(red: 0.25, green: 0.62, blue: 1.00, alpha: 1)
    private static let leftColor  = UIColor(red: 1.00, green: 0.55, blue: 0.20, alpha: 1)

    private static let matBarRight    = mat(rightColor.withAlphaComponent(0.92))
    private static let matBarLeft     = mat(leftColor.withAlphaComponent(0.92))
    private static let matBarOptional = mat(UIColor(white: 0.75, alpha: 0.35))
    private static let matBarPlayed   = mat(UIColor(red: 0.30, green: 1.00, blue: 0.55, alpha: 0.85))
    private static let matBarEdge     = mat(UIColor(white: 1, alpha: 0.95))
    private static let matHitLine     = mat(UIColor(red: 0.75, green: 0.92, blue: 1.0, alpha: 0.95),
                                            emission: UIColor(red: 0.3, green: 0.6, blue: 1.0, alpha: 1))
    private static let matLane        = mat(UIColor(white: 1, alpha: 0.16))
    private static let matBeat        = mat(UIColor(white: 1, alpha: 0.10))
    private static let matBar4        = mat(UIColor(white: 1, alpha: 0.26))

    private static let matCueRight    = mat(rightColor, blend: .add)
    private static let matCueLeft     = mat(leftColor, blend: .add)
    private static let matCueOptional = mat(UIColor(white: 0.55, alpha: 1), blend: .add)
    private static let matCueSoon     = mat(UIColor(white: 0.45, alpha: 1), blend: .add)
    private static let matFlashGood   = mat(UIColor(red: 0.15, green: 1.0, blue: 0.45, alpha: 1), blend: .add)
    private static let matFlashBad    = mat(UIColor(red: 1.0, green: 0.15, blue: 0.12, alpha: 1), blend: .add)

    // MARK: Nodes
    private let sheet = SCNNode()            // tilted; local +Y runs up the sheet
    private var background: SCNNode!
    private var bars:       [SCNNode] = []
    private var barEdges:   [SCNNode] = []
    private var barLabels:  [SCNNode] = []
    private var labelText:  [String]  = []
    private var beatLines:  [SCNNode] = []
    private var cues:       [SCNNode] = []   // one per key, on the key top
    private var keyLabels:  [SCNNode] = []

    private var goodFlashes: [Int: TimeInterval] = [:]
    private var badFlashes:  [Int: TimeInterval] = [:]
    /// "Something was struck" — shown the instant an onset is heard, before
    /// anything is known about which note it was.
    private var heardAt: TimeInterval = 0
    /// Keys currently being waited for, captured while the cues are drawn.
    private var pendingCueKeys: Set<Int> = []
    private var sheetShown = false
    private let midiToKey: [Int: KeyboardLayout.Key]

    var showNoteNames = true
    var showKeyLabels = true

    init() {
        midiToKey = Dictionary(uniqueKeysWithValues: KeyboardLayout.keys.map { ($0.midiNote, $0) })
        sheet.simdPosition = SIMD3<Float>(0, KeyboardLayout.whiteKeyHeight + 0.004,
                                          -KeyboardLayout.whiteKeyDepth / 2 - 0.004)
        sheet.eulerAngles.x = -Self.tilt
        sheet.opacity = 0
        rootNode.addChildNode(sheet)

        buildBackground()
        buildLanes()
        buildHitLine()
        buildBeatLines()
        buildBars()
        buildCues()
        buildKeyLabels()
    }

    // MARK: - Construction

    private func buildBackground() {
        let geo = SCNPlane(width: CGFloat(KeyboardLayout.totalWidth + 0.02),
                           height: CGFloat(Self.sheetHeight))
        let m = Self.mat(UIColor(white: 0, alpha: 1))
        m.diffuse.contents = Self.gradientImage()   // CoreGraphics only: render-thread safe
        geo.materials = [m]
        background = SCNNode(geometry: geo)
        background.simdPosition = SIMD3<Float>(0, Self.sheetHeight / 2, -0.003)
        background.renderingOrder = 40
        sheet.addChildNode(background)
    }

    /// Dark at the hit line, fading to clear at the top, so the sheet reads
    /// as a light veil over the piano case instead of a wall.
    private static func gradientImage() -> CGImage? {
        let w = 4, h = 256
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let grad = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [CGColor(red: 0.02, green: 0.03, blue: 0.10, alpha: 0.62),
                         CGColor(red: 0.02, green: 0.03, blue: 0.10, alpha: 0.0)] as CFArray,
                locations: [0, 1])
        else { return nil }
        // CG's origin is bottom-left and the image shows upright on the plane,
        // so dark at CG y = 0 lands on the plane's bottom edge (the hit line).
        ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 0),
                               end: CGPoint(x: 0, y: h), options: [])
        return ctx.makeImage()
    }

    private func buildLanes() {
        // A faint lane line at every octave boundary (left edge of each C).
        for key in KeyboardLayout.keys where key.noteName.hasPrefix("C") && !key.isBlack {
            let line = SCNBox(width: 0.0015, height: CGFloat(Self.sheetHeight),
                              length: 0.001, chamferRadius: 0)
            line.materials = [Self.matLane]
            let n = SCNNode(geometry: line)
            n.simdPosition = SIMD3<Float>(Self.leftEdge + key.xCenter - KeyboardLayout.whiteKeyWidth / 2,
                                          Self.sheetHeight / 2, -0.001)
            n.renderingOrder = 45
            sheet.addChildNode(n)
        }
    }

    private func buildHitLine() {
        let line = SCNBox(width: CGFloat(KeyboardLayout.totalWidth + 0.01), height: 0.0035,
                          length: 0.004, chamferRadius: 0.001)
        line.materials = [Self.matHitLine]
        let n = SCNNode(geometry: line)
        n.simdPosition = SIMD3<Float>(0, 0, 0.002)
        n.renderingOrder = 70
        sheet.addChildNode(n)
    }

    private func buildBeatLines() {
        for _ in 0..<Self.beatLineCount {
            let line = SCNBox(width: CGFloat(KeyboardLayout.totalWidth), height: 0.0012,
                              length: 0.001, chamferRadius: 0)
            line.materials = [Self.matBeat]
            let n = SCNNode(geometry: line)
            n.isHidden = true
            n.renderingOrder = 46
            sheet.addChildNode(n)
            beatLines.append(n)
        }
    }

    private func buildBars() {
        for _ in 0..<Self.barPoolSize {
            let box = SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0)
            box.materials = [Self.matBarRight]
            let bar = SCNNode(geometry: box)
            bar.isHidden = true
            bar.renderingOrder = 50
            sheet.addChildNode(bar)
            bars.append(bar)

            // Bright leading edge — the part that "lands" on the hit line.
            let edgeGeo = SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0)
            edgeGeo.materials = [Self.matBarEdge]
            let edge = SCNNode(geometry: edgeGeo)
            edge.isHidden = true
            edge.renderingOrder = 55
            sheet.addChildNode(edge)
            barEdges.append(edge)

            let plane = SCNPlane(width: 0.024, height: 0.012)
            let lm = Self.mat(.white)
            plane.materials = [lm]
            let label = SCNNode(geometry: plane)
            label.isHidden = true
            label.renderingOrder = 60
            sheet.addChildNode(label)
            barLabels.append(label)
            labelText.append("")
        }
    }

    private func buildCues() {
        for key in KeyboardLayout.keys {
            let w: Float, d: Float, y: Float, z: Float
            if key.isBlack {
                w = KeyboardLayout.blackKeyWidth - 0.001
                d = KeyboardLayout.blackKeyDepth - 0.004
                y = KeyboardLayout.whiteKeyHeight + KeyboardLayout.blackKeyExtraHeight + 0.001
                z = -(KeyboardLayout.whiteKeyDepth - KeyboardLayout.blackKeyDepth) / 2
            } else {
                w = KeyboardLayout.whiteKeyWidth - 0.002
                d = KeyboardLayout.whiteKeyDepth - 0.004
                y = KeyboardLayout.whiteKeyHeight + 0.001
                z = 0
            }
            let box = SCNBox(width: CGFloat(w), height: 0.0008, length: CGFloat(d), chamferRadius: 0.001)
            box.materials = [Self.matCueRight]
            let n = SCNNode(geometry: box)
            n.simdPosition = SIMD3<Float>(Self.leftEdge + key.xCenter, y, z)
            n.isHidden = true
            n.renderingOrder = 20
            rootNode.addChildNode(n)
            cues.append(n)
        }
    }

    private func buildKeyLabels() {
        for key in KeyboardLayout.keys where !key.isBlack {
            let plane = SCNPlane(width: 0.018, height: 0.009)
            let m = Self.mat(.white)
            m.diffuse.contents = LabelFactory.image(LabelFactory.keyLabelText(for: key), style: .keyLetter)
            plane.materials = [m]
            let n = SCNNode(geometry: plane)
            n.eulerAngles.x = -.pi / 2              // lie flat on the key top
            n.simdPosition = SIMD3<Float>(Self.leftEdge + key.xCenter,
                                          KeyboardLayout.whiteKeyHeight + 0.0015,
                                          KeyboardLayout.whiteKeyDepth / 2 - 0.014)
            n.renderingOrder = 25
            n.name = LabelFactory.keyLabelText(for: key)
            rootNode.addChildNode(n)
            keyLabels.append(n)
        }
    }

    // MARK: - Feedback

    /// Telling the player "I heard you" and telling them "that was right"
    /// are two different questions, and only the second one is slow.
    ///
    /// Deciding *which* note was played needs a long look at the sound — at
    /// 8192 points that is 186 ms of audio, and the window cannot open until
    /// the hammer noise has passed, so a verdict lands about a third of a
    /// second after the strike. But *that* a note was struck is known within
    /// about 40 ms, and known reliably (the onset detector measured 0.99
    /// precision). Waiting for the verdict before showing anything made the
    /// whole app feel unresponsive for no reason.
    ///
    /// So the keys being waited for pulse immediately on any strike — an
    /// acknowledgement, deliberately not a judgement — and the green
    /// confirmation still arrives when it is actually known.
    func registerStrike() { heardAt = CACurrentMediaTime() }

    func registerPress(keyIndex: Int) { goodFlashes[keyIndex] = CACurrentMediaTime() }
    func registerMiss(keyIndex: Int)  { badFlashes[keyIndex]  = CACurrentMediaTime() }

    // MARK: - Per-frame update (render thread)

    func update(player: SongPlayer) {
        let now = CACurrentMediaTime()
        showSheet(player.isPlaying)
        updateKeyLabels()

        if player.isPlaying {
            let beat = Float(player.beatNow())
            updateBars(player: player, beat: beat)
            updateBeatLines(beat: beat)
        } else {
            for i in 0..<Self.barPoolSize {
                bars[i].isHidden = true
                barEdges[i].isHidden = true
                barLabels[i].isHidden = true
            }
            beatLines.forEach { $0.isHidden = true }
        }
        updateCues(player: player, now: now)
    }

    private func showSheet(_ show: Bool) {
        guard show != sheetShown else { return }
        sheetShown = show
        sheet.removeAllActions()
        sheet.runAction(show ? .fadeIn(duration: 0.4) : .fadeOut(duration: 0.4))
    }

    private func updateKeyLabels() {
        for n in keyLabels {
            n.isHidden = !showKeyLabels
            // Fill in any label whose image wasn't baked yet at build time.
            if showKeyLabels, let m = n.geometry?.firstMaterial, m.diffuse.contents == nil,
               let text = n.name, let img = LabelFactory.image(text, style: .keyLetter) {
                m.diffuse.contents = img
            }
        }
    }

    private func setMaterial(_ node: SCNNode, _ material: SCNMaterial) {
        if node.geometry?.firstMaterial !== material { node.geometry?.materials = [material] }
    }

    private func updateBars(player: SongPlayer, beat: Float) {
        Self.updateLookAhead(bpm: Float(player.effectiveBPMNow))
        let mpb = Self.metersPerBeat
        let groupStart = player.currentGroupStartBeat()
        let accepted = player.acceptedKeys
        var i = 0

        for note in player.notes {
            let start = Float(note.startBeat) - beat
            if start >= Self.lookAheadBeats { break }          // notes are sorted by start
            let end = start + Float(note.durationBeats)
            guard end > 0, i < Self.barPoolSize,
                  let key = midiToKey[note.midiNote ?? -1] else { continue }
            let bottom = max(0, start) * mpb
            let top = min(Self.lookAheadBeats, end) * mpb
            guard top - bottom > 0.002 else { continue }

            let w = (key.isBlack ? KeyboardLayout.blackKeyWidth : KeyboardLayout.whiteKeyWidth) - Self.barGap
            let x = Self.leftEdge + key.xCenter

            let bar = bars[i]
            bar.simdPosition = SIMD3<Float>(x, (bottom + top) / 2, Self.barDepth / 2)
            bar.scale = SCNVector3(w, top - bottom, Self.barDepth)
            let inCurrentGroup = groupStart.map { abs(note.startBeat - $0) < 0.001 } ?? false
            if inCurrentGroup && accepted.contains(key.index) {
                setMaterial(bar, Self.matBarPlayed)
            } else if !player.isRequired(note) {
                setMaterial(bar, Self.matBarOptional)
            } else {
                setMaterial(bar, note.isLeft ? Self.matBarLeft : Self.matBarRight)
            }
            // While the song waits, everything stops — so a dense piece piles
            // up at the hit line and it stops being obvious which notes are
            // actually being asked for. Hold the current group at full
            // strength and push the rest back.
            bar.opacity = (player.isWaitingNow && !inCurrentGroup) ? 0.42 : 1.0
            bar.isHidden = false

            let edge = barEdges[i]
            if start >= 0 {
                edge.simdPosition = SIMD3<Float>(x, bottom + 0.0015, Self.barDepth + 0.0005)
                edge.scale = SCNVector3(w, 0.003, 0.001)
                edge.isHidden = false
            } else {
                edge.isHidden = true
            }

            let label = barLabels[i]
            if showNoteNames, top - bottom > 0.016 {
                if labelText[i] != note.key,
                   let img = LabelFactory.image(note.key, style: .note) {
                    label.geometry?.firstMaterial?.diffuse.contents = img
                    labelText[i] = note.key
                }
                let s: Float = key.isBlack ? 0.8 : 1.0
                label.scale = SCNVector3(s, s, s)
                label.simdPosition = SIMD3<Float>(x, bottom + 0.010, Self.barDepth + 0.001)
                label.isHidden = labelText[i] != note.key
            } else {
                label.isHidden = true
            }
            i += 1
        }
        for j in i..<Self.barPoolSize {
            bars[j].isHidden = true
            barEdges[j].isHidden = true
            barLabels[j].isHidden = true
        }
    }

    private func updateBeatLines(beat: Float) {
        let mpb = Self.metersPerBeat
        var b = beat.rounded(.up)
        var i = 0
        while i < Self.beatLineCount, b - beat < Self.lookAheadBeats {
            let n = beatLines[i]
            n.simdPosition = SIMD3<Float>(0, (b - beat) * mpb, -0.0005)
            setMaterial(n, Int(b) % 4 == 0 ? Self.matBar4 : Self.matBeat)
            n.isHidden = false
            i += 1
            b += 1
        }
        for j in i..<Self.beatLineCount { beatLines[j].isHidden = true }
    }

    private func updateCues(player: SongPlayer, now: TimeInterval) {
        cues.forEach { $0.isHidden = true }
        pendingCueKeys.removeAll(keepingCapacity: true)

        if player.isPlaying {
            // What to play now: pulsing, coloured by hand.
            let pulse = CGFloat(0.72 + 0.28 * sin(now * 2 * .pi * 1.6))
            for cue in player.currentCues() where cue.keyIndex >= 0 && cue.keyIndex < cues.count {
                let n = cues[cue.keyIndex]
                if cue.required {
                    pendingCueKeys.insert(cue.keyIndex)
                    setMaterial(n, cue.isLeft ? Self.matCueLeft : Self.matCueRight)
                    n.opacity = pulse
                } else {
                    setMaterial(n, Self.matCueOptional)
                    n.opacity = 0.45
                }
                n.isHidden = false
            }

            // What's coming within a beat: a faint pre-glow that brightens as
            // the note approaches the hit line.
            let beat = player.beatNow()
            let groupStart = player.currentGroupStartBeat()
            for note in player.notes {
                let dt = note.startBeat - beat
                if dt > 1.0 { break }
                guard dt > 0,
                      groupStart.map({ abs(note.startBeat - $0) > 0.001 }) ?? true,
                      player.isRequired(note),
                      let key = midiToKey[note.midiNote ?? -1],
                      cues[key.index].isHidden else { continue }
                let n = cues[key.index]
                setMaterial(n, Self.matCueSoon)
                n.opacity = CGFloat(0.55 * (1 - dt))
                n.isHidden = false
            }
        }

        // "Heard you": a brief lift on whatever is being waited for, so the
        // strike registers visually long before the verdict can exist.
        let heardAge = now - heardAt
        if heardAge >= 0, heardAge < Self.heardDuration {
            let lift = CGFloat(1 - heardAge / Self.heardDuration)
            for k in pendingCueKeys where k >= 0 && k < cues.count {
                if goodFlashes[k] == nil, badFlashes[k] == nil {
                    cues[k].opacity = max(cues[k].opacity, 0.35 + 0.45 * lift)
                    cues[k].isHidden = false
                }
            }
        }

        // Detection feedback overrides cues.
        for (k, t0) in goodFlashes {
            let age = now - t0
            if age > Self.flashDuration { goodFlashes.removeValue(forKey: k); continue }
            guard k >= 0, k < cues.count else { continue }
            setMaterial(cues[k], Self.matFlashGood)
            cues[k].opacity = CGFloat(1 - age / Self.flashDuration)
            cues[k].isHidden = false
        }
        for (k, t0) in badFlashes {
            let age = now - t0
            if age > Self.flashDuration { badFlashes.removeValue(forKey: k); continue }
            guard k >= 0, k < cues.count else { continue }
            setMaterial(cues[k], Self.matFlashBad)
            cues[k].opacity = CGFloat(1 - age / Self.flashDuration)
            cues[k].isHidden = false
        }
    }
}
