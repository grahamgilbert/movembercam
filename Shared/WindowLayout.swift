import Foundation

/// Fit a saved window to the usable display area, including after moving screens.
enum WindowLayout {
    static func fittedFrame(_ frame: CGRect, visibleFrame: CGRect, minimumSize: CGSize) -> CGRect {
        let area = visibleFrame.insetBy(dx: 12, dy: 12)
        let size = CGSize(width: min(max(frame.width, minimumSize.width), area.width),
                          height: min(max(frame.height, minimumSize.height), area.height))
        return CGRect(x: min(max(frame.minX, area.minX), area.maxX - size.width),
                      y: min(max(frame.maxY - size.height, area.minY), area.maxY - size.height),
                      width: size.width, height: size.height)
    }
}
