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

        private var fingerNodes: [SCNNode] = []   // pool of 10 sphere nodes

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

        // MARK: Per-frame update — hand marker positions

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            guard let sceneView = renderer as? ARSCNView,
                  let frame = sceneView.session.currentFrame
            else { return }

            // Lazy-create the finger node pool once the scene is ready
            if fingerNodes.isEmpty {
                fingerNodes = (0..<10).map { _ in makeFingerNode(in: renderer.scene) }
            }

            // Drive Vision at ~20 fps
            handTracker.maybeProcess(frame, viewportSize: sceneView.bounds.size)

            // Update node positions from the latest snapshot
            let tips = handTracker.snapshot()
            for (i, node) in fingerNodes.enumerated() {
                if i < tips.count {
                    node.simdPosition = tips[i].worldPosition
                    node.isHidden = false
                } else {
                    node.isHidden = true
                }
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

        // MARK: Node builders

        private func makeFingerNode(in scene: SCNScene) -> SCNNode {
            let sphere = SCNSphere(radius: 0.015)
            let mat = SCNMaterial()
            mat.diffuse.contents  = UIColor(red: 1.0, green: 0.55, blue: 0.0, alpha: 1)
            mat.emission.contents = UIColor(red: 0.6, green: 0.3,  blue: 0.0, alpha: 1)
            sphere.materials = [mat]
            let node = SCNNode(geometry: sphere)
            node.isHidden = true
            scene.rootNode.addChildNode(node)
            return node
        }

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
