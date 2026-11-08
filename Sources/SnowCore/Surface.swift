import Foundation

/// Snow that slid over an open edge of a surface.
public struct Spill {
    public let x: Double
    public let y: Double
    public let area: Double
    public let direction: Double   // -1 = left, +1 = right
}

/// A horizontal ledge (window top or screen bottom) carrying a snow height
/// profile in fixed-width columns. CG global points: y grows downward, so
/// snow of height h reaches up to `baseY - h`.
public struct Surface {
    public var originX: Double
    public var baseY: Double
    public var heights: [Double] { didSet { revision &+= 1 } }
    /// Bumped on every change of `heights`: lets settling and drawing skip resting snow.
    public private(set) var revision = 0
    private var rest: (revision: Int, bias: Double)?   // known to be settled at this revision and tilt
    public let cap: Double
    public let walls: Bool                                     // true: nothing leaves at the ends
    var pendingSpill: (left: Double, right: Double) = (0, 0)  // pt² waiting to drop as a clump

    public init(originX: Double, baseY: Double, columns: Int, cap: Double, walls: Bool) {
        self.originX = originX
        self.baseY = baseY
        self.heights = Array(repeating: 0, count: max(0, columns))
        self.cap = cap
        self.walls = walls
    }

    public var maxX: Double { originX + Double(heights.count) * Tuning.column }
    public var volume: Double { heights.reduce(0, +) * Tuning.column }

    func columnIndex(at x: Double) -> Int? {
        guard x >= originX, x < maxX else { return nil }
        return min(heights.count - 1, Int((x - originX) / Tuning.column))
    }

    /// Top of the snow at `x`, nil outside the surface.
    public func lineY(at x: Double) -> Double? {
        columnIndex(at: x).map { baseY - heights[$0] }
    }

    /// Spreads `area` evenly over the columns whose centers lie within `width`
    /// around `x` (at least the column under `x`). `capped`: new snowfall stops
    /// growing at `cap`; snow that only moves (clumps) is never destroyed and
    /// spreads out by settling instead.
    public mutating func deposit(area: Double, x: Double, width: Double, capped: Bool = true) {
        guard let hit = columnIndex(at: x) else { return }
        let cw = Tuning.column
        let lo = max(0, Int(((x - width / 2 - originX) / cw - 0.5).rounded(.up)))
        let hi = min(heights.count - 1, Int(((x + width / 2 - originX) / cw - 0.5).rounded(.down)))
        let range = lo <= hi ? lo...hi : hit...hit
        let add = area / (Double(range.count) * cw)
        // capped: fill up to the cap but never lower a drift that is already above it
        for i in range { heights[i] = capped ? max(heights[i], min(cap, heights[i] + add)) : heights[i] + add }
    }

    /// The snow of `range` in groups of `clumpColumns`, as chunks moving with (vx, vy).
    func chunks(_ range: Range<Int>, vx: Double, vy: Double) -> [Chunk] {
        var out: [Chunk] = []
        var i = range.lowerBound
        while i < range.upperBound {
            let j = min(i + Tuning.clumpColumns, range.upperBound)
            let sum = heights[i..<j].reduce(0, +)
            let area = sum * Tuning.column
            if area >= 0.25 {
                out.append(Chunk(x: originX + Double(i + j) / 2 * Tuning.column,
                                 y: baseY - sum / Double(j - i) / 2, area: area, vx: vx, vy: vy))
            }
            i = j
        }
        return out
    }

    /// Moves the whole snow layer `shift` pt along x, like a slab sliding on a tilted
    /// ledge (upwind transport, mass-conserving). It comes to rest against a wall,
    /// where the heap grows up to `heapCap` and settling shapes it.
    mutating func slide(by shift: Double) {
        let n = heights.count
        guard shift != 0, n > 1, walls else { return }
        var h = heights, remaining = abs(shift) / Tuning.column
        let order = shift > 0 ? Array(0..<(n - 1)) : Array((1..<n).reversed())
        let step = shift > 0 ? 1 : -1
        while remaining > 0 {
            let f = min(1, remaining)
            remaining -= f
            var out = h
            for i in order {   // flux from i to its downhill neighbour, never into a full heap
                let flux = min(f * h[i], max(0, Tuning.heapCap - h[i + step]))
                out[i] -= flux
                out[i + step] += flux
            }
            h = out
        }
        heights = h
    }

    /// Gentle thaw: every column keeps `keep` (just below 1) of its height.
    mutating func melt(keep: Double) {
        heights = heights.map { $0 * keep }
    }

    /// One relaxation pass toward the angle of repose (Jacobi: flows from the
    /// current heights, then applied). `bias` = column · tan(tilt): with gravity
    /// tilted toward +x, snow flows that way once the slope exceeds repose.
    /// Open edges drain into `pendingSpill`.
    public mutating func settle(bias: Double = 0) -> [Spill] {
        let n = heights.count
        guard n > 0 else { return [] }
        if let rest, rest.revision == revision, rest.bias == bias { return [] }
        let maxStep = Tuning.reposeMaxStep, rate = Tuning.settleRate
        let tol = 1e-4   // flows only beyond this: settling converges asymptotically and must be able to rest
        var delta = [Double](repeating: 0, count: n)
        // never move more than a quarter of the source column: it has at most two outflows
        func flow(_ excess: Double, from source: Double) -> Double { min(excess * rate, source * 0.25) }
        for i in 0..<(n - 1) {
            let d = heights[i] - heights[i + 1] + bias
            if d > maxStep + tol {
                let f = flow(d - maxStep, from: heights[i])
                delta[i] -= f
                delta[i + 1] += f
            } else if d < -maxStep - tol {
                let f = flow(-d - maxStep, from: heights[i + 1])
                delta[i + 1] -= f
                delta[i] += f
            }
        }
        if !walls {   // virtual neighbor of height 0 beyond each end
            let left = heights[0] - bias, right = heights[n - 1] + bias
            if left > maxStep + tol {
                let out = flow(left - maxStep, from: heights[0])
                delta[0] -= out
                pendingSpill.left += out * Tuning.column
            }
            if right > maxStep + tol {
                let out = flow(right - maxStep, from: heights[n - 1])
                delta[n - 1] -= out
                pendingSpill.right += out * Tuning.column
            }
        }
        if delta.contains(where: { $0 != 0 }) {
            heights = zip(heights, delta).map { $0 + $1 }
        } else {
            rest = (revision, bias)
        }

        var spills: [Spill] = []
        if pendingSpill.left >= Tuning.spillQuantum {
            spills.append(Spill(x: originX, y: baseY - heights[0], area: pendingSpill.left, direction: -1))
            pendingSpill.left = 0
        }
        if pendingSpill.right >= Tuning.spillQuantum {
            spills.append(Spill(x: maxX, y: baseY - heights[n - 1], area: pendingSpill.right, direction: 1))
            pendingSpill.right = 0
        }
        return spills
    }
}
