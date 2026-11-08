import Foundation

/// Turns raw accelerometer readings (in g, MacBook base coordinates: lying flat
/// reads z ≈ −1) into the direction of gravity on screen. The sensor is trusted
/// only after it once read "lying flat", which every MacBook does in normal use;
/// a sensor mounted the other way round, or one whose reports changed, then
/// leaves the snow falling straight down instead of turning it upside down.
public struct TiltReading {
    public private(set) var trusted: Bool
    private var g: (x: Double, y: Double, z: Double)?

    public init(trusted: Bool = false) { self.trusted = trusted }

    public mutating func add(x: Double, y: Double, z: Double) {
        if z < -0.8 && abs(x) < 0.3 { trusted = true }
        guard let s = g else { g = (x, y, z); return }
        let k = 0.15                                   // ~0.1 s smoothing at 50 reports/s
        g = (s.x + (x - s.x) * k, s.y + (y - s.y) * k, s.z + (z - s.z) * k)
    }

    /// Gravity on screen (0 = down, +π/2 = toward the right edge), nil until trusted.
    public var screenAngle: Double? {
        guard trusted, let g else { return nil }
        // The screen shares the hinge (x) axis with the base; the rest of gravity lies in y/z.
        // z < 0: the MacBook stands upright, otherwise it is upside down.
        let towardBottom = (g.y * g.y + g.z * g.z).squareRoot() * (g.z < 0 ? 1 : -1)
        guard abs(g.x) + abs(towardBottom) > 0.3 else { return nil }   // no usable reading
        return atan2(g.x, towardBottom)
    }
}
