import AppKit
import SwiftUI

/// AppKit supplies the actual system window controls and title bar.
struct NativeWindowStyle: NSViewRepresentable {
    var minimumContentSize: CGSize? = nil
    func makeNSView(context: Context) -> WindowStyleView {
        let view = WindowStyleView()
        view.minimumContentSize = minimumContentSize
        return view
    }
    func updateNSView(_ view: WindowStyleView, context: Context) {
        view.minimumContentSize = minimumContentSize
        view.enlargeIfNeeded()
    }
}

final class WindowStyleView: NSView {
    var minimumContentSize: CGSize?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.styleMask.insert([.titled, .closable, .miniaturizable, .resizable])
        window.styleMask.remove(.fullSizeContentView)
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .visible
        window.toolbarStyle = .expanded
        // Accessory apps must keep their windows visible while macOS owns a permission prompt.
        window.hidesOnDeactivate = false
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(type)?.isHidden = false
            window.standardWindowButton(type)?.isEnabled = true
        }
        enlargeIfNeeded()
    }

    func enlargeIfNeeded() {
        guard let window, let minimumContentSize else { return }
        let current = window.contentRect(forFrameRect: window.frame).size
        guard current.width < minimumContentSize.width || current.height < minimumContentSize.height else { return }
        let size = CGSize(width: max(current.width, minimumContentSize.width),
                          height: max(current.height, minimumContentSize.height))
        var frame = window.frameRect(forContentRect: CGRect(origin: .zero, size: size))
        frame.origin = CGPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        if let screen = window.screen { frame = window.constrainFrameRect(frame, to: screen) }
        window.setFrame(frame, display: true)
    }
}
