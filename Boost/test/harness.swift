// Headless "game" for VaporBoost tests. No window is created.
// Renders a textured pattern that moves DX app-pixels to the right each frame,
// at the app resolution, into CAMetalLayer drawables and presents them through
// MTLCommandBuffer.present(_:) — the same path Wine's Metal backends use.
//
// usage: harness <frames> <appW> <appH> <layerW> <layerH> [dx]

import Metal
import QuartzCore

let args = CommandLine.arguments
let frames = Int(args[1])!, appW = Int(args[2])!, appH = Int(args[3])!
let layerW = Int(args[4])!, layerH = Int(args[5])!
let dx = args.count > 6 ? Float(args[6])! : 8

let device = MTLCreateSystemDefaultDevice()!
let queue = device.makeCommandQueue()!
let layer = CAMetalLayer()
layer.device = device
layer.pixelFormat = .bgra8Unorm
layer.contentsScale = 1
layer.bounds = CGRect(x: 0, y: 0, width: layerW, height: layerH)
layer.drawableSize = CGSize(width: appW, height: appH)

let src = """
#include <metal_stdlib>
using namespace metal;
struct V { float4 pos [[position]]; };
vertex V vs(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    V o; o.pos = float4(p * 2 - 1, 0, 1); return o;
}
// Pattern defined in app-pixel space, shifted by `offset` pixels to the right.
fragment float4 fs(V in [[stage_in]], constant float &offset [[buffer(0)]]) {
    float2 p = in.pos.xy - float2(offset, 0);
    float a = 0.5 + 0.5 * sin(p.x * 0.11) * cos(p.y * 0.07);
    float b = 0.5 + 0.5 * sin((p.x + p.y) * 0.031 + 1.3);
    float c = fract(sin(dot(floor(p / 16), float2(12.9898, 78.233))) * 43758.5453);
    return float4(a, b, mix(a, c, 0.6), 1);
}
"""
let lib = try! device.makeLibrary(source: src, options: nil)
let pd = MTLRenderPipelineDescriptor()
pd.vertexFunction = lib.makeFunction(name: "vs")
pd.fragmentFunction = lib.makeFunction(name: "fs")
pd.colorAttachments[0].pixelFormat = layer.pixelFormat
let pso = try! device.makeRenderPipelineState(descriptor: pd)

let reported = layer.drawableSize
var nilDrawables = 0
let start = Date()
for f in 0..<frames {
    guard let drawable = layer.nextDrawable() else { nilDrawables += 1; continue }
    let rp = MTLRenderPassDescriptor()
    rp.colorAttachments[0].texture = drawable.texture
    rp.colorAttachments[0].loadAction = .clear
    rp.colorAttachments[0].storeAction = .store
    let cb = queue.makeCommandBuffer()!
    let enc = cb.makeRenderCommandEncoder(descriptor: rp)!
    enc.setRenderPipelineState(pso)
    var offset = Float(f) * dx
    enc.setFragmentBytes(&offset, length: 4, index: 0)
    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    enc.endEncoding()
    cb.present(drawable)
    cb.commit()
    cb.waitUntilCompleted()
    if let e = cb.error { print("command buffer error: \(e)"); exit(3) }
}
let elapsed = Date().timeIntervalSince(start)
print("harness: frames=\(frames) nil=\(nilDrawables) app=\(appW)x\(appH) layer=\(layerW)x\(layerH)",
      "reportedDrawableSize=\(Int(reported.width))x\(Int(reported.height))",
      String(format: "elapsed=%.2fs", elapsed))
