import AppKit
import SwiftUI

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
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(button)?.isHidden = true }
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.contentsGravity = .resize
    }

    /// What it shows while macOS animates it into and out of full screen: the browser's window as it was, so it is the
    /// page that grows to the screen and shrinks back, as in macOS's own full screen (a black window grew first and
    /// the page followed, and the other way round; reported). Black again with none.
    func show(_ picture: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        window.contentView?.layer?.contents = picture
        CATransaction.commit()
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
        // The browser's window shows in its place first, then this goes: no moment with neither.
        if leaving {
            let then = exited
            exited = nil
            then?()
        } else {
            onLeftByItself?()
        }
        window.orderOut(nil)
        window.close()
    }

    /// To the front of its desktop (under the browser's window, which is ordered after it).
    func orderFront() { if isInFullScreen { window.orderFront(nil) } }

    /// Whether the desktop it made is there.
    var isInFullScreen: Bool { window.styleMask.contains(.fullScreen) }
}

// On the anchor's desktop macOS shows the menu bar whenever it auto-hides and the window in front is not the
// full-screen one, and the Dock comes out only with the menu bar auto-hiding (macOS hides the menu bar outright only
// with the Dock): so touching the Dock brought the menu bar down over the row beside the notch (reported). The
// window can't stand over the menu bar meanwhile, as it does at rest, since that is over the Dock too. So this
// window, clear but for the menu bar's row, stands over that row while the Dock is out, showing the browser window's
// own row as it is on the screen, frame by frame (BrowserWindow.mirrorRow). A picture of the page taken once, with a
// clock drawn over it again, was told apart: the page went on changing under it, and glass drawn a second time never
// came out the same (reported, four times).
@MainActor
final class RowCover {
    /// Where it is put, nowhere else.
    final class Strip: NSPanel {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }
    private var panel: Strip?
    private let band = NSView()
    private(set) var isShown = false

    /// Over the top `row` points of `screen`.
    func show(on screen: NSScreen, row: CGFloat) {
        prepare(on: screen, row: row)
        panel?.alphaValue = 1
        isShown = true
    }

    /// In place and clear, ahead of being shown (from the start of full screen): ordered in at the moment it was
    /// wanted, the first time it came a frame late, and the menu bar flickered past (reported).
    func prepare(on screen: NSScreen, row: CGFloat) {
        // The top half of the screen, not the row alone: a window as short as the row, at this level, was put
        // 280 points down the screen by the window server whatever its frame (measured); one this tall stays.
        let half = NSRect(x: screen.frame.minX, y: screen.frame.midY, width: screen.frame.width, height: screen.frame.maxY - screen.frame.midY)
        let panel = self.panel ?? make(half)
        self.panel = panel
        if panel.frame != half { panel.setFrame(half, display: false) }
        let strip = NSRect(x: 0, y: half.height - row, width: half.width, height: row)
        if band.frame != strip { band.frame = strip }
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
    }

    /// The row as the browser's window has it now.
    func mirror(_ image: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Pixel for pixel: the picture's own density, from its width against the row's, never the layer's default of
        // 1 (softer than the window's row, reported) nor a screen's guess (a picture made at another display's
        // density came out larger, reported); drawn as it is, never resampled.
        if band.bounds.width > 0 { band.layer?.contentsScale = CGFloat(image.width) / band.bounds.width }
        band.layer?.contents = image
        CATransaction.commit()
    }

    /// Clear again, still in place.
    func hide() {
        guard isShown else { return }
        isShown = false
        panel?.alphaValue = 0
        band.layer?.contents = nil
    }

    /// Out (the pointer away from the Dock, or full screen over).
    func remove() {
        hide()
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
        panel.contentView = NSView()
        band.wantsLayer = true
        band.layer?.backgroundColor = NSColor.black.cgColor
        band.layer?.contentsGravity = .topLeft
        band.layer?.magnificationFilter = .nearest
        band.layer?.minificationFilter = .nearest
        panel.contentView?.addSubview(band)
        return panel
    }
}
