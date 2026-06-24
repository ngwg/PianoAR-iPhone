import SwiftUI
import ARKit
import SceneKit

struct ARPassthroughView: UIViewRepresentable {
    let session:     ARSessionModel
    let placement:   PlacementManager
    let calibration: CalibrationManager
    let handTracker: HandTracker
    let onTap:       (CGPoint) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(placement: placement, calibration: calibration,
                    handTracker: handTracker, onTap: onTap)
    }

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = session.session
        view.delegate = context.coordinator
        view.automaticallyUpdatesLighting = true
        view.rendersContinuously = true
        view.preferredFramesPerSecond = 60
        view.contentMode = .scaleAspectFill
        view.debugOptions = []

        placement.sceneView   = view
        calibration.sceneView = view

        // 2-D hand silhouette overlay, sits above the AR scene
        let overlay = HandOverlayView(frame: .zero)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.isUserInteractionEnabled = false
        view.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: view.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        context.coordinator.handOverlay = overlay

        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        placement.sceneView   = uiView
        calibration.sceneView = uiView
        context.coordinator.onTap = onTap
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, ARSCNViewDelegate {
        let placement:   PlacementManager
        let calibration: CalibrationManager
        let handTracker: HandTracker
        var onTap: (CGPoint) -> Void
        weak var handOverlay: HandOverlayView?

        init(placement: PlacementManager, calibration: CalibrationManager,
             handTracker: HandTracker, onTap: @escaping (CGPoint) -> Void) {
            self.placement   = placement
            self.calibration = calibration
            self.handTracker = handTracker
            self.onTap       = onTap
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? ARSCNView else { return }
            onTap(gesture.location(in: view))
        }

        // MARK: Per-frame update

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            guard let sceneView = renderer as? ARSCNView,
                  let frame = sceneView.session.currentFrame
            else { return }

            handTracker.maybeProcess(frame, viewportSize: sceneView.bounds.size)
            let hands = handTracker.snapshot()
            DispatchQueue.main.async { [weak self] in
                self?.handOverlay?.update(hands)
            }
        }

        // MARK: Anchor → node

        func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
            if anchor.name == "keyboard" {
                return KeyboardNode.make()
            }
            if anchor.name == "keyboard_calibrated" {
                let node = KeyboardNode.make()
                if let data = calibration.calibrationData {
                    node.scale = SCNVector3(data.widthScale, 1, data.depthScale)
                }
                return node
            }
            if let name = anchor.name, name.hasPrefix("corner_") {
                return makeCornerMarker()
            }
            if let plane = anchor as? ARPlaneAnchor {
                placement.onPlaneAdded()
                return makePlaneNode(for: plane)
            }
            return nil
        }

        func renderer(_ renderer: SCNSceneRenderer,
                      didUpdate node: SCNNode, for anchor: ARAnchor) {
            guard let plane = anchor as? ARPlaneAnchor else { return }
            updatePlaneNode(node, for: plane)
        }

        // MARK: Small node builders

        private func makeCornerMarker() -> SCNNode {
            let sphere = SCNSphere(radius: 0.012)
            let mat = SCNMaterial()
            mat.diffuse.contents  = UIColor.orange
            mat.emission.contents = UIColor.orange.withAlphaComponent(0.6)
            sphere.materials = [mat]
            return SCNNode(geometry: sphere)
        }

        private func makePlaneNode(for anchor: ARPlaneAnchor) -> SCNNode {
            let root = SCNNode()
            let plane = SCNPlane(width:  CGFloat(anchor.planeExtent.width),
                                 height: CGFloat(anchor.planeExtent.height))
            let mat = SCNMaterial()
            mat.diffuse.contents = UIColor.cyan.withAlphaComponent(0.22)
            mat.isDoubleSided = true
            plane.materials = [mat]
            let geomNode = SCNNode(geometry: plane)
            geomNode.name = "planeGeom"
            geomNode.eulerAngles.x = -.pi / 2
            geomNode.simdPosition = anchor.center
            root.addChildNode(geomNode)
            return root
        }

        private func updatePlaneNode(_ node: SCNNode, for anchor: ARPlaneAnchor) {
            guard let geomNode = node.childNode(withName: "planeGeom", recursively: false),
                  let plane = geomNode.geometry as? SCNPlane
            else { return }
            plane.width  = CGFloat(anchor.planeExtent.width)
            plane.height = CGFloat(anchor.planeExtent.height)
            geomNode.simdPosition = anchor.center
        }
    }
}

// MARK: - 2D hand silhouette overlay

/// Draws a Quest-style transparent hand mesh directly in screen space using
/// the raw 2D Vision landmark positions — no 3D projection, so it stays
/// perfectly aligned with the real hand in the camera feed.
final class HandOverlayView: UIView {
    private var hands: [HandTracker.HandResult] = []

    func update(_ hands: [HandTracker.HandResult]) {
        self.hands = hands
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.clear(rect)
        for hand in hands { drawHand(hand, in: ctx) }
    }

    private func drawHand(_ hand: HandTracker.HandResult, in ctx: CGContext) {
        // Quest-style: thick rounded strokes that overlap and fill the palm/fingers.
        // Same teal for both hands; left/right distinction is subtle.
        let handColor = UIColor(red: 0.05, green: 0.90, blue: 0.95, alpha: 0.55)
        let glowColor = UIColor(red: 0.00, green: 0.80, blue: 1.00, alpha: 0.70)

        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setShadow(offset: .zero, blur: 22, color: glowColor.cgColor)
        ctx.setStrokeColor(handColor.cgColor)

        // Draw each bone as a thick rounded segment.
        // Overlapping caps at joints fill in the palm naturally.
        for (fi, ti) in HandTracker.boneConnections {
            let nameA = HandTracker.allJoints[fi]
            let nameB = HandTracker.allJoints[ti]
            guard let pa = hand.joints2D[nameA],
                  let pb = hand.joints2D[nameB] else { continue }

            // Wrist-to-MCP and palm-bar segments get extra width for a fuller palm look
            let isPalm = (fi == 0) || (fi == 5 && ti == 9) || (fi == 9 && ti == 13) || (fi == 13 && ti == 17)
            ctx.setLineWidth(isPalm ? 44 : 30)

            ctx.move(to: pa)
            ctx.addLine(to: pb)
            ctx.strokePath()
        }

        ctx.restoreGState()
    }
}
