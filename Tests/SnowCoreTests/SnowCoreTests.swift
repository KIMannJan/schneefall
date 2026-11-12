import Testing
import Foundation
@testable import SnowCore

// MARK: - Surface

@Test func settleRespectsRepose() {
    var s = Surface(originX: 0, baseY: 100, columns: 9, cap: 60, walls: true)
    s.heights[4] = 30
    let v0 = s.volume
    for _ in 0..<2000 { _ = s.settle() }
    for i in 0..<8 { #expect(abs(s.heights[i] - s.heights[i + 1]) <= Tuning.reposeMaxStep + 0.01) }
    #expect(abs(s.volume - v0) < 1e-6)
}

@Test func depositClampsAtCap() {
    var s = Surface(originX: 0, baseY: 100, columns: 10, cap: 24, walls: true)
    for _ in 0..<1000 { s.deposit(area: 10, x: 10, width: 4) }
    #expect(s.heights.max()! <= 24)
    #expect(s.lineY(at: 10)! == 76)
    #expect(s.lineY(at: -1) == nil)
    #expect(s.lineY(at: 20) == nil)
}

@Test func openEdgesSpillAndConserveVolume() {
    var s = Surface(originX: 0, baseY: 100, columns: 10, cap: 24, walls: false)
    s.heights = Array(repeating: 20, count: 10)            // 400 pt²
    var spilled = 0.0
    for _ in 0..<2000 { spilled += s.settle().reduce(0) { $0 + $1.area } }
    #expect(spilled > 0)
    #expect(s.heights[0] <= Tuning.reposeMaxStep + 0.01)
    #expect(abs(s.volume + spilled + s.pendingSpill.left + s.pendingSpill.right - 400) < 1e-6)
}

// MARK: - Pile

let win = CGRect(x: 300, y: 400, width: 400, height: 200)

func flatPile(_ h: Double) -> Pile {
    var p = Pile(frame: win)
    p.surface.heights = Array(repeating: h, count: p.surface.heights.count)
    return p
}

func drive(_ p: inout Pile, _ frames: [CGRect], dragging: Bool = true) -> [Chunk] {
    var shed: [Chunk] = []
    for f in frames { p.windowMoved(to: f, dt: Tuning.step, dragging: dragging); shed += p.step(dt: Tuning.step) }
    return shed
}

@Test func translationRule() {
    let a = CGRect(x: 0, y: 0, width: 100, height: 100)
    #expect(Motion.translation(from: a, to: a.offsetBy(dx: 10, dy: 5)) == 10)                         // moved
    #expect(Motion.translation(from: a, to: CGRect(x: -10, y: 0, width: 110, height: 100)) == 0)      // left edge resized
    #expect(Motion.translation(from: a, to: CGRect(x: 0, y: 0, width: 120, height: 100)) == 0)        // right edge resized
    #expect(Motion.translation(from: a, to: CGRect(x: 20, y: 0, width: 120, height: 100)) == 30)      // both edges → follow the center
}

@Test func gentleDragKeepsSnow() {                     // 120 pt in 1 s, a_max ≈ 592 pt/s² < μg
    var p = flatPile(10)
    let frames = (1...60).map { win.offsetBy(dx: 60 * (1 - cos(Double.pi * Double($0) / 60)), dy: 0) }
    let shed = drive(&p, frames) + drive(&p, Array(repeating: frames.last!, count: 60))
    #expect(shed.isEmpty)
    #expect(abs(p.offsetX - Tuning.cornerInset) < 1)
}

@Test func jerkyDragShedsTrailingEdge() {              // from standstill to 1800 pt/s
    var p = flatPile(10)
    let frames = (1...10).map { win.offsetBy(dx: Double($0) * 30, dy: 0) }
    let shed = drive(&p, frames)
    #expect(!shed.isEmpty)
    #expect(shed.allSatisfy { $0.x < Double(frames.last!.minX) + Tuning.cornerInset })
}

@Test func shrinkDropsOverhang() {
    var p = flatPile(10)
    let v0 = p.surface.volume
    let shed = drive(&p, [CGRect(x: 300, y: 400, width: 200, height: 200)], dragging: false)
    #expect(!shed.isEmpty && shed.allSatisfy { $0.x > 500 - Tuning.cornerInset })
    #expect(abs(shed.reduce(0) { $0 + $1.area } + p.surface.volume - v0) < 1e-6)
    #expect(p.surface.maxX <= 500 - Tuning.cornerInset + Tuning.overhang + Tuning.column)
}

@Test func programmaticMoveIsRigid() {                 // e.g. Show Desktop
    var p = flatPile(10)
    let shed = drive(&p, [win.offsetBy(dx: 800, dy: 300)], dragging: false)
    #expect(shed.isEmpty)
    #expect(p.surface.originX == 1100 + Tuning.cornerInset && p.surface.baseY == 700)
}

@Test func fastDropLiftsThenLands() {                  // 2400 pt/s downward
    var p = flatPile(10)
    let frames = (1...5).map { win.offsetBy(dx: 0, dy: Double($0) * 40) }
    _ = drive(&p, frames)
    #expect(p.surface.baseY < Double(frames.last!.minY) - 1)
    _ = drive(&p, Array(repeating: frames.last!, count: 60))
    #expect(p.surface.baseY == Double(frames.last!.minY))
}

@Test func upwardJerkHopIsBounded() {                  // 3000 pt/s upward, then stop
    var p = flatPile(10)
    let frames = (1...10).map { win.offsetBy(dx: 0, dy: -Double($0) * 50) }
    _ = drive(&p, frames)
    var peak = 0.0
    for _ in 0..<120 {
        _ = drive(&p, [frames.last!])
        peak = max(peak, frames.last!.minY - p.surface.baseY)
    }
    #expect(peak > 1 && peak <= 51)
}

@Test func capStopsBeforeRoundedCorners() {           // no overhang above rounded window corners
    var p = flatPile(10)
    #expect(p.surface.originX >= Double(win.minX) + Tuning.cornerInset - Tuning.column)
    #expect(p.surface.maxX <= Double(win.maxX) - Tuning.cornerInset + Tuning.column)
    _ = p.step(dt: Tuning.step)
    #expect(p.surface.originX >= Double(win.minX) + Tuning.cornerInset - Tuning.overhang - Tuning.column)
    #expect(p.surface.maxX <= Double(win.maxX) - Tuning.cornerInset + Tuning.overhang + Tuning.column)
}

@Test func degenerateDtStaysFinite() {
    var p = flatPile(10)
    p.windowMoved(to: win.offsetBy(dx: 5, dy: 0), dt: 0, dragging: true)
    _ = p.step(dt: Tuning.step)
    p.windowMoved(to: win.offsetBy(dx: 9, dy: 0), dt: 300, dragging: true)
    _ = p.step(dt: Tuning.step)
    #expect(p.surface.originX.isFinite && p.surface.baseY.isFinite)
}

@Test func restoredIntoNarrowerWindowShedsOverhang() {
    let p = flatPile(10)
    var r = Pile(restoring: p.surface.heights, offsetX: p.offsetX, frame: CGRect(x: 300, y: 400, width: 300, height: 200))
    let shed = r.step(dt: Tuning.step)
    #expect(!shed.isEmpty && shed.allSatisfy { $0.x > 600 - Tuning.cornerInset })
}

// MARK: - World

func world(_ screens: [CGRect] = [CGRect(x: 0, y: 0, width: 1000, height: 800)]) -> World {
    let w = World(seed: 42)
    w.setScreens(screens.map { ScreenInfo(frame: $0) })
    return w
}
func run(_ w: World, seconds: Double) { for _ in 0..<Int(seconds / Tuning.step) { w.step(dt: Tuning.step) } }

@Test func snowAccumulatesUnderCaps() {
    let w = world(); w.strength = .strong
    w.updateWindows([WindowInfo(id: 1, frame: win)], existing: nil, dt: Tuning.step, dragging: false)
    run(w, seconds: 120)
    #expect(w.piles[1]!.surface.volume > 0)
    #expect(w.grounds[0].volume > 0)
    w.piles[1]!.surface.heights = w.piles[1]!.surface.heights.map { _ in 23.9 }
    run(w, seconds: 30)
    #expect(w.piles[1]!.surface.heights.max()! <= Tuning.pileCap)
    #expect(w.grounds[0].heights.max()! <= Tuning.groundCap)
}

@Test func closedWindowSnowLandsOnWindowBelow() {
    let w = world(); w.spawnEnabled = false; w.flakes.removeAll()
    let upper = WindowInfo(id: 1, frame: CGRect(x: 300, y: 300, width: 400, height: 100))
    let lower = WindowInfo(id: 2, frame: CGRect(x: 200, y: 600, width: 600, height: 150))
    w.updateWindows([upper, lower], existing: nil, dt: Tuning.step, dragging: false)
    w.piles[1]!.surface.heights = w.piles[1]!.surface.heights.map { _ in 10 }
    let v1 = w.piles[1]!.surface.volume
    w.updateWindows([lower], existing: [2], dt: Tuning.step, dragging: false)      // window 1 closed
    #expect(w.piles[1] == nil && !w.clumps.isEmpty)
    run(w, seconds: 3)
    #expect(w.clumps.isEmpty)
    #expect(w.piles[2]!.surface.volume >= 0.85 * v1)
}

@Test func minimizedWindowKeepsPile() {
    let w = world(); w.spawnEnabled = false
    w.updateWindows([WindowInfo(id: 1, frame: win)], existing: nil, dt: Tuning.step, dragging: false)
    w.piles[1]!.surface.heights = w.piles[1]!.surface.heights.map { _ in 10 }
    let h = w.piles[1]!.surface.heights
    w.updateWindows([], existing: [1], dt: Tuning.step, dragging: false)           // minimized / other Space
    #expect(w.piles[1] == nil && w.clumps.isEmpty)
    let moved = win.offsetBy(dx: 200, dy: 50)
    w.updateWindows([WindowInfo(id: 1, frame: moved)], existing: nil, dt: Tuning.step, dragging: false)
    #expect(w.piles[1]!.surface.heights == h)
    #expect(w.piles[1]!.surface.originX == Double(moved.minX) + Tuning.cornerInset)
}

@Test func frozenPilesOfGoneWindowsArePruned() {
    let w = world()
    w.updateWindows([WindowInfo(id: 1, frame: win)], existing: nil, dt: Tuning.step, dragging: false)
    w.updateWindows([], existing: [1], dt: Tuning.step, dragging: false)
    #expect(w.frozen[1] != nil)
    w.updateWindows([], existing: [], dt: Tuning.step, dragging: false)
    #expect(w.frozen[1] == nil && w.clumps.isEmpty)
}

@Test func multiScreenSpawnsAndGroundsPerScreen() {
    let w = world([CGRect(x: 0, y: 0, width: 1000, height: 800), CGRect(x: -800, y: -200, width: 800, height: 600)])
    #expect(w.grounds.count == 2)
    #expect(w.grounds.contains { $0.originX == -800 && $0.baseY == 400 })
    #expect(w.flakes.contains { $0.x < 0 } && w.flakes.contains { $0.x > 0 })
}

@Test func screenChangeKeepsFlakesInside() {
    let w = world([CGRect(x: 0, y: 0, width: 2000, height: 1000)])
    w.setScreens([ScreenInfo(frame: CGRect(x: 0, y: 0, width: 800, height: 600))])
    #expect(w.flakes.allSatisfy { $0.x >= 0 && $0.x <= 800 })
    #expect(w.grounds.count == 1 && w.grounds[0].baseY == 600)
}

@Test func strengthRetargetsFlakeCount() {
    let w = world(); w.strength = .light
    let a = w.flakes.count
    w.strength = .strong
    #expect(w.flakes.count > 3 * a)
}

@Test func clearAllMeltsEverything() {
    let w = world()
    w.updateWindows([WindowInfo(id: 1, frame: win)], existing: nil, dt: Tuning.step, dragging: false)
    run(w, seconds: 60)
    w.clearAll()
    #expect(w.piles[1]!.surface.volume == 0 && w.grounds[0].volume == 0 && w.clumps.isEmpty)
}

@Test func oversizedWindowStaysBounded() {
    let w = world()
    w.updateWindows([WindowInfo(id: 1, frame: CGRect(x: -500, y: 300, width: 3000, height: 400))], existing: nil, dt: Tuning.step, dragging: false)
    run(w, seconds: 5)
    #expect(w.piles[1]!.surface.heights.count <= 1500 + 8)
}

@Test func stackedScreensBothGetSnow() {               // monitor right above the MacBook
    let w = world([CGRect(x: 0, y: -600, width: 1000, height: 600), CGRect(x: 0, y: 0, width: 1000, height: 800)])
    run(w, seconds: 60)                                 // initial flakes have landed; from now on only new ones
    let (u, l) = (w.grounds[0].volume, w.grounds[1].volume)
    run(w, seconds: 60)
    let (du, dl) = (w.grounds[0].volume - u, w.grounds[1].volume - l)
    #expect(du > 0)
    #expect(dl > 0.5 * du)                              // same width → same supply
}

// MARK: - Coverage

@Test func coverageDetectsHiddenDesktop() {
    let area = CGRect(x: 0, y: 25, width: 1600, height: 1000)
    #expect(area.isCovered(by: [CGRect(x: 0, y: 25, width: 1600, height: 1000)]))                       // maximized
    #expect(area.isCovered(by: [CGRect(x: 0, y: 25, width: 800, height: 1000),
                                CGRect(x: 800, y: 0, width: 800, height: 1100)]))                       // two halves
    #expect(!area.isCovered(by: [CGRect(x: 0, y: 25, width: 1590, height: 1000)]))                      // 10 pt gap
    #expect(!area.isCovered(by: [CGRect(x: 0, y: 25, width: 800, height: 1000),
                                 CGRect(x: 850, y: 25, width: 750, height: 1000)]))                     // gap in between
    #expect(!area.isCovered(by: []))
}

