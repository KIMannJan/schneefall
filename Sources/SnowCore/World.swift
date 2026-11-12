import CoreGraphics
import Foundation

public enum Strength: Int, CaseIterable { case light, medium, strong, storm }

public struct WindowInfo: Equatable {
    public let id: UInt32
    public let frame: CGRect          // CG global points
    public init(id: UInt32, frame: CGRect) { self.id = id; self.frame = frame }
}

/// The snow area of one screen (below the menu bar), CG global points.
public struct ScreenInfo: Equatable {
    public let frame: CGRect
    public init(frame: CGRect) { self.frame = frame }
}

public struct Particle {
    public var x, y, vx, vy, radius, area, alpha: Double
    public let isClump: Bool
    public var isCrystal = false, angle = 0.0                    // ice crystal: drawn as a spinning star
    public var fromSpill = false                                 // trickled off a full cap: counts as new snowfall
    var fall = 0.0, swayAmp = 0.0, swayFreq = 0.0, phase = 0.0, spin = 0.0   // flakes only
}

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// The whole snow scene: falling flakes, falling clumps, window piles, grounds.
public final class World {
    public internal(set) var flakes: [Particle] = []
    public internal(set) var clumps: [Particle] = []
    public internal(set) var piles: [UInt32: Pile] = [:]
    var frozen: [UInt32: (heights: [Double], offsetX: Double)] = [:]
    public internal(set) var grounds: [Surface] = []
    public var strength: Strength = .medium { didSet { retarget() } }
    /// Monitors stacked on top of each other share the snow: the upper one gets no
    /// ground, flakes start only on top and fall through to the lower monitor.
    public var stackedFallThrough = false { didSet { rebuildScreens() } }
    /// Gravity in screen space (radians): 0 = straight down, +π/2 = toward the right
    /// edge (MacBook turned onto its right side), π = upside down.
    public var gravityAngle = 0.0 { didSet { applyGravity() } }
    /// The simulation runs in the screen turned by this many quarter turns, so that
    /// gravity points roughly down; `tilt` is the rest (up to ±turnThreshold).
    public private(set) var quarterTurns = 0
    public private(set) var tilt = 0.0
    var spawnEnabled = true

    private var screenInputs: [ScreenInfo] = []   // screen space, as given
    private var screens: [ScreenInfo] = []        // simulation frame
    /// The screens as plain numbers, for the hot loops.
    private var bounds: [(minX: Double, maxX: Double, minY: Double, maxY: Double)] = []
    private var spawnEdges: [(lo: Double, hi: Double, y: Double)] = []   // where respawned flakes start
    private var t = 0.0
    private var meltClock = 0.0                   // thaw is applied once per second, not every step
    private var settleClock = 0.0                 // slopes relax and caps shed at most 60×/s
    private var rng: SplitMix64
    /// Where a particle can land: one surface's x-extent and the band its snow fills. The band lets
    /// `land` skip a surface with two comparisons: almost every particle is still in the air above it.
    private struct Landing {
        let lo, hi, base: Double
        var top: Double                 // base minus the highest column
        let pile: UInt32?               // a window's cap, or
        let ground: Int                 // the ground with this index
        init(_ s: Surface, pile: UInt32?, ground: Int) {
            lo = s.originX
            hi = s.maxX
            base = s.baseY
            top = s.baseY - (s.heights.max() ?? 0)
            self.pile = pile
            self.ground = ground
        }
    }
    private var landings: [Landing] = []          // rebuilt each step

    public init(seed: UInt64) { rng = SplitMix64(state: seed) }

    // MARK: Screens

    public func setScreens(_ newScreens: [ScreenInfo]) {
        screenInputs = newScreens
        rebuildScreens()
    }

