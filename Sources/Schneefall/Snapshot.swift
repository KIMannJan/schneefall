import AppKit
import ImageIO
import UniformTypeIdentifiers
import SnowCore

/// `Schneefall --snapshot <path.png>`: renders a synthetic desktop offscreen so the
/// shaders can be checked without touching real windows. Desktop level means the
/// windows sit in front of the snow, so they are composited on top.
enum Snapshot {
    static func run(path: String) -> Int32 {
        let screen = CGRect(x: 0, y: 0, width: 900, height: 600)
        let a = CGRect(x: 100, y: 180, width: 380, height: 260)
        var b = CGRect(x: 430, y: 330, width: 400, height: 200)
        let world = World(seed: 7)
        world.setScreens([ScreenInfo(frame: screen)])
        world.strength = .strong
        let dt = Tuning.step
        func tick(dragging: Bool) {
            world.updateWindows([WindowInfo(id: 1, frame: a), WindowInfo(id: 2, frame: b)], existing: nil, dt: dt, dragging: dragging)
            world.step(dt: dt)
        }
        for _ in 0..<Int(240 / dt) { tick(dragging: false) }
        for _ in 0..<6 { b = b.offsetBy(dx: 30, dy: 0); tick(dragging: true) }   // jerky drag → clumps
        for _ in 0..<Int(0.15 / dt) { tick(dragging: true) }

        guard let device = MTLCreateSystemDefaultDevice(), let renderer = Renderer(device: device),
              let snow = renderer.snapshot(world, rect: screen, scale: 2) else {
            fputs("snapshot: render failed\n", stderr)
            return 1
        }
        let w = snow.width, h = snow.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 1 }
        ctx.setFillColor(CGColor(srgbRed: 0x4F / 255, green: 0xB8 / 255, blue: 0xC4 / 255, alpha: 1))   // teal wallpaper
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(snow, in: CGRect(x: 0, y: 0, width: w, height: h))
        let light = CGColor(srgbRed: 0xEC / 255, green: 0xEC / 255, blue: 0xEE / 255, alpha: 1)   // like a white window
        let dark = CGColor(srgbRed: 0x3A / 255, green: 0x42 / 255, blue: 0x52 / 255, alpha: 1)
        for (r, color) in [(a, light), (b, dark)] {   // CG context is y-up
            ctx.setFillColor(color)
            ctx.fill(CGRect(x: r.minX * 2, y: CGFloat(h) - r.maxY * 2, width: r.width * 2, height: r.height * 2))
        }
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                         UTType.png.identifier as CFString, 1, nil) else { return 1 }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? 0 : 1
    }
}
