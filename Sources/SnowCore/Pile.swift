import CoreGraphics
import Foundation

public enum Motion {
    /// How far a window's top surface itself moved, as opposed to its edges:
    /// a pure resize moves an edge but not the surface the snow rests on.
    public static func translation(from old: CGRect, to new: CGRect) -> Double {
        let dl = Double(new.minX - old.minX), dr = Double(new.maxX - old.maxX)
        if abs(dl - dr) < 0.5 { return dl }               // moved
        if abs(dl) < 0.5 || abs(dr) < 0.5 { return 0 }    // one edge resized
        return (dl + dr) / 2                              // animated move + resize: follow the center
    }
}

/// Snow shed from a pile; becomes a falling clump.
public struct Chunk {
    public let x, y, area, vx, vy: Double
}

/// The snow cap on one window, resting on the straight part of its top edge
/// (`cornerInset` in from each side: windows have rounded corners).
/// Horizontal: friction-limited coupling — the pile's velocity relative to the
/// window surface decays by at most μg, so gentle drags carry it and jerky ones
/// make it slip. Vertical: rests on the top edge, lifts off when the window
/// drops faster than gravity, hops (bounded) after an upward jerk.
public struct Pile {
    public var surface: Surface
    public private(set) var frame: CGRect
    public private(set) var inContact = true

    var anchor: Double                     // advances with the surface translation
    var rel = 0.0                          // pile offset vs. anchor; surface.originX == anchor + rel
    var vRel = 0.0                         // pile velocity relative to the surface
    var surfaceVX = 0.0, surfaceVY = 0.0
    var vy = 0.0                           // absolute vertical velocity of the pile

    public init(frame: CGRect) {
        self.frame = frame
        anchor = Double(frame.minX)
        rel = Tuning.cornerInset
        let span = max(0, Double(frame.width) - 2 * Tuning.cornerInset)
        surface = Surface(originX: anchor + rel, baseY: Double(frame.minY),
                          columns: Int((span / Tuning.column).rounded(.up)),
                          cap: Tuning.pileCap, walls: false)
    }

    /// Re-seats a frozen pile (window back from minimize / another Space).
    public init(restoring heights: [Double], offsetX: Double, frame: CGRect) {
        self.init(frame: frame)
        rel = offsetX
        surface.heights = heights
        surface.originX = anchor + rel
    }

    public var offsetX: Double { surface.originX - Double(frame.minX) }

    public mutating func windowMoved(to new: CGRect, dt: Double, dragging: Bool) {
        let dt = max(dt, Tuning.minPollDt)
        let tx = Motion.translation(from: frame, to: new)
        let dy = Double(new.minY - frame.minY)
        if !dragging && (tx != 0 || dy != 0) {
            // Moved by the system (Show Desktop, keyboard tiling): carry rigidly.
            anchor += tx
            surface.baseY = Double(new.minY)
            vRel = 0; vy = 0; surfaceVX = 0; surfaceVY = 0
        } else {
            let newVX = tx / dt
            vRel -= newVX - surfaceVX      // the window accelerates out from under the snow
            surfaceVX = newVX
            surfaceVY = dy / dt
            anchor += tx
        }
        frame = new
        surface.originX = anchor + rel
    }

    /// `tilt`: gravity's angle from straight down in this frame. Past `slideStart` the
    /// cap creeps downhill as a slab, faster the steeper, and sheds over the low edge.
    public mutating func step(dt: Double, tilt: Double = 0) -> [Chunk] {
        let creep = Self.creep(tilt: tilt)
        if inContact { vRel += max(-Tuning.friction * dt, min(Tuning.friction * dt, creep - vRel)) }
        rel += vRel * dt
        surface.originX = anchor + rel

        vy += Tuning.gravity * dt
        surface.baseY += vy * dt
        let top = Double(frame.minY)
        guard surface.baseY >= top else { inContact = false; return [] }
        surface.baseY = top
        vy = max(min(vy, surfaceVY), -Tuning.maxHopSpeed)
        inContact = true

        // Shed columns that are no longer supported.
        let cw = Tuning.column
        let spanL = Double(frame.minX) + Tuning.cornerInset, spanR = Double(frame.maxX) - Tuning.cornerInset
        let lo = spanL - Tuning.overhang, hi = spanR + Tuning.overhang
        let n = surface.heights.count
        var left = 0
        while left < n && surface.originX + (Double(left) + 0.5) * cw < lo { left += 1 }
        var right = n
        while right > left && surface.originX + (Double(right - 1) + 0.5) * cw > hi { right -= 1 }
        var shed = surface.chunks(0..<left, vx: surfaceVX + vRel, vy: vy) + surface.chunks(right..<n, vx: surfaceVX + vRel, vy: vy)
        surface.heights.removeSubrange(right..<n)
        surface.heights.removeFirst(left)
        rel += Double(left) * cw
        if surface.heights.isEmpty { rel = spanL - anchor }
        surface.originX = anchor + rel

        // Grow with empty columns until the whole support span is covered.
        if spanL < surface.originX {
            let k = Int(((surface.originX - spanL) / cw).rounded(.up))
            surface.heights.insert(contentsOf: repeatElement(0, count: k), at: 0)
            rel -= Double(k) * cw
            surface.originX = anchor + rel
        }
        if spanR > surface.maxX {
            let k = Int(((spanR - surface.maxX) / cw).rounded(.up))
            surface.heights.append(contentsOf: repeatElement(0, count: k))
        }
        shed.removeAll { $0.area <= 0 }
        return shed
    }

    /// Downhill speed of lying snow (pt/s, + = toward +x): nothing below `slideStart`,
    /// then faster the steeper, `slideSpeed` when on its side.
    public static func creep(tilt: Double) -> Double {
        let s = sin(tilt), grip = sin(Tuning.slideStart)
        return abs(s) > grip ? Tuning.slideSpeed * (abs(s) - grip) / (1 - grip) * (s > 0 ? 1 : -1) : 0
    }

    /// Window closed: everything falls.
    public mutating func shedAll() -> [Chunk] {
        let out = surface.chunks(0..<surface.heights.count, vx: surfaceVX + vRel, vy: vy)
        surface.heights.removeAll()
        return out
    }

}