    private func rebuildScreens() {
        let newScreens = screenInputs.map { ScreenInfo(frame: Self.turn($0.frame, quarterTurns)) }
        // Grounds run along every bottom edge and flakes start along every top edge. With
        // stackedFallThrough a monitor that has another one below keeps no ground at all,
        // and flakes start only where no monitor continues above.
        let frames = newScreens.map(\.frame)
        func stacked(_ upper: CGRect, over lower: CGRect) -> Bool {   // gap = lower screen's menu bar strip
            lower.minY >= upper.maxY - 1 && lower.minY <= upper.maxY + 60 && lower.minX < upper.maxX && lower.maxX > upper.minX
        }
        func edges(_ f: CGRect, minus others: [CGRect]) -> [(Double, Double)] {
            var parts = [(Double(f.minX), Double(f.maxX))]
            for o in others where stackedFallThrough {
                let (cl, ch) = (Double(o.minX), Double(o.maxX))
                parts = parts.flatMap { (pl, ph) -> [(Double, Double)] in
                    guard cl < ph, ch > pl else { return [(pl, ph)] }
                    return [(pl, cl), (ch, ph)].filter { $0.1 - $0.0 >= Tuning.column }
                }
            }
            return parts
        }
        var newGrounds: [Surface] = []
        spawnEdges = []
        for f in frames {
            if !(stackedFallThrough && frames.contains { stacked(f, over: $0) }) {
                let (lo, columns) = (Double(f.minX), Int((Double(f.width) / Tuning.column).rounded(.up)))
                newGrounds.append(grounds.first { $0.originX == lo && $0.baseY == Double(f.maxY) && $0.heights.count == columns }
                    ?? Surface(originX: lo, baseY: Double(f.maxY), columns: columns, cap: Tuning.groundCap, walls: true))
            }
            for (lo, hi) in edges(f, minus: frames.filter { stacked($0, over: f) }) { spawnEdges.append((lo, hi, Double(f.minY))) }
        }
        grounds = newGrounds
        screens = newScreens
        bounds = newScreens.map(\.frame).map { (Double($0.minX), Double($0.maxX), Double($0.minY), Double($0.maxY)) }
        if screens.isEmpty { flakes.removeAll(); clumps.removeAll(); return }
        for i in flakes.indices where !onScreen(flakes[i]) { flakes[i] = makeFlake(initial: true) }
        clumps.removeAll { !onScreen($0) }
        retarget()
    }

    private func onScreen(_ p: Particle) -> Bool {
        screens.contains { s in
            let f = s.frame
            return p.x >= Double(f.minX) && p.x <= Double(f.maxX) && p.y >= Double(f.minY) - 40 && p.y <= Double(f.maxY)
        }
    }

    /// Adds (spread over the screens) or removes flakes to match the strength.
    private func retarget() {
        let area = screens.reduce(0.0) { $0 + Double($1.frame.width * $1.frame.height) }
        let target = Int((area / 1e6 * Tuning.flakeDensity[strength.rawValue]).rounded())
        if flakes.count > target { flakes.removeLast(flakes.count - target) }
        while spawnEnabled && flakes.count < target { flakes.append(makeFlake(initial: true)) }
    }

    func makeFlake(initial: Bool) -> Particle {
        let r = Double.random(in: 0.8...2.6, using: &rng)
        let k = (r - 0.8) / 1.8
        let x: Double, y: Double
        if initial {   // anywhere on a screen, weighted by width
            var pick = Double.random(in: 0..<screens.reduce(0.0) { $0 + Double($1.frame.width) }, using: &rng)
            var f = screens[0].frame
            for s in screens {
                if pick < Double(s.frame.width) { f = s.frame; break }
                pick -= Double(s.frame.width)
            }
            x = Double(f.minX) + Double.random(in: 0...Double(f.width), using: &rng)
            y = Double(f.minY) + Double.random(in: 0...Double(f.height), using: &rng)
        } else {       // along a spawn edge, just inside the screen's top: above it a flake would sit in
                       // the ground layer of a monitor stacked on top and land there instead
            var pick = Double.random(in: 0..<spawnEdges.reduce(0.0) { $0 + $1.hi - $1.lo }, using: &rng)
            var e = spawnEdges[0]
            for s in spawnEdges {
                if pick < s.hi - s.lo { e = s; break }
                pick -= s.hi - s.lo
            }
            x = Double.random(in: e.lo...e.hi, using: &rng)
            y = e.y + r / 2
        }
        var p = Particle(x: x, y: y, vx: 0, vy: 0, radius: r, area: .pi * r * r * Tuning.compaction,
                         alpha: 0.55 + 0.45 * k, isClump: false)
        p.fall = 30 + k * 50 + Double.random(in: -5...5, using: &rng)
        p.swayAmp = Double.random(in: 5...20, using: &rng)
        p.swayFreq = Double.random(in: 0.5...1.5, using: &rng)
        p.phase = Double.random(in: 0...(2 * .pi), using: &rng)
        if Double.random(in: 0..<1, using: &rng) < Tuning.crystalShare {   // now and then: an ice crystal
            p.isCrystal = true
            p.radius = Double.random(in: 6...9, using: &rng)
            p.fall = Double.random(in: 95...135, using: &rng)
            p.swayAmp = Double.random(in: 2...6, using: &rng)
            p.spin = Double.random(in: -1.5...1.5, using: &rng)
            p.angle = Double.random(in: 0...(2 * .pi), using: &rng)
            p.alpha = 0.95
        }
        return p
    }