// MARK: - Thaw

@Test func meltShrinksSnowThatIsNotFed() {             // ground under windows slowly melts away
    let w = world(); w.spawnEnabled = false; w.flakes.removeAll()
    w.updateWindows([WindowInfo(id: 1, frame: win)], existing: nil, dt: Tuning.step, dragging: false)
    w.piles[1]!.surface.heights = w.piles[1]!.surface.heights.map { _ in 20 }
    w.grounds[0].heights = w.grounds[0].heights.map { _ in 30 }
    run(w, seconds: 600)
    let factor = exp(-600 * Tuning.meltRate)
    #expect(abs(w.grounds[0].heights[200] - 30 * factor) < 0.5)
    #expect(w.piles[1]!.surface.heights.max()! < 20 * factor + 0.5)
}

// MARK: - Screen sides + stacked monitors

@Test func flakesCannotDriftOutOfTheScreenSides() {     // snow never leaves the screen sideways
    let w = world(); w.strength = .strong
    var escaped = 0
    for _ in 0..<Int(30 / Tuning.step) {
        w.step(dt: Tuning.step)
        escaped += w.flakes.filter { $0.x < 0 || $0.x > 1000 }.count
    }
    #expect(escaped == 0)
}

@Test func clumpsStopAtTheScreenSide() {
    let w = world(); w.spawnEnabled = false; w.flakes.removeAll()
    w.clumps.append(Particle(x: 995, y: 400, vx: 300, vy: 0, radius: 3, area: 20, alpha: 1, isClump: true))
    run(w, seconds: 2)
    #expect(w.clumps.isEmpty)
    #expect(w.grounds[0].volume > 19)                      // landed on the ground, not lost
}

