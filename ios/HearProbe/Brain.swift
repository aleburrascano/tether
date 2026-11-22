import SwiftUI
import SceneKit

/// The brain picture in the middle of the screen.
///
/// This is an ILLUSTRATION, not a measurement and not a prediction from a brain model: a band along the
/// hearing area of the cortex brightens with how much sound reaches the headphones, and a few loose
/// patches drift slowly so it does not look frozen. Nothing here reads anyone's brain.
final class BrainModel: ObservableObject {
    static let points = 20484, patchCount = 6
    let positions: [Float], normals: [Float], triangles: Data
    private let folds: [Float], band: [Float], patches: [[Float]]
    private var from = [Float](repeating: 0, count: 6), to = [Float](repeating: 0, count: 6)
    private var blend: Float = 1, level: Float = 0, seed: UInt64 = 7
    private(set) var colors: [Float]
    @Published var version = 0
    let loaded: Bool

    init() {
        func file(_ name: String, _ ext: String) -> Data { Bundle.main.url(forResource: name, withExtension: ext).flatMap { try? Data(contentsOf: $0) } ?? Data() }
        let n = BrainModel.points
        let p = file("positions", "i16"), nm = file("normals", "i8"), f = file("folds", "u8"), b = file("band", "u8"), pd = file("patches", "i8")
        triangles = file("triangles", "u16")
        loaded = p.count == n * 6 && nm.count == n * 3 && f.count == n && b.count == n && pd.count == n * 6 && !triangles.isEmpty
        guard loaded else { positions = []; normals = []; folds = []; band = []; patches = []; colors = []; return }
        positions = p.withUnsafeBytes { raw in raw.bindMemory(to: Int16.self).map { Float($0) / 32767 } }
        normals = nm.map { Float(Int8(bitPattern: $0)) / 127 }
        folds = f.map { Float($0) / 255 }
        band = b.map { Float($0) / 255 }
        patches = (0..<6).map { k in pd[(k * n)..<((k + 1) * n)].map { Float(Int8(bitPattern: $0)) / 110 } }
        colors = [Float](repeating: 0.5, count: n * 3)
        step(heard: 0, dt: 0.1)
    }

    private func random() -> Float {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Float(seed >> 40) / Float(1 << 24) * 2 - 1
    }

    /// Advance the picture. `heard` = how much sound reaches the headphones, 0...1.
    func step(heard: Float, dt: Float) {
        guard loaded else { return }
        let target = powf(min(1, max(0, heard) * 1.6), 0.6)
        level += (target - level) * (target > level ? 0.35 : 0.12)
        blend += dt / 1.4
        if blend >= 1 { blend = 0; from = to; for k in 0..<6 { to[k] = random() } }
        var weight = [Float](repeating: 0, count: 6)
        for k in 0..<6 { weight[k] = 0.5 * (from[k] * (1 - blend) + to[k] * blend) }
        for v in 0..<BrainModel.points {
            let fold = folds[v]
            let grey: Float = 0.34 + 0.50 * fold
            var value = band[v]
            for k in 0..<6 { value += weight[k] * patches[k][v] }
            value *= level * (0.55 + 0.45 * fold)
            let hot = min(1, max(0, (value - 0.10) / 0.5)), cold = min(1, max(0, (-value - 0.10) / 0.5)) * 0.55
            var r = grey, g = grey, b = grey + 0.02
            r += (1 - r) * hot; g += ((120 + 105 * hot) / 255 - g) * hot; b += (36.0 / 255 - b) * hot
            r += (60.0 / 255 - r) * cold; g += (150.0 / 255 - g) * cold; b += (1 - b) * cold
            colors[v * 3] = r; colors[v * 3 + 1] = g; colors[v * 3 + 2] = b
        }
        version &+= 1
    }
}

/// The 3D brain. Drag to turn it; let go and it returns to its side view.
struct Brain3DView: UIViewRepresentable {
    @ObservedObject var brain: BrainModel
    static let homeTilt: Float = 0.10, homeTurn: Float = 0

    final class Coordinator: NSObject {
        var node: SCNNode?, tilt: SCNNode?
        var shape: [SCNGeometrySource] = []
        var element: SCNGeometryElement?
        var drawn = -1
        private var grabbedTurn: Float = 0, grabbedTilt: Float = 0

        @objc func drag(_ gesture: UIPanGestureRecognizer) {
            guard let node, let tilt else { return }
            switch gesture.state {
            case .began:
                node.removeAllActions(); tilt.removeAllActions()
                grabbedTurn = node.eulerAngles.y; grabbedTilt = tilt.eulerAngles.x
            case .changed:
                let move = gesture.translation(in: gesture.view)
                node.eulerAngles.y = grabbedTurn + Float(move.x) * 0.012
                tilt.eulerAngles.x = max(-1.1, min(1.1, grabbedTilt + Float(move.y) * 0.012))
            default:
                let turn = SCNAction.rotateTo(x: 0, y: CGFloat(Brain3DView.homeTurn), z: 0, duration: 0.55, usesShortestUnitArc: true)
                let tip = SCNAction.rotateTo(x: CGFloat(Brain3DView.homeTilt), y: 0, z: 0, duration: 0.55, usesShortestUnitArc: true)
                turn.timingMode = .easeOut; tip.timingMode = .easeOut
                node.runAction(turn); tilt.runAction(tip)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.scene = SCNScene()
        view.antialiasingMode = .multisampling4X
        view.autoenablesDefaultLighting = true
        view.addGestureRecognizer(UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.drag(_:))))
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 30
        camera.position = SCNVector3(0, 0, 4.6)
        view.scene?.rootNode.addChildNode(camera)
        view.pointOfView = camera
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        guard brain.loaded else { return }
        let state = context.coordinator, count = BrainModel.points
        if state.node == nil {
            let make = { (values: [Float], kind: SCNGeometrySource.Semantic) in
                SCNGeometrySource(data: values.withUnsafeBufferPointer { Data(buffer: $0) }, semantic: kind, vectorCount: count, usesFloatComponents: true,
                                  componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
            }
            state.shape = [make(brain.positions, .vertex), make(brain.normals, .normal)]
            state.element = SCNGeometryElement(data: brain.triangles, primitiveType: .triangles, primitiveCount: brain.triangles.count / 6, bytesPerIndex: 2)
            let tilt = SCNNode(), node = SCNNode()
            tilt.eulerAngles.x = Brain3DView.homeTilt
            node.eulerAngles.y = Brain3DView.homeTurn
            tilt.addChildNode(node)
            view.scene?.rootNode.addChildNode(tilt)
            state.node = node; state.tilt = tilt
        }
        guard state.drawn != brain.version, let element = state.element else { return }
        state.drawn = brain.version
        let colour = SCNGeometrySource(data: brain.colors.withUnsafeBufferPointer { Data(buffer: $0) }, semantic: .color, vectorCount: count,
                                       usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        let geometry = SCNGeometry(sources: state.shape + [colour], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .lambert
        material.isDoubleSided = true
        geometry.materials = [material]
        state.node?.geometry = geometry
    }
}