    // MARK: Windows

    /// `windows`: currently visible windows. `existing`: every window ID that
    /// still exists anywhere (other Spaces, minimized), or nil if not queried —
    /// a vanished window that still exists keeps its pile frozen; one that is
    /// gone (closed) drops all of its snow.
    @discardableResult
    public func updateWindows(_ windows: [WindowInfo], existing: Set<UInt32>?, dt: Double, dragging: Bool) -> Bool {
        var changed = false
        var seen = Set<UInt32>()
        let visible = Set(windows.map(\.id))
        var vanishing = Set(piles.keys.filter { !visible.contains($0) })
        for input in windows {
            let w = WindowInfo(id: input.id, frame: Self.turn(input.frame, quarterTurns))
            seen.insert(w.id)
            if piles[w.id] != nil {
                if piles[w.id]!.frame != w.frame { changed = true }
                piles[w.id]!.windowMoved(to: w.frame, dt: dt, dragging: dragging)
            } else if let old = vanishing.first(where: { piles[$0]!.frame == w.frame }) {
                // Native tabs (Finder, Terminal) are separate windows in one frame: the cap stays.
                piles[w.id] = piles.removeValue(forKey: old)
                vanishing.remove(old)
                frozen[w.id] = nil
                changed = true
            } else if let f = frozen.removeValue(forKey: w.id) {
                piles[w.id] = Pile(restoring: f.heights, offsetX: f.offsetX, frame: w.frame)
                changed = true
            } else {
                piles[w.id] = Pile(frame: w.frame)
                changed = true
            }
        }
        for id in Array(piles.keys) where !seen.contains(id) {
            var p = piles.removeValue(forKey: id)!
            changed = true
            if existing?.contains(id) ?? true {
                frozen[id] = (p.surface.heights, p.offsetX)
            } else {
                addClumps(p.shedAll())
            }
        }
        if let existing { frozen = frozen.filter { existing.contains($0.key) } }
        return changed
    }

    // MARK: Simulation

    public func step(dt: Double) {
        t += dt
        // Lying snow starts to drift downhill at slideStart rather than at the 50° repose angle.
        let bias = Tuning.reposeMaxStep * tan(tilt) / tan(Tuning.slideStart)
        meltClock += dt
        let melting = meltClock >= 1
        let keep = exp(-Tuning.meltRate * meltClock)
        if melting { meltClock = 0 }
        // Slopes relax and caps shed at most 60×/s (every step up to 60 fps, every other one at 120):
        // snow flows and breaks off alike at every frame rate.
        settleClock += dt
        let settling = settleClock >= Tuning.step * 0.999
        if settling { settleClock = min(settleClock - Tuning.step, Tuning.step) }
        for id in Array(piles.keys) {
            addClumps(piles[id]!.step(dt: dt, tilt: tilt, shed: settling))
            // Level: what trickles off a full cap is redirected snowfall and obeys the caps.
            // Tilted: it is lying snow sliding off, which must never be destroyed.
            if settling { addSpills(piles[id]!.surface.settle(bias: bias), asSnowfall: abs(tilt) < Tuning.slideStart) }
            if melting { piles[id]!.surface.melt(keep: keep) }
        }
        let slide = Pile.creep(tilt: tilt) * dt          // ground snow slides as one slab, like the caps
        for i in grounds.indices {
            grounds[i].slide(by: slide)
            if settling { _ = grounds[i].settle(bias: bias) }
            if melting { grounds[i].melt(keep: keep) }
        }
        landings.removeAll(keepingCapacity: true)
        for (id, pile) in piles { landings.append(Landing(pile.surface, pile: id, ground: -1)) }
        for (i, ground) in grounds.enumerated() { landings.append(Landing(ground, pile: nil, ground: i)) }
        moveFlakes(dt)
        moveClumps(dt)
    }

    public func clearAll() {
        for id in Array(piles.keys) {
            piles[id]!.surface.heights = Array(repeating: 0, count: piles[id]!.surface.heights.count)
            piles[id]!.surface.pendingSpill = (0, 0)
        }
        for i in grounds.indices { grounds[i].heights = Array(repeating: 0, count: grounds[i].heights.count) }
        frozen.removeAll()
        clumps.removeAll()
    }

