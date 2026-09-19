import SceneKit
import UIKit

enum KeyboardNode {
    /// Builds a full 88-key keyboard SCNNode tree.
    /// The node is centered at X=0, sits on the Y=0 plane (keys extend upward),
    /// and is centered in Z (keyboard depth spans ±whiteKeyDepth/2).
    static func make() -> SCNNode {
        let root = SCNNode()
        let leftEdge = -KeyboardLayout.totalWidth / 2

        // Dark wood base plate — makes the keyboard shape obvious from any angle
        let base = SCNBox(
            width:        CGFloat(KeyboardLayout.totalWidth + 0.012),
            height:       0.006,
            length:       CGFloat(KeyboardLayout.whiteKeyDepth + 0.012),
            chamferRadius: 0.003
        )
        let baseMat = SCNMaterial()
        baseMat.lightingModel    = .constant
        baseMat.diffuse.contents = UIColor(red: 0.18, green: 0.09, blue: 0.02, alpha: 1)
        base.materials = [baseMat]
        let baseNode = SCNNode(geometry: base)
        baseNode.position = SCNVector3(0, -0.003, 0)
        root.addChildNode(baseNode)

        // Constant lighting model: the keys look exactly like their diffuse color
        // regardless of scene light estimation. This matters in the headset where the
        // phone is in a dark enclosure — default Blinn/Phong gets very dark.
        let ivoryMat = SCNMaterial()
        ivoryMat.lightingModel    = .constant
        ivoryMat.diffuse.contents = UIColor(white: 0.93, alpha: 1)
        ivoryMat.emission.contents = UIColor(white: 0.06, alpha: 1)  // slight glow for dark rooms

        let eboxyMat = SCNMaterial()
        eboxyMat.lightingModel    = .constant
        eboxyMat.diffuse.contents = UIColor(white: 0.10, alpha: 1)
        eboxyMat.emission.contents = UIColor(white: 0.02, alpha: 1)

        // White keys first so black keys render on top
        for key in KeyboardLayout.keys where !key.isBlack {
            let box = SCNBox(
                width:        CGFloat(KeyboardLayout.whiteKeyWidth - 0.0008),
                height:       CGFloat(KeyboardLayout.whiteKeyHeight),
                length:       CGFloat(KeyboardLayout.whiteKeyDepth - 0.001),
                chamferRadius: 0.001
            )
            box.materials = [ivoryMat]
            let node = SCNNode(geometry: box)
            node.name = key.noteName
            node.position = SCNVector3(
                leftEdge + key.xCenter,
                KeyboardLayout.whiteKeyHeight / 2,
                0
            )
            root.addChildNode(node)
        }

        // Black keys — shifted toward the far side of the keyboard
        let blackZOffset = -((KeyboardLayout.whiteKeyDepth - KeyboardLayout.blackKeyDepth) / 2)
        let blackY = (KeyboardLayout.whiteKeyHeight + KeyboardLayout.blackKeyExtraHeight) / 2
        for key in KeyboardLayout.keys where key.isBlack {
            let box = SCNBox(
                width:        CGFloat(KeyboardLayout.blackKeyWidth),
                height:       CGFloat(KeyboardLayout.whiteKeyHeight + KeyboardLayout.blackKeyExtraHeight),
                length:       CGFloat(KeyboardLayout.blackKeyDepth),
                chamferRadius: 0.0005
            )
            box.materials = [eboxyMat]
            let node = SCNNode(geometry: box)
            node.name = key.noteName
            node.position = SCNVector3(
                leftEdge + key.xCenter,
                blackY,
                blackZOffset
            )
            root.addChildNode(node)
        }

        return root
    }