@Test func stackedScreensCanShareOneGround() {         // monitor above the MacBook, snow only at the bottom
    let w = world([CGRect(x: 0, y: -600, width: 1000, height: 600),      // upper, snow area down to y = 0
                   CGRect(x: 0, y: 39, width: 1000, height: 761)])       // lower, below its menu bar
    w.stackedFallThrough = true
    #expect(w.grounds.count == 1 && w.grounds[0].baseY == 800)
    #expect((0..<200).allSatisfy { _ in w.makeFlake(initial: false).y < -590 })   // new flakes only at the top
    run(w, seconds: 60)
    #expect(w.grounds[0].volume > 0)
    w.stackedFallThrough = false
    #expect(w.grounds.count == 2)
}

// MARK: - Snowstorm + ice crystals

@Test func stormIsDenseAndBlowsSideways() {            // an extreme level: the snowstorm
    let w = world(); w.strength = .strong
    let strong = w.flakes.count
    w.strength = .storm
    #expect(w.flakes.count > 18 * strong / 10)
    var escaped = 0
    for _ in 0..<Int(10 / Tuning.step) {
        w.step(dt: Tuning.step)
        escaped += w.flakes.filter { $0.x < 0 || $0.x > 1000 }.count
    }
    #expect(escaped == 0)
    #expect(w.flakes.reduce(0) { $0 + $1.vx } / Double(w.flakes.count) > 50)
}

