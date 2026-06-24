import SwiftUI
import ARKit
import SceneKit

struct ARPassthroughView: UIViewRepresentable {
    let session:     ARSessionModel
    let placement:   PlacementManager
    let calibration: CalibrationManager
    let onTap:       (CGPoint) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(placement: placement, calibration: calibration, onTap: onTap)
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
        var onTap: (CGPoint) -> Void

        init(placement: PlacementManager, calibration: CalibrationManager,
             onTap: @escaping (CGPoint) -> Void) {
            self.placement   = placement
            self.calibration = calibration
            self.onTap       = onTap
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? ARSCNView else { return }
            onTap(gesture.location(in: view))
        }

        // MARK: ARSCNViewDelegate

        func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
            // Virtual piano keyboard
            if anchor.name == "keyboard" {
                return KeyboardNode.make()
            }
            // Calibrated real-piano keyboard — apply measured scale
            if anchor.name == "keyboard_calibrated" {
                let node = KeyboardNode.make()
                if let data = calibration.calibrationData {
                    node.scale = SCNVector3(data.widthScale, 1, data.depthScale)
                }
                return node
            }
            // Corner calibration markers — small bright spheres
            if let name = anchor.name, name.hasPrefix("corner_") {
                return makeCornerMarker()
            }
            // Detected horizontal plane — semi-transparent cyan overlay
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

        private func makeCornerMarker() -> SCNNode {
            let sphere = SCNSphere(radius: 0.012)
            let mat = SCNMaterial()
            mat.diffuse.contents = UIColor.orange
            mat.emission.contents = UIColor.orange.withAlphaComponent(0.6)
            sphere.materials = [mat]
            return SCNNode(geometry: sphere)
        }

        private func makePlaneNode(for anchor: ARPlaneAnchor) -> SCNNode {
            let root = SCNNode()
            let plane = SCNPlane(
                width:  CGFloat(anchor.planeExtent.width),
                height: CGFloat(anchor.planeExtent.height)
            )
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
            guard
                let geomNode = node.childNode(withName: "planeGeom", recursively: false),
                let plane = geomNode.geometry as? SCNPlane
            else { return }
            plane.width  = CGFloat(anchor.planeExtent.width)
            plane.height = CGFloat(anchor.planeExtent.height)
            geomNode.simdPosition = anchor.center
        }
    }
}
