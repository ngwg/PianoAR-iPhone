import SceneKit
import UIKit
import simd

/// All Phase-4 visual elements: the highway grid, falling note bars,
/// per-key highlight overlays, and note-letter labels.
///
/// rootNode should be added as a child of the keyboard anchor's scene node
/// so it inherits the anchor's world-space transform (and the calibration
/// scale for real-piano mode). All child positions are in keyboard-local
/// space using KeyboardLayout constants.
final class NoteHighway {
    let rootNode = SCNNode()

    // MARK: - Layout constants

    private static let highwayLength:   Float = 1.5    // metres visible ahead
    private static let lookAheadBeats:  Float = 4.0
    private static let highwayY:        Float = 0.030  // metres above keyboard surface
    private static let barThickness:    Float = 0.003  // note bar Y height
    // Near edge of keys (in keyboard-local Z) — highway "now" line.
    private static let nearEdgeZ:       Float = KeyboardLayout.whiteKeyDepth / 2   // 0.074 m
    private static var beatsToMeters:   Float { highwayLength / lookAheadBeats }
    private static let poolSize:        Int   = 48

    // MARK: - Cached materials (created once, reused every frame)

    private static let matBackground: SCNMaterial = {
        let m = SCNMaterial()
        m.lightingModel       = .constant
        m.diffuse.contents    = UIColor(red: 0.04, green: 0.05, blue: 0.16, alpha: 0.78)
        m.blendMode           = .alpha
        m.isDoubleSided       = true
        m.writesToDepthBuffer = false
        return m
    }()

    private static let matGridLine: SCNMaterial = {
        let m = SCNMaterial()
        m.lightingModel       = .constant
        m.diffuse.contents    = UIColor(white: 1.0, alpha: 0.18)
        m.blendMode           = .alpha
        m.isDoubleSided       = true
        m.writesToDepthBuffer = false
        return m
    }()

    private static let matPlayhead: SCNMaterial = {
        let m = SCNMaterial()
        m.lightingModel       = .constant
        m.diffuse.contents    = UIColor(white: 1.0, alpha: 0.90)
        m.blendMode           = .alpha
        m.writesToDepthBuffer = false
        return m
    }()

    // Solid blue — right hand / unassigned notes
    private static let matBarRight: SCNMaterial = {
        let m = SCNMaterial()
        m.lightingModel       = .constant
        m.diffuse.contents    = UIColor(red: 0.22, green: 0.55, blue: 1.00, alpha: 0.90)
        m.blendMode           = .alpha
        m.writesToDepthBuffer = false
        return m
    }()

    // Solid rose — left hand notes
    private static let matBarLeft: SCNMaterial = {
        let m = SCNMaterial()
        m.lightingModel       = .constant
        m.diffuse.contents    = UIColor(red: 0.95, green: 0.30, blue: 0.55, alpha: 0.90)
        m.blendMode           = .alpha
        m.writesToDepthBuffer = false
        return m
    }()

    // White flash when the bar reaches the playhead — stays in the same visual family
    private static let matBarActive: SCNMaterial = {
        let m = SCNMaterial()
        m.lightingModel       = .constant
        m.diffuse.contents    = UIColor(white: 1.0, alpha: 0.96)
        m.blendMode           = .alpha
        m.writesToDepthBuffer = false
        return m
    }()

    // Key glow uses additive blend so it lights up the real key surface
    private static let matHighlightRight: SCNMaterial = {
        let m = SCNMaterial()
        m.lightingModel       = .constant
        m.diffuse.contents    = UIColor(red: 0.22, green: 0.55, blue: 1.00, alpha: 1)
        m.emission.contents   = UIColor(red: 0.10, green: 0.30, blue: 0.70, alpha: 1)
        m.blendMode           = .add
        m.isDoubleSided       = true
        m.writesToDepthBuffer = false
        return m
    }()

    private static let matHighlightLeft: SCNMaterial = {
        let m = SCNMaterial()
        m.lightingModel       = .constant
        m.diffuse.contents    = UIColor(red: 0.95, green: 0.30, blue: 0.55, alpha: 1)
        m.emission.contents   = UIColor(red: 0.60, green: 0.10, blue: 0.28, alpha: 1)
        m.blendMode           = .add
        m.isDoubleSided       = true
        m.writesToDepthBuffer = false
        return m
    }()

    private static let matLabel: SCNMaterial = {
        let m = SCNMaterial()
        m.lightingModel      = .constant
        m.diffuse.contents   = UIColor.white
        m.emission.contents  = UIColor(white: 0.65, alpha: 1)
        m.isDoubleSided      = true
        m.writesToDepthBuffer = false
        return m
    }()

    // MARK: - Node pools / registries