@Test func windDoesNotPileFlakesAgainstTheScreenSide() { // no curtain of flakes along the wall
    let w = world(); w.strength = .storm
    run(w, seconds: 15)
    let atWall = w.flakes.filter { $0.x > 980 }.count, middle = w.flakes.filter { $0.x > 490 && $0.x <= 510 }.count
    #expect(atWall <= 3 * max(middle, 5))
}

@Test func iceCrystalsFallNowAndThen() {               // now and then an ice crystal
    let w = world()
    let fresh = (0..<4000).map { _ in w.makeFlake(initial: false) }
    let crystals = fresh.filter(\.isCrystal)
    #expect(crystals.count > 40 && crystals.count < 160)          // ≈ 2 %
    #expect(crystals.allSatisfy { $0.fall > 80 && $0.radius >= 6 })                 // big enough to see
}

@Test func widerUpperMonitorKeepsNoGroundWhenStacked() { // the whole upper monitor keeps no ground
    let w = world([CGRect(x: -300, y: -600, width: 1600, height: 600),   // upper, wider
                   CGRect(x: 0, y: 39, width: 1000, height: 761)])       // lower
    w.stackedFallThrough = true
    #expect(w.grounds.count == 1 && w.grounds[0].baseY == 800)
    var lost = 0                                          // flakes below the overhanging sides
    for _ in 0..<Int(30 / Tuning.step) {
        w.step(dt: Tuning.step)
        lost += w.flakes.filter { $0.y > 60 && ($0.x < 0 || $0.x >= 1000) }.count
    }
    #expect(lost == 0)
}

