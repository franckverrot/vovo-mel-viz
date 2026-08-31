import Foundation
import Metal
import MetalKit
import SwiftUI

/// GPU heatmap of a [T,100] log-mel: the mel is uploaded as an R32Float texture, a tiny fragment shader maps
/// it through the fixed viridis-like colormap (same scale as MelEdit.color, so PNG exports and the view agree).
struct MelHeatmap: NSViewRepresentable {
    var mel: [Float]
    var frames: Int
    @EnvironmentObject var model: AppModel

    func makeCoordinator() -> Renderer { Renderer() }

    /// Transparent to hit-testing: the SwiftUI overlays above it own the mouse (scrub, pitch drag).
    final class PassthroughMTKView: MTKView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> MTKView {
        let v = PassthroughMTKView(frame: .zero, device: context.coordinator.device)
        v.colorPixelFormat = .bgra8Unorm
        v.delegate = context.coordinator
        v.enableSetNeedsDisplay = true
        v.isPaused = true
        v.clearColor = MTLClearColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1)
        model.heatmap = v; model.heatmapRenderer = context.coordinator
        return v
    }

    func updateNSView(_ v: MTKView, context: Context) {
        context.coordinator.update(mel: mel, frames: frames)
        v.setNeedsDisplay(v.bounds)
    }

    final class Renderer: NSObject, MTKViewDelegate {
        let device = MTLCreateSystemDefaultDevice()!
        let queue: MTLCommandQueue
        let pipeline: MTLRenderPipelineState
        var texture: MTLTexture?
        var lastCount = 0

        override init() {
            queue = device.makeCommandQueue()!
            let lib = try! device.makeLibrary(source: Renderer.shader, options: nil)
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "mel_vert")
            d.fragmentFunction = lib.makeFunction(name: "mel_frag")
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try! device.makeRenderPipelineState(descriptor: d)
            super.init()
        }

        func update(mel: [Float], frames: Int) {
            guard frames > 0, mel.count == frames * 100 else { texture = nil; return }
            if texture == nil || texture!.height != frames {
                let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: 100, height: frames, mipmapped: false)
                td.usage = .shaderRead
                texture = device.makeTexture(descriptor: td)
            }
            mel.withUnsafeBytes { texture!.replace(region: MTLRegionMake2D(0, 0, 100, frames), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 100 * 4) }
        }

        func encode(_ enc: MTLRenderCommandEncoder, _ tex: MTLTexture) {
            enc.setRenderPipelineState(pipeline)
            enc.setFragmentTexture(tex, index: 0)
            var range = SIMD2<Float>(MelEdit.displayMin, MelEdit.displayMax)
            enc.setFragmentBytes(&range, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        /// Offscreen render with the exact on-screen pipeline (used by GET /screenshot.png).
        func snapshot(width: Int, height: Int) -> CGImage? {
            guard let tex = texture, width > 0, height > 0 else { return nil }
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            td.usage = [.renderTarget, .shaderRead]; td.storageMode = .shared
            guard let out = device.makeTexture(descriptor: td), let cb = queue.makeCommandBuffer() else { return nil }
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = out; rpd.colorAttachments[0].loadAction = .clear; rpd.colorAttachments[0].storeAction = .store
            guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return nil }
            encode(enc, tex); enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            out.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let tex = texture, let rpd = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
                  let cb = queue.makeCommandBuffer(), let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
            encode(enc, tex)
            enc.endEncoding()
            cb.present(drawable)
            cb.commit()
        }

        static let shader = """
        #include <metal_stdlib>
        using namespace metal;
        struct V { float4 pos [[position]]; float2 uv; };
        vertex V mel_vert(uint id [[vertex_id]]) {
            float2 p = float2((id & 1) ? 1.0 : -1.0, (id & 2) ? 1.0 : -1.0);
            V o; o.pos = float4(p, 0, 1); o.uv = float2((p.x + 1) * 0.5, (p.y + 1) * 0.5); return o;
        }
        // viridis-like, 5 stops (matches MelEdit.color on the CPU)
        float3 cmap(float t) {
            const float3 c0 = float3(0.267, 0.005, 0.329), c1 = float3(0.229, 0.322, 0.545), c2 = float3(0.127, 0.566, 0.551),
                         c3 = float3(0.369, 0.788, 0.383), c4 = float3(0.993, 0.906, 0.144);
            t = clamp(t, 0.0, 1.0) * 4.0;
            if (t < 1) return mix(c0, c1, t);
            if (t < 2) return mix(c1, c2, t - 1);
            if (t < 3) return mix(c2, c3, t - 2);
            return mix(c3, c4, t - 3);
        }
        fragment float4 mel_frag(V in [[stage_in]], texture2d<float> mel [[texture(0)]], constant float2 &range [[buffer(0)]]) {
            constexpr sampler s(filter::nearest, address::clamp_to_edge);
            // texture is [T rows, 100 cols] = the mel buffer as-is; screen x = time, screen y (1 = top) = band 99
            float v = mel.sample(s, float2(in.uv.y, in.uv.x)).r;
            float t = (v - range.x) / (range.y - range.x);
            return float4(cmap(t), 1);
        }
        """
    }
}
