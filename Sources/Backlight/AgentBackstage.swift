import AppKit
import WebKit

// Where the agent's page is while the person looks at another (after Copper's
// Backstage, MIT). It used to wait in the person's window, under the page they
// see: it ran and could be pictured and clicked, but it was not focused (the
// window is the person's, and often not the key one: `document.hasFocus()` was
// false, so a passkey sheet was refused, "the document is not focused", and
// fields that close their suggestions on blur closed them), and a pointer move
// sent through the window found the page on top, so hover never reached it.
//
// Now it hangs in a borderless panel of its own outside every display: ordered
// in, so WebKit lays it out and paints it, its occlusion detection off, so the
// page counts as visible; and the panel says it is the key window without ever
// becoming it, so WebKit takes the page for focused while the person's key
// window, keyboard and app focus stay where they are. Choosing the tab takes
// its page to the window the ordinary way; the next call of the agent's hangs
// it here again. When the agent lets the tab go it leaves, and the panel goes
// out of the screen list when it holds nothing.
@MainActor
enum AgentBackstage {
    /// Says it is key, and can never be: WebKit reads `isKeyWindow` for whether the page's window is active.
    final class Panel: NSPanel {
        override var isKeyWindow: Bool { true }
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
        /// Never brought onto a screen: AppKit moves a window outside every display back onto one when the
        /// desktops change (going into full screen moved this to y 38 of the screen, where the agent's page then
        /// showed over the person's desktop, measured). Its frame is only ever ours.
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    /// What `Tab.windowFrame(for:)` knows it by, without needing the agent's build.
    static let identifier = NSUserInterfaceItemIdentifier(Tab.backstageIdentifier)

    private static var panel: Panel?
    /// Pages just hung here: WebKit tells such a page it is visible and focused on its next turn, so the call
    /// about to work in it gives it one first (`takeMoved`).
    private static var moved = Set<ObjectIdentifier>()

    /// Whether the page was hung here since this was last asked.
    static func takeMoved(_ web: WKWebView) -> Bool { moved.remove(ObjectIdentifier(web)) != nil }

    /// The page hung here, the size it would have in the window (`stage`), in front of any other hung here (so a pointer
    /// move through the panel reaches it) and the one the keyboard goes to.
    static func hang(_ web: WKWebView, sized stage: NSSize) {
        let size = stage.width > 200 && stage.height > 200 ? stage : NSSize(width: 1280, height: 800)
        let panel = ensure(size)
        guard let content = panel.contentView else { return }
        if web.superview !== content || content.subviews.last !== web {
            web.removeFromSuperview()
            web.frame = content.bounds
            web.autoresizingMask = [.width, .height]
            web.isHidden = false
            if web.superview !== content { moved.insert(ObjectIdentifier(web)) }
            content.addSubview(web)
        }
        if panel.firstResponder !== web { panel.makeFirstResponder(web) }
    }

    /// A page just moved in from the person's window: once that window has done what the move set going there
    /// (a turn later), its focus is said again from nothing, and WebKit is told this panel is the key window
    /// (it learns that from the notice, which a panel that never really becomes key would never send).
    static func refocus(_ web: WKWebView) {
        guard let panel, web.window === panel else { return }
        panel.makeFirstResponder(nil)
        panel.makeFirstResponder(web)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: panel)
    }

    /// Whether the page is hung here.
    static func holds(_ web: WKWebView) -> Bool { panel != nil && web.window === panel }

    /// The page leaves (the agent let its tab go); the panel goes when it holds nothing.
    static func release(_ web: WKWebView) {
        guard holds(web) else { return }
        moved.remove(ObjectIdentifier(web))
        web.removeFromSuperview()
        if panel?.contentView?.subviews.isEmpty ?? true { panel?.orderOut(nil) }
    }

    private static func ensure(_ size: NSSize) -> Panel {
        let panel = self.panel ?? make(size)
        self.panel = panel
        // Following the size of the page in the window, and off every display (screens come and go).
        if panel.contentView?.bounds.size != size || NSScreen.screens.contains(where: { $0.frame.intersects(panel.frame) }) {
            panel.setContentSize(size)
            panel.setFrameOrigin(parking(for: panel.frame.size))
        }
        // Ordered in behind everything, never brought forward: an app in the background stays there.
        if !panel.isVisible { panel.orderBack(nil) }
        return panel
    }

    /// Back off every screen when the screens or the desktop shown change, or it is moved: whatever moved it,
    /// it goes back.
    private static var watching: [NSObjectProtocol] = []
    private static func watch(_ panel: Panel) {
        guard watching.isEmpty else { return }
        let repark: @Sendable (Notification) -> Void = { _ in MainActor.assumeIsolated { reparkIfSeen() } }
        watching = [
            NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main, using: repark),
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main, using: repark),
            NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main, using: repark),
        ]
    }

    private static func reparkIfSeen() {
        guard let panel, NSScreen.screens.contains(where: { $0.frame.intersects(panel.frame) }) else { return }
        panel.setFrameOrigin(parking(for: panel.frame.size))
    }

    private static func make(_ size: NSSize) -> Panel {
        let panel = Panel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        // A panel hides when its app stops being active: this one never does, or the page would turn hidden.
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenNone]
        panel.identifier = identifier
        panel.title = "Backlight backstage"
        panel.contentView = NSView(frame: NSRect(origin: .zero, size: size))
        watch(panel)
        return panel
    }

    /// Below and left of every screen there is.
    private static func parking(for size: NSSize) -> NSPoint {
        let all = NSScreen.screens.map(\.frame).reduce(NSRect.null) { $0.union($1) }
        let area = all.isNull ? NSRect(x: 0, y: 0, width: 1440, height: 900) : all
        return NSPoint(x: area.minX - size.width - 400, y: area.minY - size.height - 400)
    }
}