    private func moveFlakes(_ dt: Double) {
        var wind = Tuning.wind * Tuning.windScale[strength.rawValue] * (sin(2 * .pi * t / 40) + 0.5 * sin(2 * .pi * t / 13 + 1.3))
        var swirl = 1.0, rush = 1.0                       // storm: wild turbulence, faster fall
        if strength == .storm {
            wind += Tuning.stormWind * (1 + 0.5 * sin(2 * .pi * t / 6) + 0.3 * sin(2 * .pi * t / 1.7))
            (swirl, rush) = (3, 1.35)
        }
        let (along, down) = (sin(tilt), cos(tilt))
        var i = 0
        while i < flakes.count {
            var f = flakes[i]
            f.vx = wind * (f.isCrystal ? 0.4 : 1.3 - f.radius / 2.6) + f.swayAmp * swirl * sin(f.swayFreq * swirl * t + f.phase)
                + f.fall * rush * along
            f.vy = f.fall * rush * down
            if f.isCrystal { f.angle = (f.angle + f.spin * dt).truncatingRemainder(dividingBy: 2 * .pi) }
            let y0 = f.y
            f.x = wrapped(from: f.x, to: f.x + f.vx * dt, at: f.y)
            f.y += f.vy * dt
            if land(f, from: y0, width: Tuning.column) || outOfBounds(f) {
                if spawnEnabled {
                    flakes[i] = makeFlake(initial: false)
                    i += 1
                } else {
                    flakes.swapAt(i, flakes.count - 1)
                    flakes.removeLast()
                }
                continue
            }
            flakes[i] = f
            i += 1
        }
    }

    private func moveClumps(_ dt: Double) {
        let drag = Tuning.clumpGravity / Tuning.clumpTerminal   // terminal speed along gravity
        var i = 0
        while i < clumps.count {
            var c = clumps[i]
            c.vy += (Tuning.clumpGravity * cos(tilt) - drag * c.vy) * dt
            c.vx += (Tuning.clumpGravity * sin(tilt) - drag * c.vx) * dt
            let y0 = c.y
            let x1 = sideways(from: c.x, to: c.x + c.vx * dt, at: c.y)
            if x1 == c.x { c.vx = 0 }          // hit a screen side
            c.x = x1
            c.y += c.vy * dt
            if land(c, from: y0, width: 2 * c.radius) || outOfBounds(c) {
                clumps.swapAt(i, clumps.count - 1)
                clumps.removeLast()
                continue
            }
            clumps[i] = c
            i += 1
        }
    }

    /// Screen sides are walls: sideways motion only where a screen continues
    /// (a neighbouring monitor, or the menu-bar gap below a stacked one).
    private func sideways(from x0: Double, to x1: Double, at y: Double) -> Double {
        covered(x1, y) || !covered(x0, y) ? x1 : x0
    }

    /// Flakes blown against a screen side re-enter at the opposite side instead of
    /// piling up into a curtain along the wall (matters in a storm).
    private func wrapped(from x0: Double, to x1: Double, at y: Double) -> Double {
        guard !covered(x1, y), covered(x0, y) else { return x1 }
        let band = screens.map(\.frame).filter { y >= Double($0.minY) - 100 && y <= Double($0.maxY) + 60 }
        guard let lo = band.map({ Double($0.minX) }).min(), let hi = band.map({ Double($0.maxX) }).max() else { return x0 }
        return x1 > x0 ? lo : hi - 0.01
    }

    private func covered(_ x: Double, _ y: Double) -> Bool {
        for b in bounds where x >= b.minX && x < b.maxX && y >= b.minY - 100 && y <= b.maxY + 60 { return true }
        return false
    }

    /// Off every screen (e.g. fell past a monitor that keeps no ground).
    private func outOfBounds(_ p: Particle) -> Bool { !covered(p.x, p.y) }

