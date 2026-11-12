import AppKit
import IOKit.ps
import SnowCore

/// Frame loop: one display link polls windows, steps the world at a fixed rate and
/// draws every visible overlay. Stops when nothing can be seen: overlays occluded
/// (full-screen Space) or the desktop covered by windows — then a 2 Hz timer only
/// watches the window layout until some desktop shows again.
@MainActor
final class Engine: NSObject {
    private let world: World
    private let renderer: Renderer
    private let tracker = WindowTracker()
    private var overlays: [Overlay] = []
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var accumulator = 0.0
    private var lastPoll: CFTimeInterval = 0
    private var lastMotion: CFTimeInterval = -1
    private var lastPowerCheck: CFTimeInterval = -10
    private var onAC = true
    private var fps: Float = 0
    private var desktopCovered = false
    private var overlayCovered: [Bool] = []   // per overlay: its snow area is hidden behind windows
    private var watchTimer: Timer?
    private let tilt = TiltSensor()
    private var builtInOnly = false   // tilt only makes sense while the MacBook's own display is the only one
    private var lastTiltMotion: CFTimeInterval = -10
    private var boostAngle = 0.0      // gravity angle at the last tilt boost to 60 fps

    /// Let gravity follow how the MacBook is held (accelerometer).
    var followTilt = true { didSet { updateRunning() } }

    /// Menu "Animation": how many frames per second the snow gets.
    var frameRate = FrameRate.optimized
    /// The fastest rate every screen can show: 120 with ProMotion, less once a slower display is attached.
    private(set) var maxFPS = 60

    var paused = false {
        didSet {
            for o in overlays { paused ? o.window.orderOut(nil) : o.window.orderFrontRegardless() }
            updateRunning()
        }
    }

    init(world: World, renderer: Renderer) {
        self.world = world
        self.renderer = renderer
    }

    func start() {
        TiltSensor.setDriver(awake: false)    // a crash or kill may have left the sensor awake
        rebuildOverlays()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged),
                                               name: NSWindow.didChangeOcclusionStateNotification, object: nil)
    }

    @objc private func screensChanged() { rebuildOverlays() }
    @objc private func occlusionChanged() { updateRunning() }

    private func rebuildOverlays() {
        link?.invalidate()
        link = nil
        for o in overlays { o.window.orderOut(nil) }
        overlays = NSScreen.screens.map { Overlay(screen: $0, renderer: renderer) }
        overlayCovered = Array(repeating: false, count: overlays.count)
        builtInOnly = NSScreen.screens.count == 1
            && (NSScreen.screens[0].deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID)
                .map { CGDisplayIsBuiltin($0) != 0 } == true
        world.setScreens(overlays.map { ScreenInfo(frame: $0.view.snowRect) })
        if !paused { for o in overlays { o.window.orderFrontRegardless() } }
        if let first = overlays.first {
            let l = first.view.displayLink(target: self, selector: #selector(tick(_:)))
            l.add(to: .main, forMode: .common)
            link = l
            fps = 0
            maxFPS = NSScreen.screens.map(\.maximumFramesPerSecond).min() ?? 60   // one link draws every screen
        }
        updateRunning()
    }

    private func updateRunning() {
        let visible = !paused && overlays.contains { $0.window.occlusionState.contains(.visible) }
        let run = visible && !desktopCovered
        link?.isPaused = !run
        if !run { lastTimestamp = 0 }
        let tiltWanted = followTilt && builtInOnly
        if run && tiltWanted { tilt.start() } else { tilt.stop() }   // sensor sleeps when nothing is visible
        if !tiltWanted { world.gravityAngle = 0; boostAngle = 0 }
        if visible && desktopCovered {
            if watchTimer == nil {
                watchTimer = Timer.scheduledTimer(timeInterval: 0.5, target: self, selector: #selector(watch),
                                                  userInfo: nil, repeats: true)
            }
        } else {
            watchTimer?.invalidate()
            watchTimer = nil
        }
    }

    @objc private func watch() { pollWindows(now: CACurrentMediaTime(), dragging: false) }

    private func pollWindows(now: CFTimeInterval, dragging: Bool) {
        let poll = tracker.poll()
        let dt = lastPoll == 0 ? Tuning.step : now - lastPoll
        if world.updateWindows(poll.windows, existing: poll.existing, dt: dt, dragging: dragging) { lastMotion = now }
        lastPoll = now
        let frames = poll.windows.map(\.frame)
        overlayCovered = overlays.map { $0.view.snowRect.isCovered(by: frames) }
        let covered = !overlayCovered.contains(false)
        if covered != desktopCovered {
            desktopCovered = covered
            updateRunning()
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let frameDt = lastTimestamp == 0 ? Tuning.step : now - lastTimestamp
        lastTimestamp = now
        let dragging = NSEvent.pressedMouseButtons != 0

        // Window speeds come from poll times, so take those from one clock (the watch timer uses it
        // too), not from the display link's vsync timestamp. While windows move, poll every frame but
        // at most ~60×/s: at 120 fps a window's bounds need not change every frame, and a poll that
        // sees no motion reads as a sudden stop that shakes caps loose.
        let wall = CACurrentMediaTime()
        if (dragging || wall - lastMotion < 0.5) && wall - lastPoll >= 0.75 / 60 || wall - lastPoll >= 0.2 {
            pollWindows(now: wall, dragging: dragging)
            if desktopCovered { return }
        }

        // Only real changes: sensor noise would otherwise re-settle every resting surface.
        if followTilt && builtInOnly, let angle = tilt.screenAngle,
           abs(remainder(angle - world.gravityAngle, 2 * .pi)) > 0.005 {
            // 60 fps only for a real tilt of 2° or more: a MacBook on a lap wobbles by less all the time
            if abs(remainder(angle - boostAngle, 2 * .pi)) > 0.035 {
                lastTiltMotion = now
                boostAngle = angle
            }
            world.gravityAngle = angle
        }

        // One step per frame at the rate the link really delivers: 1/30, 1/60, 1/120 s, or e.g. 1/48
        // on a 144-Hz display asked for 60. Steps sized to the request would judder there.
        let step = min(max(link.targetTimestamp - link.timestamp, 1.0 / 240), 1.0 / 30)
        accumulator = min(accumulator + frameDt, step * Double(Tuning.maxSubsteps))
        while accumulator >= step {
            world.step(dt: step)
            accumulator -= step
        }

        renderer.prepare(world)
        for (i, o) in overlays.enumerated() where o.window.occlusionState.contains(.visible) && !overlayCovered[i] {
            o.view.draw()   // a screen whose snow is all behind windows is not drawn
        }

        if now - lastPowerCheck > 5 {
            lastPowerCheck = now
            onAC = Self.onACPower()
        }
        // Optimiert runs at 60 fps on battery too while something big moves: a window (a held mouse
        // button alone is not enough, most presses move none), falling chunks (not the small spills
        // that trickle off full caps all the time), a tilting MacBook
        let moving = wall - lastMotion < 0.5 || world.clumps.contains { $0.radius > 2.5 } || now - lastTiltMotion < 1
        let wanted = Float(frameRate.fps(screenMax: maxFPS, onAC: onAC,
                                         lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, moving: moving))
        if wanted != fps {
            fps = wanted
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: max(60, wanted), preferred: wanted)
        }
    }

    /// Puts the accelerometer back to sleep before the app quits.
    func shutdown() { tilt.stop() }

    private static func onACPower() -> Bool {
        guard let source = IOPSGetProvidingPowerSourceType(nil)?.takeUnretainedValue() else { return true }
        return (source as String) == kIOPMACPowerKey
    }
}
