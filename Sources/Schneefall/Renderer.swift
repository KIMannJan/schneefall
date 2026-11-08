import AppKit
import MetalKit
import SnowCore

/// An overlay's Metal view; `snowRect` is the area it shows, in CG global points.
final class SnowView: MTKView {
    var snowRect: CGRect = .zero
}

/// Draws the whole world once per frame into every overlay view: snow surfaces
/// (caps + grounds) as triangle strips, flakes + clumps as instanced soft discs.
final class Renderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let surfacePipeline: MTLRenderPipelineState
    private let particlePipeline: MTLRenderPipelineState
    private var surfaceBuffer: MTLBuffer?
    private var surfaceStrips: [Range<Int>] = []
    private var particleBuffer: MTLBuffer?
    private var particleCount = 0
    // ponytail: rings of 3 reused buffers, no fence — the GPU is long done with a slot three
    // uploads later; add a semaphore if frames ever pile up
    private var surfaceRing: [MTLBuffer?] = [nil, nil, nil], particleRing: [MTLBuffer?] = [nil, nil, nil]
    private var surfaceSlot = 0, particleSlot = 0

    /// Lying snow changes rarely: each surface's strip is rebuilt only when its heights,
    /// position or the frame's orientation changed, and nothing is uploaded if none did.
    private enum SurfaceKey: Hashable { case ground(Int), pile(UInt32) }
    private struct CachedStrip { let revision: Int, originX: Double, baseY: Double, turns: Int, verts: [SIMD4<Float>] }
    private var stripCache: [SurfaceKey: CachedStrip] = [:]

    /// Copies `data` into a reused buffer, growing it when needed.
    private func upload(_ data: [SIMD4<Float>], into buffer: inout MTLBuffer?) -> MTLBuffer? {
        guard !data.isEmpty else { return nil }
        let length = data.count * MemoryLayout<SIMD4<Float>>.stride
        if (buffer?.length ?? 0) < length {
            buffer = device.makeBuffer(length: max(length, 2 * (buffer?.length ?? 0)), options: .storageModeShared)
        }
        guard let buffer else { return nil }
        data.withUnsafeBytes { buffer.contents().copyMemory(from: $0.baseAddress!, byteCount: length) }
        return buffer
    }

    init?(device: MTLDevice) {
        self.device = device
        guard let queue = device.makeCommandQueue() else { return nil }
        self.queue = queue
        let library: MTLLibrary
        do { library = try device.makeLibrary(source: Self.shaders, options: nil) } catch {
            NSLog("Schneefall: shader compile failed: \(error)")
            return nil
        }
        func pipeline(_ vertex: String, _ fragment: String) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertex)
            d.fragmentFunction = library.makeFunction(name: fragment)
            let c = d.colorAttachments[0]!
            c.pixelFormat = .bgra8Unorm
            c.isBlendingEnabled = true                       // premultiplied alpha
            c.sourceRGBBlendFactor = .one
            c.sourceAlphaBlendFactor = .one
            c.destinationRGBBlendFactor = .oneMinusSourceAlpha
            c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            do { return try device.makeRenderPipelineState(descriptor: d) } catch {
                NSLog("Schneefall: pipeline \(vertex)/\(fragment) failed: \(error)")
                return nil
            }
        }
        guard let s = pipeline("surfaceVertex", "surfaceFragment"),
              let p = pipeline("particleVertex", "particleFragment") else { return nil }
        surfacePipeline = s
        particlePipeline = p
    }

    /// Builds this frame's vertex data; shared by every overlay view.
    func prepare(_ world: World) {
        let surfaces = world.grounds.enumerated().map { (SurfaceKey.ground($0.offset), $0.element) }
            + world.piles.map { (SurfaceKey.pile($0.key), $0.value.surface) }
        var changed = surfaces.count != stripCache.count
        var fresh: [SurfaceKey: CachedStrip] = [:]
        for (key, s) in surfaces {
            if let c = stripCache[key], c.revision == s.revision, c.originX == s.originX, c.baseY == s.baseY,
               c.turns == world.quarterTurns {
                fresh[key] = c
            } else {
                fresh[key] = CachedStrip(revision: s.revision, originX: s.originX, baseY: s.baseY,
                                         turns: world.quarterTurns, verts: Self.strip(s, world))
                changed = true
            }
        }
        stripCache = fresh
        if changed {
            var verts: [SIMD4<Float>] = []
            surfaceStrips.removeAll(keepingCapacity: true)
            for (key, _) in surfaces {
                let v = fresh[key]!.verts
                guard !v.isEmpty else { continue }
                surfaceStrips.append(verts.count..<verts.count + v.count)
                verts += v
            }
            surfaceSlot = (surfaceSlot + 1) % surfaceRing.count
            surfaceBuffer = upload(verts, into: &surfaceRing[surfaceSlot])
        }

        var parts: [SIMD4<Float>] = []   // per particle: (x, y, radius, alpha), (crystal, angle, -, -)
        parts.reserveCapacity(2 * (world.flakes.count + world.clumps.count))
        func addParticle(_ p: Particle) {
            let at = world.toScreen(p.x, p.y)
            parts.append(SIMD4(Float(at.x), Float(at.y), Float(p.radius), Float(p.alpha)))
            parts.append(SIMD4(p.isCrystal ? 1 : 0, Float(p.angle), 0, 0))
        }
        world.flakes.forEach(addParticle)
        world.clumps.forEach(addParticle)
        particleCount = parts.count / 2
        particleSlot = (particleSlot + 1) % particleRing.count
        particleBuffer = upload(parts, into: &particleRing[particleSlot])
    }

    /// One surface as a triangle strip in screen space: per column the top (with a 1 pt
    /// AA fringe above the snow) and the base. Empty when there is no snow.
    private static func strip(_ s: Surface, _ world: World) -> [SIMD4<Float>] {
        guard s.heights.contains(where: { $0 > 0.05 }) else { return [] }
        let heights = smoothed(s.heights, openEnds: !s.walls)
        var verts: [SIMD4<Float>] = []
        verts.reserveCapacity(2 * heights.count + 4)
        func push(_ x: Double, _ h: Double) {
            let top = world.toScreen(x, s.baseY - h - 1), base = world.toScreen(x, s.baseY)
            verts.append(SIMD4(Float(top.x), Float(top.y), -1, Float(h)))
            verts.append(SIMD4(Float(base.x), Float(base.y), Float(h), Float(h)))
        }
        push(s.originX, s.walls ? heights[0] : 0)          // caps taper to the ledge, grounds meet the wall
        for (i, h) in heights.enumerated() { push(s.originX + (Double(i) + 0.5) * Tuning.column, h) }
        push(s.maxX, s.walls ? heights[heights.count - 1] : 0)
        return verts
    }

    /// Display-only smoothing. A flake is coarse next to a 2-pt column, so the raw
    /// profile is jagged up to the repose limit; two 7-tap box passes (~28 pt
    /// triangle kernel) read as snow. Physics keeps the raw heights. With open ends
    /// (caps) missing neighbours count as bare ledge, so a cap tapers off instead
    /// of ending in a wall; grounds (walls) repeat their edge.
    static func smoothed(_ heights: [Double], openEnds: Bool) -> [Double] {
        var a = heights
        let n = a.count
        var prefix = [Double](repeating: 0, count: n + 1)
        for _ in 0..<2 {
            for i in 0..<n { prefix[i + 1] = prefix[i] + a[i] }
            for i in 0..<n {
                let lo = max(0, i - 3), hi = min(n - 1, i + 3)
                a[i] = (prefix[hi + 1] - prefix[lo]) / (openEnds ? 7 : Double(hi - lo + 1))
            }
        }
        return a
    }

    func draw(in view: MTKView) {
        guard let view = view as? SnowView, let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable, let cmd = queue.makeCommandBuffer() else { return }
        encode(cmd, pass, view.snowRect)
        cmd.present(drawable)
        cmd.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    private func encode(_ cmd: MTLCommandBuffer, _ pass: MTLRenderPassDescriptor, _ rect: CGRect) {
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        var r = SIMD4<Float>(Float(rect.minX), Float(rect.minY), Float(rect.width), Float(rect.height))
        let rLen = MemoryLayout<SIMD4<Float>>.stride
        if let buf = surfaceBuffer {
            enc.setRenderPipelineState(surfacePipeline)
            enc.setVertexBuffer(buf, offset: 0, index: 0)
            enc.setVertexBytes(&r, length: rLen, index: 1)
            for strip in surfaceStrips {
                enc.drawPrimitives(type: .triangleStrip, vertexStart: strip.lowerBound, vertexCount: strip.count)
            }
        }
        if let buf = particleBuffer {
            enc.setRenderPipelineState(particlePipeline)
            enc.setVertexBuffer(buf, offset: 0, index: 0)
            enc.setVertexBytes(&r, length: rLen, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: particleCount)
        }
        enc.endEncoding()
    }

    /// Offscreen render of `rect` (CG global points) at `scale`, transparent background.
    func snapshot(_ world: World, rect: CGRect, scale: Int) -> CGImage? {
        prepare(world)
        let w = Int(rect.width) * scale, h = Int(rect.height) * scale
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared                      // Apple silicon; snapshot is a dev tool
        guard let tex = device.makeTexture(descriptor: desc), let cmd = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = tex
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        encode(cmd, pass, rect)
        cmd.commit()
        cmd.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        tex.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private static let shaders = """
    #include <metal_stdlib>
    using namespace metal;

    // rect = (minX, minY, width, height) of the view in CG global points (y down)
    static float4 toClip(float2 p, float4 rect) {
        return float4((p.x - rect.x) / rect.z * 2.0 - 1.0, 1.0 - (p.y - rect.y) / rect.w * 2.0, 0.0, 1.0);
    }

    struct SurfaceOut { float4 position [[position]]; float depth; float height; };

    // vertex = (x, y, depth below the snow top in pt, column height in pt)
    vertex SurfaceOut surfaceVertex(uint vid [[vertex_id]],
                                    const device float4 *verts [[buffer(0)]],
                                    constant float4 &rect [[buffer(1)]]) {
        float4 v = verts[vid];
        SurfaceOut o;
        o.position = toClip(v.xy, rect);
        o.depth = v.z;
        o.height = v.w;
        return o;
    }

    fragment float4 surfaceFragment(SurfaceOut in [[stage_in]]) {
        float a = clamp(in.depth + 0.5, 0.0, 1.0) * clamp(in.height / 0.75, 0.0, 1.0);
        float3 c = mix(float3(0.97, 0.98, 1.0), float3(0.82, 0.88, 0.96), smoothstep(0.0, 20.0, in.depth));
        // soft contact shadow along the ledge keeps the snow readable on light windows
        c *= mix(0.85, 1.0, smoothstep(0.0, 4.0, in.height - in.depth));
        return float4(c * a, a);
    }

    struct ParticleOut { float4 position [[position]]; float2 offset; float radius; float alpha; float crystal; float angle; };

    // instance = (x, y, radius, alpha), (crystal flag, angle, -, -); 4-vertex strip per instance
    vertex ParticleOut particleVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                      const device float4 *inst [[buffer(0)]],
                                      constant float4 &rect [[buffer(1)]]) {
        float4 p = inst[2 * iid];
        float4 q = inst[2 * iid + 1];
        float2 corner = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
        float extent = p.z + 1.0;
        ParticleOut o;
        o.position = toClip(p.xy + corner * extent, rect);
        o.offset = corner * extent;
        o.radius = p.z;
        o.alpha = p.w;
        o.crystal = q.x;
        o.angle = q.y;
        return o;
    }

    fragment float4 particleFragment(ParticleOut in [[stage_in]]) {
        float d = length(in.offset) / in.radius;
        if (in.crystal < 0.5) {
            float a = smoothstep(1.0, 0.55, d) * in.alpha;
            return float4(a, a, a, a);
        }
        // ice crystal: six arms, short twigs in between, spinning, faint glint
        float r = length(in.offset);
        float t = atan2(in.offset.y, in.offset.x) + in.angle + 12.566371;   // positive for fmod
        const float sector = 1.0471976;                                     // 60 degrees
        float w = in.radius;                                                // stroke width scales with size
        float arms = smoothstep(0.11 * w, 0.04 * w, abs(sin(fmod(t, sector) - 0.5 * sector)) * r) * smoothstep(1.0, 0.85, d);
        float twigs = smoothstep(0.09 * w, 0.03 * w, abs(sin(fmod(t + 0.5 * sector, sector) - 0.5 * sector)) * r)
                    * smoothstep(0.55, 0.42, d);
        float core = smoothstep(0.3, 0.1, d);
        float a = max(max(arms, twigs), core) * in.alpha * (0.8 + 0.2 * cos(3.0 * in.angle));
        return float4(float3(0.86, 0.95, 1.0) * a, a);
    }
    """
}
