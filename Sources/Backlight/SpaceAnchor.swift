import AppKit

// A desktop of its own for Backlight's full screen beside the notch.
//
// macOS's own full screen gives a window a desktop of its own (Mission Control
// and Stage Manager show it as one), but puts the window below the notch: the
// window server keeps it at the screen's height less the notch's row whatever
// frame the window is given (measured on a 1710×1112 screen: y 38, height 1074,
// with NSPrefersDisplaySafeAreaCompatibilityMode false and with the frame forced
// to the whole screen alike). Backlight's own full screen used the whole
// screen, the row beside the notch included, but stayed on the desktop it was
// on. A desktop can't be made and a window put on it by any call an app may
// make (CGSAddWindowsToSpaces leaves the window on none, measured).
//
// What does work: a window that goes into macOS's full screen makes the
// desktop, and another window ordered in on that desktop as an auxiliary one
// is not held below the notch (measured: y 0, the screen's whole height). So
// this anchor, a plain black window, goes into full screen for its desktop, and
// the browser's window joins it there in Backlight's own full screen.
final class SpaceAnchor: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private var entered: (() -> Void)?
    private var exited: (() -> Void)?
    /// It left full screen without being asked (from Mission Control, say).
    var onLeftByItself: (() -> Void)?
    private var leaving = false

    init(over frame: NSRect) {
        window = NSWindow(contentRect: frame, styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Backlight"
        window.backgroundColor = .black
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.fullScreenPrimary, .ignoresCycle]
        window.animationBehavior = .none
        window.delegate = self
    }

    /// Into full screen; `then` once its desktop is the one shown.
    func enter(then: @escaping () -> Void) {
        entered = then
        window.orderFront(nil)
        window.toggleFullScreen(nil)
    }

    /// Out of full screen; `then` once its desktop is gone and the one it came from is shown.
    func leave(then: @escaping () -> Void) {
        exited = then
        leaving = true
        if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) } else { windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification)) }
    }

    /// On its desktop the menu bar and the Dock are hidden outright, as in Backlight's own full screen: macOS's
    /// default there hides them only while its own full-screen window is in front, and the browser's window is
    /// (the menu bar stayed over the row beside the notch, reported). The browser brings the menu bar down when
    /// the pointer pushes at the top, as it does elsewhere (BrowserWindow.setOptions).
    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposed: NSApplication.PresentationOptions = []) -> NSApplication.PresentationOptions {
        [.fullScreen, .hideDock, .hideMenuBar]
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        let then = entered
        entered = nil
        then?()
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        let then = entered
        entered = nil
        then?()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        window.orderOut(nil)
        window.close()
        if leaving {
            let then = exited
            exited = nil
            then?()
        } else {
            onLeftByItself?()
        }
    }

    /// Whether the desktop it made is there.
    var isInFullScreen: Bool { window.styleMask.contains(.fullScreen) }
}

// On the anchor's desktop macOS shows the menu bar whenever it auto-hides and the window in front is not the
// full-screen one, and the Dock comes out only with the menu bar auto-hiding (macOS hides the menu bar outright only
// with the Dock): so touching the Dock brought the menu bar down over the row beside the notch (reported). The
// window can't stand over the menu bar meanwhile, as it does at rest, since that is over the Dock too. So this
// window, clear but for the menu bar's row, stands over that row while the Dock is out, showing what the browser's
// window shows there (a picture of the page, taken as the pointer comes near the Dock; black where there is none).
@MainActor
final class RowCover {
    /// Where it is put, nowhere else.
    final class Strip: NSPanel {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }
    private var panel: Strip?
    private let picture = NSImageView()
    private let band = NSView()
    /// The window's clock, which would be under the strip: one of its own in the same place.
    private lazy var clock: ClockHost = {
        let clock = ClockHost(rootView: MenuBarClock())
        clock.sizingOptions = []
        clock.safeAreaRegions = []
        return clock
    }()
    private(set) var isShown = false

    /// Over the top `row` points of `screen`, with `image` (if any) where it was taken from: `at` in the row's own coordinates.
    /// `clockAt`: where the window's clock is, in the same coordinates, if it shows.
    func show(on screen: NSScreen, row: CGFloat, image: NSImage?, at frame: NSRect, clockAt: NSRect?) {
        // The top half of the screen, not the row alone: a window as short as the row, at this level, was put
        // 280 points down the screen by the window server whatever its frame (measured); one this tall stays.
        let half = NSRect(x: screen.frame.minX, y: screen.frame.midY, width: screen.frame.width, height: screen.frame.maxY - screen.frame.midY)
        let panel = self.panel ?? make(half)
        self.panel = panel
        if panel.frame != half { panel.setFrame(half, display: false) }
        band.frame = NSRect(x: 0, y: half.height - row, width: half.width, height: row)
        place(image, at: frame)
        if let clockAt {
            clock.frame = clockAt
            if clock.superview !== band { band.addSubview(clock) }
        } else {
            clock.removeFromSuperview()
        }
        if !isShown || !panel.isVisible { panel.orderFrontRegardless() }
        isShown = true
    }

    /// A newer picture, while shown. Out to whole points, so no seam of the black behind it shows.
    func place(_ image: NSImage?, at frame: NSRect) {
        picture.image = image
        picture.frame = frame.integral
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        panel?.orderOut(nil)
    }

    private func make(_ frame: NSRect) -> Strip {
        let panel = Strip(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace, .ignoresCycle]
        picture.imageScaling = .scaleAxesIndependently
        panel.contentView = NSView()
        band.wantsLayer = true
        band.layer?.backgroundColor = NSColor.black.cgColor
        band.addSubview(picture)
        panel.contentView?.addSubview(band)
        return panel
    }
}
