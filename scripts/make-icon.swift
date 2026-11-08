// Draws the 1024×1024 app icon: swift scripts/make-icon.swift <out.png>
import AppKit

let size = 1024.0
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.translateBy(x: 0, y: size)   // draw y-down
ctx.scaleBy(x: 1, y: -1)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
func gradient(_ top: UInt32, _ bottom: UInt32, from y0: CGFloat, to y1: CGFloat) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [rgb(top), rgb(bottom)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: y0), end: CGPoint(x: 0, y: y1), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

// Body: macOS icon grid (824 pt rounded square, soft drop shadow)
let body = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: rgb(0x000000, 0.35))
ctx.addPath(body); ctx.setFillColor(rgb(0x14254A)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(body); ctx.clip()
gradient(0x0E1C3B, 0x35598F, from: 100, to: 924)

// Falling flakes (deterministic scatter)
var seed: UInt32 = 7
func rnd() -> CGFloat { seed = seed &* 1_664_525 &+ 1_013_904_223; return CGFloat(seed >> 8) / CGFloat(1 << 24) }
for _ in 0..<46 {
    let x = 120 + rnd() * 784, y = 120 + rnd() * 700, r = 4 + rnd() * 8
    ctx.setFillColor(rgb(0xFFFFFF, 0.55 + rnd() * 0.45))
    ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
}

// Ice crystal
func crystal(at c: CGPoint, radius: CGFloat) {
    ctx.setStrokeColor(rgb(0xDDF3FF)); ctx.setLineWidth(radius * 0.17); ctx.setLineCap(.round)
    for k in 0..<6 {
        let a = CGFloat(k) * .pi / 3 + .pi / 2
        let tip = CGPoint(x: c.x + cos(a) * radius, y: c.y + sin(a) * radius)
        ctx.move(to: c); ctx.addLine(to: tip)
        let mid = CGPoint(x: c.x + cos(a) * radius * 0.55, y: c.y + sin(a) * radius * 0.55)
        for side in [-1.0, 1.0] {
            let b = a + CGFloat(side) * .pi / 4
            ctx.move(to: mid); ctx.addLine(to: CGPoint(x: mid.x + cos(b) * radius * 0.32, y: mid.y + sin(b) * radius * 0.32))
        }
    }
    ctx.strokePath()
}
crystal(at: CGPoint(x: 735, y: 255), radius: 62)

// Ground drift
let ground = CGMutablePath()
ground.move(to: CGPoint(x: 90, y: 870))
ground.addCurve(to: CGPoint(x: 420, y: 858), control1: CGPoint(x: 200, y: 830), control2: CGPoint(x: 320, y: 875))
ground.addCurve(to: CGPoint(x: 940, y: 835), control1: CGPoint(x: 560, y: 835), control2: CGPoint(x: 760, y: 870))
ground.addLine(to: CGPoint(x: 940, y: 940)); ground.addLine(to: CGPoint(x: 90, y: 940)); ground.closeSubpath()
ctx.saveGState(); ctx.addPath(ground); ctx.clip(); gradient(0xFFFFFF, 0xC9DBF2, from: 830, to: 930); ctx.restoreGState()

// Window
let win = CGRect(x: 225, y: 475, width: 574, height: 320)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 30, color: rgb(0x000000, 0.45))
ctx.addPath(CGPath(roundedRect: win, cornerWidth: 38, cornerHeight: 38, transform: nil)); ctx.setFillColor(rgb(0xF3F5F9)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: win, cornerWidth: 38, cornerHeight: 38, transform: nil)); ctx.clip()
ctx.setFillColor(rgb(0xE1E6EF)); ctx.fill(CGRect(x: win.minX, y: win.minY, width: win.width, height: 66))
ctx.restoreGState()
for (i, color) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
    ctx.setFillColor(rgb(UInt32(color)))
    ctx.fillEllipse(in: CGRect(x: win.minX + 34 + CGFloat(i) * 42, y: win.minY + 20, width: 26, height: 26))
}

// Snow cap on the window, tapering where the rounded corners start
let cap = CGMutablePath()
cap.move(to: CGPoint(x: 252, y: 476))
cap.addCurve(to: CGPoint(x: 330, y: 402), control1: CGPoint(x: 268, y: 430), control2: CGPoint(x: 290, y: 405))
cap.addCurve(to: CGPoint(x: 520, y: 398), control1: CGPoint(x: 400, y: 392), control2: CGPoint(x: 450, y: 412))
cap.addCurve(to: CGPoint(x: 700, y: 404), control1: CGPoint(x: 590, y: 386), control2: CGPoint(x: 640, y: 410))
cap.addCurve(to: CGPoint(x: 772, y: 476), control1: CGPoint(x: 745, y: 400), control2: CGPoint(x: 760, y: 440))
cap.closeSubpath()
ctx.saveGState(); ctx.addPath(cap); ctx.clip(); gradient(0xFFFFFF, 0xC7D9F0, from: 395, to: 478); ctx.restoreGState()

// A clump sliding off the right edge
ctx.setFillColor(rgb(0xFFFFFF))
ctx.fillEllipse(in: CGRect(x: 790, y: 520, width: 40, height: 36))
ctx.fillEllipse(in: CGRect(x: 818, y: 588, width: 24, height: 22))
ctx.restoreGState()

let image = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
