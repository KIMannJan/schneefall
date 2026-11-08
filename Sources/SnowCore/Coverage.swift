import CoreGraphics

extension CGRect {
    /// True when `rects` together cover all of `self` (exact rectangle subtraction;
    /// slivers under 1 pt count as covered). Used to stop rendering when windows hide
    /// the whole desktop: macOS never reports the overlay as occluded there, because
    /// rounded window corners leave a few pixels of desktop showing.
    public func isCovered(by rects: [CGRect]) -> Bool {
        var open = [self]
        for r in rects {
            var next: [CGRect] = []
            for u in open {
                let i = u.intersection(r)
                guard !i.isNull, i.width > 0, i.height > 0 else { next.append(u); continue }
                next.append(CGRect(x: u.minX, y: u.minY, width: u.width, height: i.minY - u.minY))   // above
                next.append(CGRect(x: u.minX, y: i.maxY, width: u.width, height: u.maxY - i.maxY))   // below
                next.append(CGRect(x: u.minX, y: i.minY, width: i.minX - u.minX, height: i.height))  // left
                next.append(CGRect(x: i.maxX, y: i.minY, width: u.maxX - i.maxX, height: i.height))  // right
            }
            open = next.filter { $0.width >= 1 && $0.height >= 1 }
            if open.isEmpty { return true }
        }
        return false
    }
}