    private var barPool:        [SCNNode]  = []
    private var labelPool:      [SCNNode]  = []
    private var barNoteKeys:    [String]   = []   // tracks last text set on each label
    private var highlights:     [SCNNode?] = Array(repeating: nil, count: 88)
    private let midiToKey: [Int: KeyboardLayout.Key]

    // MARK: - Init

    init() {
        midiToKey = Dictionary(
            uniqueKeysWithValues: KeyboardLayout.keys.map { ($0.midiNote, $0) }
        )
        buildBackground()
        buildGridLines()
        buildPlayheadLine()
        buildBarPool()
        buildLabelPool()
        buildKeyHighlights()
        buildKeyLabels()
    }

    // MARK: - Scene construction (called once from init)

    private func buildBackground() {
        let geo = SCNPlane(
            width:  CGFloat(KeyboardLayout.totalWidth),
            height: CGFloat(Self.highwayLength)
        )
        geo.materials = [Self.matBackground]
        let node = SCNNode(geometry: geo)
        // SCNPlane faces +Z; rotate -90° around X so it lies flat facing +Y
        node.eulerAngles.x = -.pi / 2
        node.simdPosition  = SIMD3<Float>(
            0,
            Self.highwayY - 0.001,
            Self.nearEdgeZ - Self.highwayLength / 2
        )
        rootNode.addChildNode(node)
    }

    private func buildGridLines() {
        let leftEdge = -KeyboardLayout.totalWidth / 2
        let centerZ  = Self.nearEdgeZ - Self.highwayLength / 2

        // Vertical lines at every C note (octave boundaries)
        for key in KeyboardLayout.keys where key.noteName.hasPrefix("C") {
            let x    = leftEdge + key.xCenter
            let line = SCNBox(width: 0.0018,
                              height: 0.0015,
                              length: CGFloat(Self.highwayLength),
                              chamferRadius: 0)
            line.materials = [Self.matGridLine]
            let node = SCNNode(geometry: line)
            node.simdPosition = SIMD3<Float>(x, Self.highwayY, centerZ)
            rootNode.addChildNode(node)
        }
    }

    private func buildPlayheadLine() {
        let line = SCNBox(
            width:  CGFloat(KeyboardLayout.totalWidth + 0.02),
            height: 0.002,
            length: 0.004,
            chamferRadius: 0
        )
        line.materials = [Self.matPlayhead]
        let node = SCNNode(geometry: line)
        node.simdPosition = SIMD3<Float>(0, Self.highwayY + 0.001, Self.nearEdgeZ)
        rootNode.addChildNode(node)
    }