// MARK: - Tilt (accelerometer)

@Test func snowBeyondReposeSlidesDownhill() {
    var s = Surface(originX: 0, baseY: 100, columns: 20, cap: 60, walls: true)
    s.heights = Array(repeating: 10, count: 20)
    for _ in 0..<3000 { _ = s.settle(bias: Tuning.reposeMaxStep + 1) }
    #expect(s.heights[19] > s.heights[0] + 10)               // slid to the low side
    #expect(abs(s.volume - 400) < 1e-6)                       // walls: nothing is lost
    #expect(s.heights.allSatisfy { $0 >= 0 })
}

@Test func gentleTiltLeavesLyingSnowAlone() {            // snow sticks up to the angle of repose
    var s = Surface(originX: 0, baseY: 100, columns: 20, cap: 60, walls: true)
    s.heights = Array(repeating: 10, count: 20)
    for _ in 0..<300 { _ = s.settle(bias: Tuning.column * tan(30 * Double.pi / 180)) }
    #expect(s.heights.allSatisfy { abs($0 - 10) < 1e-9 })
}

@Test func flakesFallDiagonallyWhenTilted() {             // MacBook tilted 30° to the right
    let w = world()
    w.gravityAngle = 30 * Double.pi / 180
    #expect(w.quarterTurns == 0)
    run(w, seconds: 2)
    #expect(w.flakes.reduce(0) { $0 + $1.vx } / Double(w.flakes.count) > 15)
}

@Test func quarterTurnMovesGroundAndSpawnToTheSides() {  // MacBook turned onto its right side
    let w = world()
    w.gravityAngle = .pi / 2
    #expect(w.quarterTurns == 1)
    let g = w.grounds[0]
    let a = w.toScreen(g.originX, g.baseY), b = w.toScreen(g.maxX, g.baseY)
    #expect(abs(a.x - 1000) < 1 && abs(b.x - 1000) < 1)      // the ground now runs along the right edge
    let spawned = (0..<100).map { _ in w.makeFlake(initial: false) }.map { w.toScreen($0.x, $0.y) }
    #expect(spawned.allSatisfy { $0.x < 5 })                  // new flakes come from the left
}

@Test func turningLetsLyingSnowSlideOff() {
    let w = world(); w.spawnEnabled = false; w.flakes.removeAll()
    w.updateWindows([WindowInfo(id: 1, frame: win)], existing: nil, dt: Tuning.step, dragging: false)
    w.piles[1]!.surface.heights = w.piles[1]!.surface.heights.map { _ in 10 }
    w.grounds[0].heights = w.grounds[0].heights.map { _ in 10 }
    let lying = w.piles[1]!.surface.volume + w.grounds[0].volume
    w.gravityAngle = .pi / 2
    #expect(w.piles.isEmpty && w.grounds.allSatisfy { $0.volume == 0 })
    #expect(abs(w.clumps.reduce(0) { $0 + $1.area } - lying) < 1)
    w.updateWindows([WindowInfo(id: 1, frame: win)], existing: nil, dt: Tuning.step, dragging: false)
    #expect(w.piles[1] != nil)                                // the cap now sits on the window's left edge
}

@Test func lyingSnowHoldsOnUntilClearlyTurned() {         // lying snow lets go only after a clear turn
    let w = world()
    w.gravityAngle = 65 * Double.pi / 180
    #expect(w.quarterTurns == 0)                              // still holds
    w.gravityAngle = 75 * Double.pi / 180
    #expect(w.quarterTurns == 1)                              // only now does everything slide off
    w.gravityAngle = 30 * Double.pi / 180
    #expect(w.quarterTurns == 1)                              // hysteresis: no flip-flopping
    w.gravityAngle = 15 * Double.pi / 180
    #expect(w.quarterTurns == 0)
}

