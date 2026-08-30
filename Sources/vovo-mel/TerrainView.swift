import Foundation
import SceneKit
import SwiftUI

/// 3-D "terrain" of the mel: x = time, z = band, y = level. Orbit with the mouse (allowsCameraControl).
struct MelTerrain: NSViewRepresentable {
    var mel: [Float]
    var frames: Int
    @EnvironmentObject var model: AppModel

    func makeNSView(context: Context) -> SCNView {
        let v = SCNView()
        v.backgroundColor = NSColor(calibratedRed: 0.05, green: 0.05, blue: 0.07, alpha: 1)
        v.allowsCameraControl = true
        v.autoenablesDefaultLighting = true
        v.antialiasingMode = .multisampling4X
        let scene = SCNScene()
        let cam = SCNNode(); cam.camera = SCNCamera(); cam.camera!.zFar = 1000
        cam.position = SCNVector3(0, 70, 95); cam.look(at: SCNVector3(0, 8, 0))
        scene.rootNode.addChildNode(cam)
        v.scene = scene
        model.terrain = v
        return v
    }

    func updateNSView(_ v: SCNView, context: Context) {
        v.scene?.rootNode.childNode(withName: "terrain", recursively: false)?.removeFromParentNode()
        guard frames > 1, mel.count == frames * 100 else { return }
        let node = SCNNode(geometry: Self.geometry(mel, frames: frames))
        node.name = "terrain"
        v.scene?.rootNode.addChildNode(node)
    }

    static func geometry(_ mel: [Float], frames T: Int, bands: Int = 100) -> SCNGeometry {
        // Downsample time to <= 512 columns so the mesh stays light.
        let step = max(1, T / 512), cols = T / step
        let width: Float = 200, depth: Float = 70, height: Float = 36
        var verts: [SCNVector3] = [], colors: [SCNVector3] = [], normals: [SCNVector3] = []
        verts.reserveCapacity(cols * bands)
        func level(_ c: Int, _ b: Int) -> Float {
            var s: Float = 0
            for k in 0..<step { s += mel[(c * step + k) * bands + b] }
            return (s / Float(step) - MelEdit.displayMin) / (MelEdit.displayMax - MelEdit.displayMin)
        }
        var h = [Float](repeating: 0, count: cols * bands)
        for c in 0..<cols { for b in 0..<bands { h[c * bands + b] = level(c, b) } }
        for c in 0..<cols {
            for b in 0..<bands {
                let y = h[c * bands + b]
                let x = (Float(c) / Float(cols - 1) - 0.5) * width
                let z = (Float(b) / Float(bands - 1) - 0.5) * depth
                verts.append(SCNVector3(x, y * height, -z))
                let (r, g, bl) = MelEdit.color(y * (MelEdit.displayMax - MelEdit.displayMin) + MelEdit.displayMin)
                colors.append(SCNVector3(r, g, bl))
                let dx = (c + 1 < cols ? h[(c + 1) * bands + b] : y) - (c > 0 ? h[(c - 1) * bands + b] : y)
                let dz = (b + 1 < bands ? h[c * bands + b + 1] : y) - (b > 0 ? h[c * bands + b - 1] : y)
                let n = SIMD3<Float>(-dx * height / (width / Float(cols)), 1, dz * height / (depth / Float(bands)))
                let nn = n / max(1e-6, (n * n).sum().squareRoot())
                normals.append(SCNVector3(nn.x, nn.y, nn.z))
            }
        }
        var idx: [Int32] = []
        idx.reserveCapacity((cols - 1) * (bands - 1) * 6)
        for c in 0..<(cols - 1) {
            for b in 0..<(bands - 1) {
                let i = Int32(c * bands + b), j = Int32((c + 1) * bands + b)
                idx += [i, j, i + 1, i + 1, j, j + 1]
            }
        }
        let vsrc = SCNGeometrySource(vertices: verts)
        let nsrc = SCNGeometrySource(normals: normals)
        let cdata = colors.withUnsafeBufferPointer { Data(buffer: $0) }
        let csrc = SCNGeometrySource(data: cdata, semantic: .color, vectorCount: colors.count, usesFloatComponents: true, componentsPerVector: 3,
                                     bytesPerComponent: MemoryLayout<CGFloat>.size, dataOffset: 0, dataStride: MemoryLayout<SCNVector3>.stride)
        let el = SCNGeometryElement(indices: idx, primitiveType: .triangles)
        let g = SCNGeometry(sources: [vsrc, nsrc, csrc], elements: [el])
        let m = SCNMaterial(); m.lightingModel = .lambert; m.isDoubleSided = true
        g.materials = [m]
        return g
    }
}
