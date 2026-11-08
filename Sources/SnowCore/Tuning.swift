import Foundation

/// Every tuning knob in one place. Units: points (pt) and seconds.
public enum Tuning {
    // Height profiles
    public static let column = 2.0                                     // column width
    public static let pileCap = 24.0                                   // max cap height on a window
    public static let groundCap = 60.0                                 // max ground height
    public static let reposeMaxStep = tan(50 * Double.pi / 180) * column  // 50° angle of repose ≈ 2.38 pt/column
    public static let settleRate = 0.25
    public static let compaction = 0.35                                // flake disc area → snow area
    public static let spillQuantum = 8.0                               // pt² collected before an edge spill drops
    public static let clumpColumns = 3                                 // columns per shed clump
    public static let meltRate = 1.0 / 1200                            // per s, ∝ height: medium snowfall levels off at ~38 pt;
                                                                       // unfed snow (e.g. ground under windows) halves in ~14 min

    // Pile physics
    public static let friction = 5000.0                                // μg: max accel the window transfers (pt/s²)
    public static let gravity = 2500.0                                 // pt/s² for caps lifting off and hopping
    public static let maxHopSpeed = 500.0                              // caps an upward throw at v²/2g = 50 pt
    public static let overhang = 4.0                                   // pt a pile may stick out past its support
    public static let cornerInset = 12.0                               // caps start this far inside the frame: rounded window corners
    public static let clumpTerminal = 520.0                            // pt/s
    public static let clumpGravity = 1700.0                            // pt/s²: clumps fall heavy but unhurried
    public static let turnThreshold = 70 * Double.pi / 180             // tilt at which lying snow lets go and the frame turns
    public static let slideStart = 20 * Double.pi / 180                // from this tilt lying snow starts to creep downhill
    public static let slideSpeed = 250.0                               // pt/s a cap slab slides at when on its side
    public static let heapCap = 150.0                                  // a sliding ground slab stops where the heap is this high

    // Flakes
    public static let flakeDensity: [Double] = [70, 260, 560, 1400]    // per 1M pt², index = Strength.rawValue
    public static let wind = 15.0                                      // pt/s amplitude
    public static let windScale: [Double] = [1, 1.6, 2.5, 2.5]         // per strength
    public static let stormWind = 260.0                                // pt/s mean, gusting ±80%, blows right
    public static let crystalShare = 0.02                              // share of new flakes that are ice crystals

    // Timing
    public static let step = 1.0 / 60                                  // fixed sim step
    public static let maxSubsteps = 4
    public static let minPollDt = 1.0 / 240                            // floor for window-poll dt
}
