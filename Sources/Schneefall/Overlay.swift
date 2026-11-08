import AppKit
import MetalKit

/// One transparent, click-through window per screen at desktop level (above the
/// wallpaper, below the desktop icons), covering the screen minus the menu bar.
final class Overlay {
    let window: NSWindow
    let view: SnowView

    init(screen: NSScreen, renderer: Renderer) {
        let rects = Self.snowRects(for: screen)
        window = NSWindow(contentRect: rects.cocoa, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isReleasedWhenClosed = false

        view = SnowView(frame: NSRect(origin: .zero, size: rects.cocoa.size), device: renderer.device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.isPaused = true                   // the engine draws explicitly
        view.enableSetNeedsDisplay = false
        view.layer?.isOpaque = false
        (view.layer as? CAMetalLayer)?.maximumDrawableCount = 2
        view.autoResizeDrawable = false
        view.drawableSize = rects.cocoa.size   // one pixel per point: a quarter of the pixels on Retina, snow is soft anyway
        view.delegate = renderer
        view.snowRect = rects.cg
        window.contentView = view
        window.setFrame(rects.cocoa, display: false)
    }

    /// The screen without its menu bar strip, in Cocoa (y up) and CG global (y down) coordinates.
    static func snowRects(for screen: NSScreen) -> (cocoa: NSRect, cg: CGRect) {
        let f = screen.frame
        let menuBar = f.maxY - screen.visibleFrame.maxY
        let cocoa = NSRect(x: f.minX, y: f.minY, width: f.width, height: f.height - menuBar)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? f.height
        return (cocoa, CGRect(x: cocoa.minX, y: primaryHeight - cocoa.maxY, width: cocoa.width, height: cocoa.height))
    }
}