@Test func tiltingNeverDropsSnowOffScreen() {           // can tilting drop snow off the screen?
    let w = world(); w.spawnEnabled = false; w.flakes.removeAll()
    w.updateWindows([WindowInfo(id: 1, frame: win)], existing: nil, dt: Tuning.step, dragging: false)
    w.piles[1]!.surface.heights = w.piles[1]!.surface.heights.map { _ in 10 }
    w.grounds[0].heights = w.grounds[0].heights.map { _ in 10 }
    let lying = w.piles[1]!.surface.volume + w.grounds[0].volume
    for degrees in [50.0, 100, 190, 280, 0] {             // turn once all the way around
        w.gravityAngle = degrees * Double.pi / 180
        w.updateWindows([WindowInfo(id: 1, frame: win)], existing: nil, dt: Tuning.step, dragging: false)
        run(w, seconds: 3)
    }
    let kept = w.grounds.reduce(0) { $0 + $1.volume } + w.piles.values.reduce(0) { $0 + $1.surface.volume }
    #expect(w.clumps.isEmpty)
    #expect(kept > 0.9 * lying)                            // only the gentle thaw, nothing falls out
}

// MARK: - Gradual sliding + stronger levels

@Test func capSlidesOffGraduallyWhenTilted() {           // early and gradual instead of all at once at 70°
    var p = flatPile(10)
    let v0 = p.surface.volume
    var shed: [Chunk] = []
    for _ in 0..<60 { p.windowMoved(to: win, dt: Tuning.step, dragging: false); shed += p.step(dt: Tuning.step, tilt: 10 * .pi / 180) }
    #expect(shed.isEmpty)                                     // 10°: holds
    for _ in 0..<120 { p.windowMoved(to: win, dt: Tuning.step, dragging: false); shed += p.step(dt: Tuning.step, tilt: 35 * .pi / 180) }
    #expect(!shed.isEmpty && shed.allSatisfy { $0.x > Double(win.maxX) - Tuning.cornerInset })   // slides off to the right
    #expect(p.surface.volume > 0.3 * v0)                      // ... bit by bit, not all at once
}

@Test func groundSnowDriftsDownhillFromModestTilt() {
    let w = world(); w.spawnEnabled = false; w.flakes.removeAll()
    w.grounds[0].heights = w.grounds[0].heights.map { _ in 10 }
    w.gravityAngle = 10 * Double.pi / 180
    run(w, seconds: 2)
    #expect(abs(w.grounds[0].heights[400] - w.grounds[0].heights[100]) < 0.5)   // 10°: stays put
    w.gravityAngle = 35 * Double.pi / 180
    run(w, seconds: 3)
    #expect(w.grounds[0].heights[495] > w.grounds[0].heights[5] + 5)          // 35°: drifts to the low side
}

@Test func strengthLevelsStepUpAndStormRages() {          // Light unchanged, the rest stronger, the storm goes wild
    let w = world()
    var counts: [Int] = []
    for s in Strength.allCases { w.strength = s; counts.append(w.flakes.count) }
    #expect(counts[0] == 56)                                  // Light unchanged
    #expect(counts[1] >= 7 * counts[0] / 2 && counts[2] >= 2 * counts[1] && counts[3] >= 5 * counts[2] / 2)
    var speed = 0.0
    for _ in 0..<Int(6 / Tuning.step) {
        w.step(dt: Tuning.step)
        speed += w.flakes.reduce(0) { $0 + $1.vx } / Double(w.flakes.count)
    }
    #expect(speed / (6 / Tuning.step) > 150)                  // strongly sideways on average
}

// MARK: - Resting surfaces (resources)

@Test func restingSurfaceIsNotTouchedAgain() {            // recompute and redraw only on a real change
    var s = Surface(originX: 0, baseY: 100, columns: 9, cap: 60, walls: true)
    s.heights[4] = 30
    for _ in 0..<2000 { _ = s.settle() }
    let rested = s.revision
    for _ in 0..<50 { _ = s.settle() }
    #expect(s.revision == rested)                              // at rest: no work, no change
    s.deposit(area: 4, x: 9, width: 2)
    #expect(s.revision != rested)
}

@Test func quietSnowIsNotChangedEveryStep() {             // thaw batched instead of every step
    let w = world(); w.spawnEnabled = false; w.flakes.removeAll()
    w.grounds[0].heights = w.grounds[0].heights.map { _ in 10 }
    run(w, seconds: 0.2)
    let r = w.grounds[0].revision
    run(w, seconds: 0.5)
    #expect(w.grounds[0].revision == r)
}

