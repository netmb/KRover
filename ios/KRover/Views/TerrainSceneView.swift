import SceneKit
import SwiftUI
import simd

/// Rotatable 3D view of the triangulated terrain with adjustable vertical
/// exaggeration. x = east, y = up, z = south (SceneKit convention).
struct TerrainSceneView: UIViewRepresentable {
    let model: TerrainModel
    let exaggeration: Double
    let profileLine: (SIMD2<Double>, SIMD2<Double>)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = SCNScene()
        view.backgroundColor = UIColor(white: 0.06, alpha: 1)
        view.allowsCameraControl = true
        view.antialiasingMode = .multisampling4X
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.inertiaEnabled = true
        context.coordinator.update(view: view, model: model, exaggeration: exaggeration, profileLine: profileLine)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.update(view: view, model: model, exaggeration: exaggeration, profileLine: profileLine)
    }

    final class Coordinator {
        private var revision: UUID?
        private var renderedExaggeration: Double?
        private var renderedProfile: [Double]?
        private let terrainNode = SCNNode()
        private let overlayNode = SCNNode()
        private var center = SIMD2<Double>(0, 0)

        func update(
            view: SCNView,
            model: TerrainModel,
            exaggeration: Double,
            profileLine: (SIMD2<Double>, SIMD2<Double>)?
        ) {
            guard let scene = view.scene else { return }
            if revision != model.revision {
                revision = model.revision
                renderedExaggeration = nil
                renderedProfile = nil
                center = model.displayBounds.center
                buildScene(scene, view: view, model: model, exaggeration: exaggeration)
            }
            let profileKey = profileLine.map { [$0.0.x, $0.0.y, $0.1.x, $0.1.y] }
            guard renderedExaggeration != exaggeration || renderedProfile != profileKey else { return }
            renderedExaggeration = exaggeration
            renderedProfile = profileKey
            terrainNode.scale = SCNVector3(1, Float(exaggeration), 1)
            rebuildOverlay(model: model, exaggeration: exaggeration, profileLine: profileLine)
        }

        private func scenePosition(_ position: SIMD2<Double>, height: Double) -> SCNVector3 {
            SCNVector3(Float(position.x - center.x), Float(height), Float(-(position.y - center.y)))
        }

        private func buildScene(_ scene: SCNScene, view: SCNView, model: TerrainModel, exaggeration: Double) {
            scene.rootNode.childNodes.forEach { $0.removeFromParentNode() }
            terrainNode.geometry = makeTerrainGeometry(model)
            scene.rootNode.addChildNode(terrainNode)
            scene.rootNode.addChildNode(overlayNode)

            let ambient = SCNNode()
            ambient.light = SCNLight()
            ambient.light?.type = .ambient
            ambient.light?.intensity = 380
            scene.rootNode.addChildNode(ambient)

            let sun = SCNNode()
            sun.light = SCNLight()
            sun.light?.type = .directional
            sun.light?.intensity = 620
            sun.eulerAngles = SCNVector3(-Float.pi / 3.2, -Float.pi / 4, 0) // from north-west, elevated
            scene.rootNode.addChildNode(sun)

            let span = max(model.displayBounds.width, model.displayBounds.height, 1)
            let camera = SCNCamera()
            camera.zNear = 0.05
            camera.zFar = span * 20
            camera.fieldOfView = 45
            let cameraNode = SCNNode()
            cameraNode.camera = camera
            let targetHeight = Float(model.heightRange * exaggeration / 2)
            cameraNode.position = SCNVector3(Float(span) * 0.55, Float(span) * 0.75 + targetHeight, Float(span) * 0.95)
            cameraNode.look(at: SCNVector3(0, targetHeight, 0))
            scene.rootNode.addChildNode(cameraNode)
            view.pointOfView = cameraNode
            view.defaultCameraController.target = SCNVector3(0, targetHeight, 0)
        }

        private func makeTerrainGeometry(_ model: TerrainModel) -> SCNGeometry? {
            guard model.canInterpolate else { return nil }
            let positions = model.vertices.map { scenePosition($0.position, height: $0.height - model.minHeight) }
            var normals = [SIMD3<Float>](repeating: .zero, count: positions.count)
            var indices: [UInt32] = []
            indices.reserveCapacity(model.triangles.count * 3)
            for triangle in model.triangles {
                let a = SIMD3(positions[triangle.a].x, positions[triangle.a].y, positions[triangle.a].z)
                let b = SIMD3(positions[triangle.b].x, positions[triangle.b].y, positions[triangle.b].z)
                let c = SIMD3(positions[triangle.c].x, positions[triangle.c].y, positions[triangle.c].z)
                let normal = simd_cross(b - a, c - a) // counter-clockwise in plan → points up
                normals[triangle.a] += normal
                normals[triangle.b] += normal
                normals[triangle.c] += normal
                indices.append(contentsOf: [UInt32(triangle.a), UInt32(triangle.b), UInt32(triangle.c)])
            }
            let normalVectors = normals.map { normal -> SCNVector3 in
                let n = simd_length(normal) > 0 ? simd_normalize(normal) : SIMD3<Float>(0, 1, 0)
                return SCNVector3(n.x, n.y, n.z)
            }
            let colors: [SIMD3<Float>] = model.vertices.map {
                let color = TerrainColorRamp.color(at: model.normalizedHeight($0.height))
                return SIMD3(Float(color.x), Float(color.y), Float(color.z))
            }
            let colorData = colors.withUnsafeBufferPointer { buffer in
                Data(bytes: buffer.baseAddress!, count: buffer.count * MemoryLayout<SIMD3<Float>>.stride)
            }
            let colorSource = SCNGeometrySource(
                data: colorData,
                semantic: .color,
                vectorCount: colors.count,
                usesFloatComponents: true,
                componentsPerVector: 3,
                bytesPerComponent: MemoryLayout<Float>.size,
                dataOffset: 0,
                dataStride: MemoryLayout<SIMD3<Float>>.stride
            )
            let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
            let geometry = SCNGeometry(
                sources: [SCNGeometrySource(vertices: positions), SCNGeometrySource(normals: normalVectors), colorSource],
                elements: [element]
            )
            let material = SCNMaterial()
            material.diffuse.contents = UIColor.white
            material.lightingModel = .lambert
            material.isDoubleSided = true
            geometry.materials = [material]
            return geometry
        }

        private func rebuildOverlay(model: TerrainModel, exaggeration: Double, profileLine: (SIMD2<Double>, SIMD2<Double>)?) {
            overlayNode.childNodes.forEach { $0.removeFromParentNode() }
            let span = max(model.displayBounds.width, model.displayBounds.height, 1)

            // Parcel boundary on the level of the lowest point.
            for ring in model.parcelRings where ring.count >= 2 {
                let base = -0.01 * span
                let vertices = ring.map { scenePosition($0, height: base) }
                var indices: [UInt32] = []
                for index in vertices.indices {
                    indices.append(UInt32(index))
                    indices.append(UInt32((index + 1) % vertices.count))
                }
                overlayNode.addChildNode(lineNode(vertices: vertices, indices: indices, color: .systemYellow))
            }

            // Measurement points with stakes down to the base level.
            let radius = CGFloat(span * 0.006)
            let sphere = SCNSphere(radius: radius)
            sphere.firstMaterial?.diffuse.contents = UIColor.white
            sphere.firstMaterial?.lightingModel = .constant
            var stakeVertices: [SCNVector3] = []
            var stakeIndices: [UInt32] = []
            for vertex in model.vertices {
                let top = scenePosition(vertex.position, height: (vertex.height - model.minHeight) * exaggeration)
                let node = SCNNode(geometry: sphere)
                node.position = SCNVector3(top.x, top.y + Float(radius), top.z)
                overlayNode.addChildNode(node)
                stakeIndices.append(UInt32(stakeVertices.count))
                stakeVertices.append(scenePosition(vertex.position, height: -0.01 * span))
                stakeIndices.append(UInt32(stakeVertices.count))
                stakeVertices.append(top)
            }
            if !stakeVertices.isEmpty {
                overlayNode.addChildNode(lineNode(
                    vertices: stakeVertices,
                    indices: stakeIndices,
                    color: UIColor.white.withAlphaComponent(0.35)
                ))
            }

            // Section line draped onto the surface.
            if let profileLine {
                let lift = span * 0.003
                let samples = model.profile(from: profileLine.0, to: profileLine.1, sampleCount: 200)
                var vertices: [SCNVector3] = []
                var indices: [UInt32] = []
                var previousIndex: UInt32?
                for sample in samples {
                    guard let height = sample.height else {
                        previousIndex = nil
                        continue
                    }
                    let index = UInt32(vertices.count)
                    vertices.append(scenePosition(sample.position, height: (height - model.minHeight) * exaggeration + lift))
                    if let previousIndex { indices.append(contentsOf: [previousIndex, index]) }
                    previousIndex = index
                }
                if !indices.isEmpty {
                    overlayNode.addChildNode(lineNode(vertices: vertices, indices: indices, color: .cyan))
                }
            }
        }

        private func lineNode(vertices: [SCNVector3], indices: [UInt32], color: UIColor) -> SCNNode {
            let geometry = SCNGeometry(
                sources: [SCNGeometrySource(vertices: vertices)],
                elements: [SCNGeometryElement(indices: indices, primitiveType: .line)]
            )
            let material = SCNMaterial()
            material.diffuse.contents = color
            material.emission.contents = color
            material.lightingModel = .constant
            geometry.materials = [material]
            return SCNNode(geometry: geometry)
        }
    }
}
