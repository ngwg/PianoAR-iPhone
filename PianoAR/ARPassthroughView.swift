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

        private var handSkeleton: HandSkeletonOverlay?

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

            if handSkeleton == nil {
                handSkeleton = HandSkeletonOverlay(scene: sceneView.scene)
            }

            handTracker.maybeProcess(frame, viewportSize: sceneView.bounds.size)
            handSkeleton?.update(hands: handTracker.snapshot())
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

// MARK: - Hand skeleton overlay

/// Manages 21 joint spheres + 23 bone cylinders per hand (2 hands max).
/// Left hand = green, right hand = blue.
private final class HandSkeletonOverlay {
    private var jointNodes: [SCNNode] = []  // 2 hands × 21 joints
    private var boneNodes:  [SCNNode] = []  // 2 hands × 23 bones

    private static let handSlots  = 2
    private static let jointsPerHand = HandTracker.allJoints.count      // 21
    private static let bonesPerHand  = HandTracker.boneConnections.count // 23

    init(scene: SCNScene) {
        let colors: [UIColor] = [
            UIColor(red: 0.0, green: 1.0, blue: 0.5, alpha: 1),   // left:  green
            UIColor(red: 0.3, green: 0.7, blue: 1.0, alpha: 1),   // right: blue
        ]
        for h in 0..<Self.handSlots {
            let col = colors[h]
            let emCol = col.withAlphaComponent(0.45)

            for _ in 0..<Self.jointsPerHand {
                let geo = SCNSphere(radius: 0.010)
                let mat = SCNMaterial()
                mat.diffuse.contents  = col
                mat.emission.contents = emCol
                geo.materials = [mat]
                let n = SCNNode(geometry: geo)
                n.isHidden = true
                scene.rootNode.addChildNode(n)
                jointNodes.append(n)
            }

            for _ in 0..<Self.bonesPerHand {
                // Unit-height cylinder; we scale Y per frame instead of
                // changing geometry, avoiding per-frame GPU mesh rebuilds.
                let geo = SCNCylinder(radius: 0.006, height: 1.0)
                let mat = SCNMaterial()
                mat.diffuse.contents  = col
                mat.emission.contents = emCol
                mat.isDoubleSided = true
                geo.materials = [mat]
                let n = SCNNode(geometry: geo)
                n.isHidden = true
                scene.rootNode.addChildNode(n)
                boneNodes.append(n)
            }
        }
    }

    func update(hands: [HandTracker.HandResult]) {
        // Hide everything, then re-show what's detected
        jointNodes.forEach { $0.isHidden = true }
        boneNodes.forEach  { $0.isHidden = true }

        for hand in hands {
            // Left hand → slot 0, right hand → slot 1
            let h = hand.isLeft ? 0 : 1
            guard h < Self.handSlots else { continue }
            let jBase = h * Self.jointsPerHand
            let bBase = h * Self.bonesPerHand

            for (i, name) in HandTracker.allJoints.enumerated() {
                guard let pos = hand.joints[name] else { continue }
                jointNodes[jBase + i].simdPosition = pos
                jointNodes[jBase + i].isHidden     = false
            }

            for (i, (fi, ti)) in HandTracker.boneConnections.enumerated() {
                guard let a = hand.joints[HandTracker.allJoints[fi]],
                      let b = hand.joints[HandTracker.allJoints[ti]]
                else { continue }
                positionBone(boneNodes[bBase + i], from: a, to: b)
            }
        }
    }

    private func positionBone(_ node: SCNNode, from a: SIMD3<Float>, to b: SIMD3<Float>) {
        let diff = b - a
        let len  = simd_length(diff)
        guard len > 0.001 else { return }

        let dir = diff / len
        let up  = SIMD3<Float>(0, 1, 0)
        let dot = simd_dot(dir, up)

        let q: simd_quatf
        if dot > 0.9999 {
            q = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)          // identity
        } else if dot < -0.9999 {
            q = simd_quatf(angle: .pi, axis: SIMD3(1, 0, 0))    // 180° flip
        } else {
            q = simd_quatf(from: up, to: dir)
        }

        node.simdPosition    = (a + b) * 0.5
        node.simdOrientation = q
        node.scale           = SCNVector3(1, Float(len), 1)
        node.isHidden        = false
    }
}
