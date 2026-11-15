import Metal
import QuartzCore
let dev = MTLCreateSystemDefaultDevice()!
let q = dev.makeCommandQueue()!
let layer = CAMetalLayer()
layer.device = dev; layer.pixelFormat = .bgra8Unorm
layer.bounds = CGRect(x: 0, y: 0, width: 2560, height: 1440); layer.contentsScale = 1
layer.drawableSize = CGSize(width: 1280, height: 720)
let t0 = Date()
var got = 0
for _ in 0..<30 {
    guard let d = layer.nextDrawable() else { print("nextDrawable nil"); break }
    got += 1
    let cb = q.makeCommandBuffer()!
    cb.present(d); cb.commit(); cb.waitUntilCompleted()
}
print("drawables: \(got)/30 in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s, size \(layer.drawableSize), framebufferOnly=\(layer.framebufferOnly)")