@Test func groundSnowSlidesAsOneSlab() {                 // ground snow moves as one slab, not grain by grain
    let w = world(); w.spawnEnabled = false; w.flakes.removeAll()
    w.grounds[0].heights = w.grounds[0].heights.map { _ in 10 }
    let v0 = w.grounds[0].volume
    w.gravityAngle = 35 * Double.pi / 180
    run(w, seconds: 1)
    #expect(w.grounds[0].heights[0..<35].allSatisfy { $0 < 1 })   // the high side is bare after 1 s
    #expect(w.grounds[0].volume > 0.98 * v0)                      // nothing lost, only moved
}

// MARK: - Review fixes

@Test func flakesNeverCutADrift() {                      // new snow stops at the cap but never lowers a drift above it
    var s = Surface(originX: 0, baseY: 100, columns: 10, cap: 60, walls: true)
    s.heights[5] = 150
    s.deposit(area: 4, x: 11, width: 2)
    #expect(s.heights[5] == 150)
}

@Test func spillsCountAsNewSnowfall() {                  // snow trickling off caps stays within the ground cap
    let w = world(); w.spawnEnabled = false; w.flakes.removeAll()
    w.grounds[0].heights = w.grounds[0].heights.map { _ in 59.5 }   // a resting ground just below its cap
    w.clumps.append(Particle(x: 201, y: 740, vx: 0, vy: 0, radius: 1.6, area: 20, alpha: 1, isClump: true, fromSpill: true))
    w.step(dt: Tuning.step)                                // lands this step; check before settling spreads it
    #expect(w.clumps.isEmpty)
    #expect(w.grounds[0].heights.max()! <= 60 + 1e-9)
}

@Test func tabSwitchKeepsTheCap() {                       // native tabs are separate windows sharing one frame
    let w = world(); w.spawnEnabled = false
    w.updateWindows([WindowInfo(id: 1, frame: win)], existing: nil, dt: Tuning.step, dragging: false)
    w.piles[1]!.surface.heights = w.piles[1]!.surface.heights.map { _ in 10 }
    let h = w.piles[1]!.surface.heights
    w.updateWindows([WindowInfo(id: 2, frame: win)], existing: [1, 2], dt: Tuning.step, dragging: false)   // switch to tab 2
    #expect(w.piles[2]?.surface.heights == h)
    w.updateWindows([WindowInfo(id: 1, frame: win)], existing: [1, 2], dt: Tuning.step, dragging: false)   // and back
    #expect(w.piles[1]?.surface.heights == h)
}

@Test func tiltIsTrustedOnlyAfterLyingFlat() {            // a sensor mounted differently must not turn the snow upside down
    var flipped = TiltReading()
    for _ in 0..<60 { flipped.add(x: 0, y: 0, z: 1) }
    #expect(flipped.screenAngle == nil)
    var ok = TiltReading()
    ok.add(x: 0.02, y: 0.05, z: -0.99)                    // lying flat
    #expect(abs(ok.screenAngle!) < 0.1)
    for _ in 0..<60 { ok.add(x: 1, y: 0, z: 0) }          // turned onto its right side
    #expect(abs(ok.screenAngle! - .pi / 2) < 0.1)
}

// MARK: - Frame rate (menu "Animation")

@Test func frameRateFollowsTheChosenSetting() {          // Maximal / Flüssig / Optimiert
    // Maximal: whatever the display can do, even on battery in Low Power Mode
    #expect(FrameRate.maximal.fps(screenMax: 120, onAC: false, lowPower: true, moving: false) == 120)
    #expect(FrameRate.maximal.fps(screenMax: 60, onAC: true, lowPower: false, moving: false) == 60)
    #expect(FrameRate.maximal.fps(screenMax: 0, onAC: true, lowPower: false, moving: false) == 60)    // display reports nothing
    // Flüssig: always 60
    #expect(FrameRate.smooth.fps(screenMax: 120, onAC: false, lowPower: true, moving: false) == 60)
    // Optimiert (default): 60 on power, 30 on battery or in Low Power Mode, 60 while something big moves
    #expect(FrameRate.optimized.fps(screenMax: 120, onAC: true, lowPower: false, moving: false) == 60)
    #expect(FrameRate.optimized.fps(screenMax: 120, onAC: false, lowPower: false, moving: false) == 30)
    #expect(FrameRate.optimized.fps(screenMax: 120, onAC: true, lowPower: true, moving: false) == 30)
    #expect(FrameRate.optimized.fps(screenMax: 120, onAC: false, lowPower: true, moving: true) == 60)
}