    /// Bright key outlines for alignment (SETUP › ALIGN and just after
    /// mapping): a line at every white-key boundary, the front and back edges,
    /// and an outline around every black key — flattened into one node so it
    /// costs a single draw call. Hidden by default.
    static func makeOutlines() -> SCNNode {
        let container = SCNNode()
        let mat = SCNMaterial()
        mat.lightingModel        = .constant
        mat.diffuse.contents     = UIColor(red: 0.35, green: 0.95, blue: 1.0, alpha: 0.9)
        mat.blendMode            = .alpha
        mat.isDoubleSided        = true
        mat.writesToDepthBuffer  = false
        mat.readsFromDepthBuffer = false

        let lineW: CGFloat = 0.0014
        let leftEdge = -KeyboardLayout.totalWidth / 2
        let whiteY = KeyboardLayout.whiteKeyHeight + 0.0012
        func line(width: CGFloat, length: CGFloat, at p: SIMD3<Float>) {
            let box = SCNBox(width: width, height: 0.0006, length: length, chamferRadius: 0)
            box.materials = [mat]
            let n = SCNNode(geometry: box)
            n.simdPosition = p
            container.addChildNode(n)
        }

        for i in 0...52 {
            let x = leftEdge + Float(i) * KeyboardLayout.whiteKeyWidth
            line(width: lineW, length: CGFloat(KeyboardLayout.whiteKeyDepth), at: SIMD3<Float>(x, whiteY, 0))
        }
        for z in [KeyboardLayout.whiteKeyDepth / 2, -KeyboardLayout.whiteKeyDepth / 2] {
            line(width: CGFloat(KeyboardLayout.totalWidth), length: lineW, at: SIMD3<Float>(0, whiteY, z))
        }

        let bz = -(KeyboardLayout.whiteKeyDepth - KeyboardLayout.blackKeyDepth) / 2
        let by = KeyboardLayout.whiteKeyHeight + KeyboardLayout.blackKeyExtraHeight + 0.0012
        let hw = KeyboardLayout.blackKeyWidth / 2
        for key in KeyboardLayout.keys where key.isBlack {
            let cx = leftEdge + key.xCenter
            line(width: lineW, length: CGFloat(KeyboardLayout.blackKeyDepth), at: SIMD3<Float>(cx - hw, by, bz))
            line(width: lineW, length: CGFloat(KeyboardLayout.blackKeyDepth), at: SIMD3<Float>(cx + hw, by, bz))
            line(width: CGFloat(KeyboardLayout.blackKeyWidth), length: lineW,
                 at: SIMD3<Float>(cx, by, bz + KeyboardLayout.blackKeyDepth / 2))
        }

        let flat = container.flattenedClone()
        flat.renderingOrder = 30
        flat.isHidden = true
        return flat
    }

    /// Transparent overlay for real-piano mode: faint glow planes over each white key
    /// so key positions are visible without covering the actual piano underneath.
    /// NoteHighway adds the key labels and active-note highlights on top of this.
    static func makeOverlay() -> SCNNode {
        let root     = SCNNode()
        let leftEdge = -KeyboardLayout.totalWidth / 2

        // Shared barely-visible material — additive so it never blocks the camera feed.
        let mat = SCNMaterial()
        mat.lightingModel      = .constant
        mat.diffuse.contents   = UIColor(white: 0.0, alpha: 0.0)
        mat.emission.contents  = UIColor(white: 0.85, alpha: 0.10)
        mat.blendMode          = .add
        mat.isDoubleSided      = true
        mat.writesToDepthBuffer = false

        for key in KeyboardLayout.keys where !key.isBlack {
            let box = SCNBox(
                width:        CGFloat(KeyboardLayout.whiteKeyWidth  - 0.001),
                height:       0.0012,
                length:       CGFloat(KeyboardLayout.whiteKeyDepth  - 0.002),
                chamferRadius: 0.001
            )
            box.materials = [mat]
            let node = SCNNode(geometry: box)
            node.name         = "ov_\(key.noteName)"
            node.simdPosition = SIMD3<Float>(leftEdge + key.xCenter,
                                             KeyboardLayout.whiteKeyHeight + 0.001, 0)
            root.addChildNode(node)
        }

        return root
    }
}
