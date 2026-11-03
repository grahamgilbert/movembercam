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
        view.fitToScreen()
    }
}

final class WindowStyleView: NSView {
    var minimumContentSize: CGSize?
    private var observers: [NSObjectProtocol] = []
    private var changingFullScreen = false
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
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
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = [NSWindow.didChangeScreenNotification, NSWindow.didResizeNotification, NSApplication.didChangeScreenParametersNotification,
                     NSWindow.willEnterFullScreenNotification, NSWindow.didEnterFullScreenNotification,
                     NSWindow.willExitFullScreenNotification, NSWindow.didExitFullScreenNotification].map { name in
            NotificationCenter.default.addObserver(forName: name,
                object: name == NSApplication.didChangeScreenParametersNotification ? nil : window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if name == NSWindow.willEnterFullScreenNotification || name == NSWindow.willExitFullScreenNotification {
                        self.changingFullScreen = true
                        return
                    }
                    if name == NSWindow.didEnterFullScreenNotification || name == NSWindow.didExitFullScreenNotification {
                        self.changingFullScreen = false
                    }
                    self.fitToScreen()
                }
            }
        }
        fitToScreen()
    }

    func fitToScreen() {
        guard let window, !changingFullScreen, !window.styleMask.contains(.fullScreen),
              let minimumContentSize, let screen = window.screen ?? NSScreen.main else { return }
        let availableContent = window.contentRect(forFrameRect: screen.visibleFrame.insetBy(dx: 12, dy: 12)).size
        window.contentMinSize = CGSize(width: min(minimumContentSize.width, availableContent.width),
                                       height: min(minimumContentSize.height, availableContent.height))
        let minimumFrame = window.frameRect(forContentRect: CGRect(origin: .zero, size: window.contentMinSize)).size
        let frame = WindowLayout.fittedFrame(window.frame, visibleFrame: screen.visibleFrame, minimumSize: minimumFrame)
        if frame != window.frame { window.setFrame(frame, display: true) }
    }
}