@Test func snowFlowsNoFasterAt120FpsThanAt60() {           // Maximal steps 120×/s; slopes must not relax twice as fast
    func pileAfter(_ steps: Int, of dt: Double) -> [Double] {
        let w = World(seed: 1)                                // no screens: no flakes, nothing lands
        w.updateWindows([WindowInfo(id: 1, frame: win)], existing: nil, dt: dt, dragging: false)
        w.piles[1]!.surface.heights[w.piles[1]!.surface.heights.count / 2] = 20   // far steeper than repose
        for _ in 0..<steps { w.step(dt: dt) }
        return w.piles[1]!.surface.heights
    }
    var ref = Pile(frame: win).surface                        // 50 ms at 60 fps = three settling passes
    ref.heights[ref.heights.count / 2] = 20
    for _ in 0..<3 { _ = ref.settle() }
    #expect(ref.heights[ref.heights.count / 2] < 20)          // the spike does flow
    #expect(pileAfter(3, of: 1.0 / 60) == ref.heights)
    #expect(pileAfter(6, of: 1.0 / 120) == ref.heights)
}

@Test func restingCapIsNotTouchedAgain() {                  // a cap at rest costs nothing: no re-settle, no re-upload
    let w = World(seed: 1)                                    // no screens: nothing lands
    w.updateWindows([WindowInfo(id: 1, frame: win)], existing: nil, dt: Tuning.step, dragging: false)
    w.piles[1]!.surface.heights = w.piles[1]!.surface.heights.map { _ in 1 }   // flat, nothing to flow
    for _ in 0..<5 { w.step(dt: Tuning.step) }
    let r = w.piles[1]!.surface.revision
    for _ in 0..<30 { w.step(dt: Tuning.step) }               // half a second: no thaw yet either
    #expect(w.piles[1]!.surface.revision == r)
}

@Test func slippingCapBreaksIntoTheSameChunksAt120Fps() {   // not more, smaller ones: same heft at every setting
    func clumpsAfterHalfASecond(at dt: Double) -> [Particle] {
        let w = world(); w.spawnEnabled = false; w.flakes.removeAll()
        w.updateWindows([WindowInfo(id: 1, frame: win)], existing: nil, dt: dt, dragging: false)
        w.piles[1]!.surface.heights = w.piles[1]!.surface.heights.map { _ in 10 }
        w.gravityAngle = 60 * Double.pi / 180                 // the cap slips off to the right at ~200 pt/s
        for _ in 0..<Int((0.5 / dt).rounded()) { w.step(dt: dt) }
        return w.clumps                                       // none has landed yet: 400 pt to the ground
    }
    let at60 = clumpsAfterHalfASecond(at: 1.0 / 60), at120 = clumpsAfterHalfASecond(at: 1.0 / 120)
    #expect(at60.count > 5)                                   // it does break off
    #expect(abs(at120.count - at60.count) <= 1)
}

@Test func snowLandingOnFreshSnowLandsInTheSameStep() {     // the landing shortcut must see snow that fell this very step
    let w = world(); w.spawnEnabled = false; w.flakes.removeAll()
    w.updateWindows([WindowInfo(id: 1, frame: win)], existing: nil, dt: Tuning.step, dragging: false)
    w.piles[1]!.surface.heights = w.piles[1]!.surface.heights.map { _ in 10 }   // snow line at y = 390
    // two chunks above the same spot: the first raises the snow there to 20 pt (line at 380) ...
    w.clumps.append(Particle(x: 500, y: 389.5, vx: 0, vy: 0, radius: 1.6, area: 40, alpha: 1, isClump: true))
    // ... and the second sits between the old and the new line, so it comes to rest on the fresh snow
    w.clumps.append(Particle(x: 500, y: 384, vx: 0, vy: 0, radius: 1.6, area: 40, alpha: 1, isClump: true))
    w.step(dt: Tuning.step)
    #expect(w.clumps.isEmpty)
    #expect(w.piles[1]!.surface.lineY(at: 500)! == 370)      // 10 + 10 + 10 pt of snow
}

@Test func groundSnowFlowsNoFasterAt120FpsThanAt60() {       // the same promise for the ground as for the caps
    func groundAfter(_ steps: Int, of dt: Double) -> [Double] {
        let w = world(); w.spawnEnabled = false; w.flakes.removeAll()
        w.grounds[0].heights[250] = 20                        // a spike far steeper than repose
        for _ in 0..<steps { w.step(dt: dt) }
        return w.grounds[0].heights
    }
    var ref = world().grounds[0]                              // 50 ms at 60 fps = three settling passes
    ref.heights[250] = 20
    for _ in 0..<3 { _ = ref.settle() }
    #expect(ref.heights[250] < 20)                            // the spike does flow
    #expect(groundAfter(3, of: 1.0 / 60) == ref.heights)
    #expect(groundAfter(6, of: 1.0 / 120) == ref.heights)
}