    /// Deposits the particle on the highest surface whose snow line its bottom has
    /// reached, provided it started above that surface's base (i.e. it did not come
    /// from behind the window). Testing "inside the layer" rather than "crossed the
    /// line" keeps a dense curtain of clumps from falling through snow that just
    /// piled up beneath it.
    private func land(_ p: Particle, from y0: Double, width: Double) -> Bool {
        let b0 = y0 + p.radius / 2, b1 = p.y + p.radius / 2
        var best = Double.infinity
        var hit = -1
        for (k, s) in landings.enumerated() where p.x >= s.lo && p.x < s.hi && b1 >= s.top && b0 <= s.base {
            let line: Double?           // only now look at the real snow line
            if let id = s.pile { line = piles[id]!.surface.lineY(at: p.x) } else { line = grounds[s.ground].lineY(at: p.x) }
            if let l = line, b1 >= l, l < best { best = l; hit = k }
        }
        guard hit >= 0 else { return false }
        let capped = !p.isClump || p.fromSpill            // only snow that merely moves ignores the caps
        // The deposit may raise the band; refresh it, because later particles in this step must see the new snow.
        let s = landings[hit]
        if let id = s.pile {
            piles[id]!.surface.deposit(area: p.area, x: p.x, width: width, capped: capped)
            landings[hit].top = s.base - (piles[id]!.surface.heights.max() ?? 0)
        } else {
            grounds[s.ground].deposit(area: p.area, x: p.x, width: width, capped: capped)
            landings[hit].top = s.base - (grounds[s.ground].heights.max() ?? 0)
        }
        return true
    }

    // MARK: Orientation

    /// Screen point → simulation frame: `q` quarter turns, chosen so gravity points to +y.
    static func turn(_ x: Double, _ y: Double, _ q: Int) -> (x: Double, y: Double) {
        switch q & 3 {
        case 1: return (-y, x)
        case 2: return (-x, -y)
        case 3: return (y, -x)
        default: return (x, y)
        }
    }

    static func turn(_ r: CGRect, _ q: Int) -> CGRect {
        guard q & 3 != 0 else { return r }
        let a = turn(Double(r.minX), Double(r.minY), q), b = turn(Double(r.maxX), Double(r.maxY), q)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Simulation frame → screen point (CG global), for drawing.
    public func toScreen(_ x: Double, _ y: Double) -> (x: Double, y: Double) {
        Self.turn(x, y, (4 - quarterTurns) & 3)
    }

    private func applyGravity() {
        let quarter = Double.pi / 2
        var q = quarterTurns
        if abs(remainder(gravityAngle - Double(q) * quarter, 2 * .pi)) > Tuning.turnThreshold {   // wide hysteresis
            q = ((Int((gravityAngle / quarter).rounded()) % 4) + 4) % 4
        }
        tilt = remainder(gravityAngle - Double(q) * quarter, 2 * .pi)
        if q != quarterTurns { reorient(to: q) }
    }

    /// Turned past a quarter: everything lying slides off as clumps, and all moving
    /// snow is re-expressed in the new frame. Piles return with the next window poll.
    private func reorient(to q: Int) {
        for id in Array(piles.keys) { addClumps(piles[id]!.shedAll()) }
        for g in grounds { addClumps(g.chunks(0..<g.heights.count, vx: 0, vy: 0)) }
        piles.removeAll()
        frozen.removeAll()
        grounds.removeAll()
        let back = (4 - quarterTurns) & 3
        func convert(_ p: inout Particle) {
            let s = Self.turn(p.x, p.y, back), v = Self.turn(p.vx, p.vy, back)
            (p.x, p.y) = Self.turn(s.x, s.y, q)
            (p.vx, p.vy) = Self.turn(v.x, v.y, q)
        }
        for i in flakes.indices { convert(&flakes[i]) }
        for i in clumps.indices { convert(&clumps[i]) }
        quarterTurns = q
        rebuildScreens()
    }

    private func addClumps(_ chunks: [Chunk]) {
        for c in chunks {
            clumps.append(Particle(x: c.x, y: c.y,
                                   vx: c.vx + Double.random(in: -15...15, using: &rng),
                                   vy: c.vy + Double.random(in: -30...0, using: &rng),
                                   radius: min(8, max(1.2, (c.area / .pi).squareRoot())),
                                   area: c.area, alpha: 0.95, isClump: true))
        }
    }

    private func addSpills(_ spills: [Spill], asSnowfall: Bool) {
        for s in spills {
            clumps.append(Particle(x: s.x + s.direction * 1.5, y: s.y, vx: s.direction * 25, vy: 0,
                                   radius: min(8, max(1.2, (s.area / .pi).squareRoot())),
                                   area: s.area, alpha: 0.95, isClump: true, fromSpill: asSnowfall))
        }
    }
}