    private func buildBarPool() {
        for _ in 0..<Self.poolSize {
            // Unit cube scaled each frame. chamferRadius 0.06 = clean rectangle
            // with just a hint of rounding on the corners.
            let geo  = SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0.06)
            geo.materials = [Self.matBarRight]
            let node = SCNNode(geometry: geo)
            node.renderingOrder = 50
            node.isHidden       = true
            rootNode.addChildNode(node)
            barPool.append(node)
        }
    }

    private func buildLabelPool() {
        for _ in 0..<Self.poolSize {
            let node = SCNNode()
            // Facing up (same orientation as key labels on the keyboard surface).
            node.eulerAngles    = SCNVector3(-Float.pi / 2, 0, 0)
            node.scale          = SCNVector3(0.009, 0.009, 0.009)
            node.renderingOrder = 60
            node.isHidden       = true
            rootNode.addChildNode(node)
            labelPool.append(node)
            barNoteKeys.append("")
        }
    }

    private func buildKeyHighlights() {
        let leftEdge = -KeyboardLayout.totalWidth / 2
        for key in KeyboardLayout.keys {
            let (w, d, y, z): (Float, Float, Float, Float)
            if key.isBlack {
                let zOff = -((KeyboardLayout.whiteKeyDepth - KeyboardLayout.blackKeyDepth) / 2)
                w = KeyboardLayout.blackKeyWidth  - 0.001
                d = KeyboardLayout.blackKeyDepth  - 0.002
                y = KeyboardLayout.whiteKeyHeight + KeyboardLayout.blackKeyExtraHeight + 0.002
                z = zOff
            } else {
                w = KeyboardLayout.whiteKeyWidth - 0.001
                d = KeyboardLayout.whiteKeyDepth - 0.002
                y = KeyboardLayout.whiteKeyHeight + 0.002
                z = 0
            }
            let box = SCNBox(width: CGFloat(w), height: 0.001,
                             length: CGFloat(d), chamferRadius: 0.001)
            box.materials = [Self.matHighlightRight]
            let node = SCNNode(geometry: box)
            node.renderingOrder = 10
            node.simdPosition   = SIMD3<Float>(leftEdge + key.xCenter, y, z)
            node.isHidden       = true
            rootNode.addChildNode(node)
            if key.index < 88 { highlights[key.index] = node }
        }
    }

    private func buildKeyLabels() {
        let leftEdge = -KeyboardLayout.totalWidth / 2
        for key in KeyboardLayout.keys where !key.isBlack {
            let letter = String(key.noteName.prefix(1))
            let text   = SCNText(string: letter, extrusionDepth: 0.0005)
            text.font     = UIFont.boldSystemFont(ofSize: 1.0)
            text.flatness = 0.05
            text.materials = [Self.matLabel]

            let node = SCNNode(geometry: text)
            node.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
            node.scale       = SCNVector3(0.010, 0.010, 0.010)
            node.renderingOrder = 20
            // After -π/2 rotation around X: text face → +Y (faces up),
            // letter height extends in -Z direction (from near edge backward).
            // X offset of -0.003 roughly centers a single uppercase character.
            node.simdPosition = SIMD3<Float>(
                leftEdge + key.xCenter - 0.003,
                KeyboardLayout.whiteKeyHeight + 0.003,
                Self.nearEdgeZ - 0.008
            )
            rootNode.addChildNode(node)
        }
    }

    // MARK: - Per-frame update (called from renderer(_:updateAtTime:) on render thread)

    func update(player: SongPlayer) {
        guard player.isPlaying else {
            barPool.forEach    { $0.isHidden = true }
            labelPool.forEach  { $0.isHidden = true }
            highlights.forEach { $0?.isHidden = true }
            return
        }

        let beat     = Float(player.beatNow())
        let leftEdge = -KeyboardLayout.totalWidth / 2

        // ── Note bars ──────────────────────────────────────────────────────
        var barIdx = 0
        for note in player.notes {
            let bUntilStart = Float(note.startBeat) - beat
            // Only show bars that are still approaching the playhead.
            // Once bUntilStart <= 0 the bar has "landed" — hide it so it
            // doesn't slide over the keyboard keys.
            guard bUntilStart > 0,
                  bUntilStart <= Self.lookAheadBeats + 0.1
            else { continue }
            guard barIdx < Self.poolSize else { break }
            guard let key = midiToKey[note.midiNote ?? -1] else { continue }

            let bar    = barPool[barIdx]
            let barLen = max(0.007, Float(note.durationBeats) * Self.beatsToMeters)
            let keyW   = key.isBlack ? KeyboardLayout.blackKeyWidth - 0.001
                                     : KeyboardLayout.whiteKeyWidth - 0.001
            let nearZ   = Self.nearEdgeZ - bUntilStart * Self.beatsToMeters
            let centerZ = nearZ - barLen / 2

            bar.simdPosition = SIMD3<Float>(
                leftEdge + key.xCenter,
                Self.highwayY + Self.barThickness / 2,
                centerZ
            )
            bar.scale = SCNVector3(keyW, Self.barThickness, barLen)
            bar.geometry?.materials = [note.isLeft ? Self.matBarLeft : Self.matBarRight]
            bar.isHidden = false

            // ── Label on bar ──
            let lbl = labelPool[barIdx]
            // Rebuild SCNText only when the note changes (avoids per-frame alloc).
            if barNoteKeys[barIdx] != note.key {
                let txt        = SCNText(string: note.key, extrusionDepth: 0.0001)
                txt.font       = UIFont.boldSystemFont(ofSize: 1.0)
                txt.flatness   = 0.05
                txt.materials  = [Self.matLabel]
                lbl.geometry   = txt
                barNoteKeys[barIdx] = note.key
            }
            // Center text on the bar: after -π/2 X rotation, text "height" extends
            // in -Z, so placing at nearZ centers the text near the leading edge.
            lbl.simdPosition = SIMD3<Float>(
                leftEdge + key.xCenter - 0.005,
                Self.highwayY + Self.barThickness + 0.002,
                nearZ - 0.002
            )
            lbl.isHidden = false

            barIdx += 1
        }
        for i in barIdx..<Self.poolSize {
            barPool[i].isHidden  = true
            labelPool[i].isHidden = true
        }

        // ── Key highlights ─────────────────────────────────────────────────
        highlights.forEach { $0?.isHidden = true }
        for note in player.notes {
            let delta = Float(note.startBeat) - beat
            let end   = Float(note.startBeat + note.durationBeats) - beat
            guard delta <= 0.35 && end > -0.10 else { continue }
            guard let key = midiToKey[note.midiNote ?? -1],
                  key.index < 88,
                  let hl  = highlights[key.index]
            else { continue }
            hl.geometry?.materials = [note.isLeft ? Self.matHighlightLeft : Self.matHighlightRight]
            hl.isHidden = false
        }
    }
}
