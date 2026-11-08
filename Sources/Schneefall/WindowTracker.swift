import CoreGraphics
import Foundation
import SnowCore

/// Window geometry from the window server: bounds, layer, owner and alpha are
/// public, so no Screen Recording or Accessibility permission is needed.
final class WindowTracker {
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private var lastIDs = Set<UInt32>()

    /// Visible normal windows. `existing` is set only when a window vanished since
    /// the last poll: every layer-0 window ID that still exists anywhere.
    func poll() -> (windows: [WindowInfo], existing: Set<UInt32>?) {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var windows: [WindowInfo] = []
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? Int32) != ownPID,
                  (info[kCGWindowAlpha as String] as? Double ?? 0) > 0.01,
                  let id = info[kCGWindowNumber as String] as? UInt32,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.width >= 40, frame.height >= 40 else { continue }
            windows.append(WindowInfo(id: id, frame: frame))
        }
        let ids = Set(windows.map(\.id))
        var existing: Set<UInt32>?
        if !lastIDs.isSubset(of: ids) {
            let all = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
            existing = Set(all.compactMap { info in
                (info[kCGWindowLayer as String] as? Int) == 0 ? info[kCGWindowNumber as String] as? UInt32 : nil
            })
        }
        lastIDs = ids
        return (windows, existing)
    }
}
