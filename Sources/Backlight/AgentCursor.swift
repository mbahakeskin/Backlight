import AppKit
import QuartzCore
import WebKit

// The agent's pointer, as the person sees it (see AgentInput.swift).
//
// The agent's clicks land at once, and nothing here makes a call slower:
// while calls are on, what they did is only noted (a point and a kind).
// Once the agent pauses (no call for 50 ms: its model thinking), what was
// noted is played over the page as one sequence, by Core Animation, which
// runs out of the app's own thread: a pointer in the agent's colour that
// glides from one place to the next, a ring where it pressed, a line along a
// drag, a filled field lit, a word for the keys and for how far a scroll
// went. A batch or a form of many fields is played step by step, quicker
// when there are many, so it never runs long behind the agent. Only the tab
// shown in a window gets it; one worked on out of sight draws nothing.
//
// Measured with the model-free bench (7 quick calls back to back, median of
// 30 rounds): drawn during each call it cost about 0.7 ms a call, drawn in
// the pause after it nothing.

/// What the agent did, where (in the web view's own points, from its top left).
enum AgentGesture {
    case click(CGPoint, right: Bool, count: Int)
    case move(CGPoint)
    case drag(from: CGPoint, to: CGPoint)
    /// Text went in where the keyboard is (what was typed is never shown).
    case typing
    /// A key or a combination, as the agent named it.
    case key(String)
    /// `delta` in the view's points; `moved` false when it was already at the end.
    case scroll(CGPoint, delta: CGVector, moved: Bool)
    /// A field filled at once, by its box.
    case fill(CGRect)
}

enum AgentCursor {
    private struct Noted {
        let gesture: AgentGesture
        weak var web: WKWebView?
    }

    private static var noted: [Noted] = []
    /// Calls on now: nothing is drawn while there are any.
    private static var calls = 0
    private static var due: DispatchWorkItem?

    /// What a call did, kept to be shown once the agent pauses.
    static func play(_ gesture: AgentGesture, in web: WKWebView) {
        guard web.window != nil else { return }
        noted.append(Noted(gesture: gesture, web: web))
        if noted.count > 60 { noted.removeFirst(noted.count - 60) }
        if calls == 0 { soon() }
    }

    static func callBegan() {
        calls += 1
        due?.cancel()
        due = nil
    }

    static func callEnded() {
        calls = max(0, calls - 1)
        if calls == 0, !noted.isEmpty { soon() }
    }

    private static func soon() {
        due?.cancel()
        let item = DispatchWorkItem { MainActor.assumeIsolated { flush() } }
        due = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: item)
    }

    /// Each page's gestures, in order, to the window showing it.
    private static func flush() {
        due = nil
        guard calls == 0 else { return }
        let all = noted
        noted = []
        var pages: [(web: WKWebView, gestures: [AgentGesture])] = []
        for entry in all {
            guard let web = entry.web else { continue }
            if let index = pages.firstIndex(where: { $0.web === web }) { pages[index].gestures.append(entry.gesture) }
            else { pages.append((web, [entry.gesture])) }
        }
        for page in pages {
            guard let window = page.web.window, let shown = Windows.all.first(where: { $0.window === window }) else { continue }
            shown.agentGestures(page.gestures, in: page.web)
        }
    }
}

/// Lies over the page, takes no clicks, and draws the agent's pointer.
final class AgentCursorView: NSView {
    private let pointer = CAShapeLayer()
    private var chips: [CALayer] = []
    private var shown = false
    private var dimmed = false

    /// Where the pointer's tip sits inside its own layer.
    private static let tip = CGPoint(x: 2, y: 25)
    private static let size = CGSize(width: 20, height: 28)
    /// The longest a sequence is played for: a long batch is played quicker.
    private static let longest: CFTimeInterval = 1.6

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        pointer.bounds = CGRect(origin: .zero, size: Self.size)
        pointer.anchorPoint = CGPoint(x: Self.tip.x / Self.size.width, y: Self.tip.y / Self.size.height)
        pointer.path = Self.arrow()
        pointer.fillColor = AgentAccess.color.cgColor
        pointer.strokeColor = NSColor.white.cgColor
        pointer.lineWidth = 1.5
        pointer.lineJoin = .round
        pointer.shadowColor = NSColor.black.cgColor
        pointer.shadowOpacity = 0.35
        pointer.shadowRadius = 2.5
        pointer.shadowOffset = CGSize(width: 0, height: -1)
        pointer.opacity = 0
        pointer.zPosition = 10
        layer?.addSublayer(pointer)
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The Mac's arrow, drawn in the layer's own (upward) points, its tip at `tip`.
    private static func arrow() -> CGPath {
        // The shape as it is usually given, from the tip, downward.
        let down: [CGPoint] = [(0, 0), (0, 17.5), (4.2, 13.6), (7, 20.2), (10.2, 18.8), (7.5, 12.4), (13, 12.4)].map { CGPoint(x: $0.0, y: $0.1) }
        let path = CGMutablePath()
        path.addLines(between: down.map { CGPoint(x: tip.x + $0.x, y: tip.y - $0.y) })
        path.closeSubpath()
        return path
    }

    private var scale: CGFloat { window?.backingScaleFactor ?? 2 }

    /// The agent has finished here: the pointer fades, and comes back with its next move.
    func setFinished(_ finished: Bool) {
        guard finished != dimmed else { return }
        dimmed = finished
        guard shown else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = pointer.presentation()?.opacity ?? pointer.opacity
        fade.duration = 0.4
        pointer.opacity = finished ? 0 : 1
        pointer.add(fade, forKey: "fade")
        if finished { shown = false }
    }

    // MARK: - a sequence

    /// One step of the sequence: where the pointer goes, how long it takes, and what is drawn once it is there.
    private struct Beat {
        var to: CGPoint?
        var glide: CFTimeInterval = 0
        /// For a drag: held at `to`, then carried here.
        var carry: CGPoint?
        var along: CFTimeInterval = 0
        var dwell: CFTimeInterval
        var effect: (_ at: CFTimeInterval, _ k: CFTimeInterval, _ point: CGPoint) -> Void
    }

    private static func glideTime(_ a: CGPoint, _ b: CGPoint) -> CFTimeInterval {
        let distance = hypot(b.x - a.x, b.y - a.y)
        return distance < 1 ? 0 : min(0.32, 0.12 + Double(distance) / 2400)
    }

    func play(_ gestures: [AgentGesture], from web: WKWebView) {
        func here(_ point: CGPoint) -> CGPoint {
            convert(NSPoint(x: point.x, y: web.isFlipped ? point.y : web.bounds.height - point.y), from: web)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let pill = CGPoint(x: bounds.midX, y: bounds.minY + 40)
        let start = shown ? (pointer.presentation()?.position ?? pointer.position) : pill
        var beats: [Beat] = []
        var last = start
        func toward(_ point: CGPoint) -> CFTimeInterval { defer { last = point }; return Self.glideTime(last, point) }

        for gesture in gestures {
            switch gesture {
            case let .click(point, right, count):
                let at = here(point)
                beats.append(Beat(to: at, glide: toward(at), dwell: 0.16 + 0.12 * Double(max(count, 1) - 1)) { [unowned self] t, k, p in
                    press(at: t, k)
                    for extra in 0..<max(count, 1) {
                        ring(at: p, t + Double(extra) * 0.12 * k, k, color: right ? NSColor.systemOrange.cgColor : AgentAccess.color.cgColor)
                    }
                    if right { say("Right-click", near: p, t, k) }
                })
            case let .move(point):
                let at = here(point)
                beats.append(Beat(to: at, glide: toward(at), dwell: 0.04) { _, _, _ in })
            case let .drag(from, to):
                let a = here(from), b = here(to)
                let along = min(0.7, 0.25 + Double(hypot(b.x - a.x, b.y - a.y)) / 1500)
                beats.append(Beat(to: a, glide: toward(a), carry: b, along: along, dwell: 0.12) { [unowned self] t, k, _ in
                    trail(from: a, to: b, t, along * k)
                    held(at: t, (0.08 + along) * k)
                    ring(at: b, t + (0.08 + along) * k, k, color: AgentAccess.color.cgColor)
                })
                last = b
            case .typing:
                beats.append(Beat(dwell: 0.3) { [unowned self] t, k, p in say("Typing…", near: p, t, k) })
            case let .key(name):
                let said = Self.keyName(name)
                beats.append(Beat(dwell: 0.3) { [unowned self] t, k, p in say(said, near: p, t, k) })
            case let .scroll(point, delta, moved):
                let at = here(point)
                beats.append(Beat(to: at, glide: toward(at), dwell: 0.3) { [unowned self] t, k, p in
                    scrolled(near: p, delta: delta, moved: moved, t, k)
                })
            case let .fill(box):
                let a = here(CGPoint(x: box.minX, y: box.minY)), b = here(CGPoint(x: box.maxX, y: box.maxY))
                let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
                let at = CGPoint(x: rect.minX + min(rect.width / 2, 24), y: rect.midY)
                beats.append(Beat(to: at, glide: toward(at), dwell: 0.25) { [unowned self] t, k, p in
                    outline(rect, t, k)
                    say("Filled", near: p, t, k)
                })
            }
        }
        guard !beats.isEmpty else { return }

        // Quicker when there is much to show, so it ends soon after the agent's calls did.
        let natural = beats.reduce(0) { $0 + $1.glide + ($1.carry == nil ? 0 : 0.08 + $1.along) + $1.dwell }
        let k = natural > Self.longest ? Self.longest / natural : 1

        chips.forEach { $0.removeFromSuperlayer() }
        chips = []
        if !shown {
            shown = true
            pointer.removeAnimation(forKey: "fade")
            let appear = CABasicAnimation(keyPath: "opacity")
            appear.fromValue = 0
            appear.duration = 0.15
            pointer.opacity = 1
            pointer.add(appear, forKey: "appear")
        }

        // The pointer's way, as one animation: glides, and holds where something is done.
        let now = CACurrentMediaTime()
        var points = [start], times: [CFTimeInterval] = [0], curves: [CAMediaTimingFunction] = []
        let glideCurve = CAMediaTimingFunction(controlPoints: 0.3, 0, 0.2, 1), still = CAMediaTimingFunction(name: .linear)
        var t: CFTimeInterval = 0, place = start
        func go(_ point: CGPoint, _ seconds: CFTimeInterval, _ curve: CAMediaTimingFunction) {
            guard seconds > 0 else { place = point; points[points.count - 1] = point; return }
            t += seconds
            points.append(point); times.append(t); curves.append(curve)
            place = point
        }
        for beat in beats {
            if let to = beat.to { go(to, beat.glide * k, glideCurve) }
            let arrived = t
            if let carry = beat.carry {
                go(place, 0.08 * k, still)
                go(carry, beat.along * k, CAMediaTimingFunction(name: .easeInEaseOut))
            }
            beat.effect(now + arrived, k, beat.carry == nil ? place : (beat.to ?? place))
            go(place, beat.dwell * k, still)
        }
        // Chips said in a row each make way for the next.
        for (index, chip) in chips.enumerated() where index + 1 < chips.count {
            guard let group = chip.animation(forKey: "say") as? CAAnimationGroup, let next = chips[index + 1].animation(forKey: "say") else { continue }
            let room = max(0.18, next.beginTime - group.beginTime + 0.04)
            if room < group.duration {
                let shorter = group.copy() as! CAAnimationGroup
                shorter.duration = room
                removeWhenDone(chip, after: shorter)
                chip.add(shorter, forKey: "say")
            }
        }

        pointer.position = place
        if t > 0 {
            let way = CAKeyframeAnimation(keyPath: "position")
            way.values = points.map { NSValue(point: $0) }
            way.keyTimes = times.map { NSNumber(value: $0 / t) }
            way.timingFunctions = curves
            way.duration = t
            pointer.add(way, forKey: "move")
        }
    }

    // MARK: - what is drawn

    /// The pointer dips as a finger presses.
    private func press(at begin: CFTimeInterval, _ k: CFTimeInterval) {
        let dip = CAKeyframeAnimation(keyPath: "transform.scale")
        dip.values = [1, 0.82, 1]
        dip.keyTimes = [0, 0.4, 1]
        dip.duration = 0.18 * k
        dip.beginTime = begin
        pointer.add(dip, forKey: "press-\(begin)")
    }

    /// Held down along a drag.
    private func held(at begin: CFTimeInterval, _ seconds: CFTimeInterval) {
        let hold = CAKeyframeAnimation(keyPath: "transform.scale")
        hold.values = [1, 0.85, 0.85, 1]
        hold.keyTimes = [0, 0.1, 0.9, 1]
        hold.duration = seconds + 0.1
        hold.beginTime = begin
        pointer.add(hold, forKey: "held-\(begin)")
    }

    /// A ring that opens and fades where it pressed.
    private func ring(at point: CGPoint, _ begin: CFTimeInterval, _ k: CFTimeInterval, color: CGColor) {
        let radius: CGFloat = 13
        let ring = CAShapeLayer()
        ring.bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
        ring.position = point
        ring.path = CGPath(ellipseIn: ring.bounds.insetBy(dx: 1, dy: 1), transform: nil)
        ring.fillColor = color.copy(alpha: 0.18)
        ring.strokeColor = color
        ring.lineWidth = 2
        ring.opacity = 0
        ring.contentsScale = scale
        layer?.insertSublayer(ring, below: pointer)
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.35
        grow.toValue = 1.5
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.95
        fade.toValue = 0
        let both = CAAnimationGroup()
        both.animations = [grow, fade]
        both.duration = max(0.25, 0.45 * k)
        both.timingFunction = CAMediaTimingFunction(name: .easeOut)
        both.beginTime = begin
        removeWhenDone(ring, after: both)
        ring.add(both, forKey: "ring")
    }

    /// A dotted line drawn from one end of a drag to the other as the pointer goes.
    private func trail(from: CGPoint, to: CGPoint, _ begin: CFTimeInterval, _ along: CFTimeInterval) {
        let path = CGMutablePath()
        path.move(to: from)
        path.addLine(to: to)
        let line = CAShapeLayer()
        line.path = path
        line.strokeColor = AgentAccess.color.withAlphaComponent(0.75).cgColor
        line.fillColor = nil
        line.lineWidth = 3
        line.lineCap = .round
        line.lineDashPattern = [1, 6]
        line.contentsScale = scale
        line.opacity = 0
        layer?.insertSublayer(line, below: pointer)
        let held: CFTimeInterval = 0.08
        let total = held + along + 0.5
        let draw = CAKeyframeAnimation(keyPath: "strokeEnd")
        draw.values = [0, 0, 1, 1]
        draw.keyTimes = [0, NSNumber(value: held / total), NSNumber(value: (held + along) / total), 1]
        let shownFor = CAKeyframeAnimation(keyPath: "opacity")
        shownFor.values = [1, 1, 0]
        shownFor.keyTimes = [0, NSNumber(value: (held + along) / total), 1]
        let group = CAAnimationGroup()
        group.animations = [draw, shownFor]
        group.duration = total
        group.beginTime = begin
        removeWhenDone(line, after: group)
        line.add(group, forKey: "drag")
    }

    /// A field's box, lit for a moment.
    private func outline(_ rect: CGRect, _ begin: CFTimeInterval, _ k: CFTimeInterval) {
        let box = CAShapeLayer()
        box.path = CGPath(roundedRect: rect.insetBy(dx: -3, dy: -3), cornerWidth: 6, cornerHeight: 6, transform: nil)
        box.strokeColor = AgentAccess.color.cgColor
        box.fillColor = AgentAccess.color.withAlphaComponent(0.08).cgColor
        box.lineWidth = 2
        box.opacity = 0
        box.contentsScale = scale
        layer?.insertSublayer(box, below: pointer)
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.15, 0.6, 1]
        fade.duration = max(0.35, 0.7 * k)
        fade.beginTime = begin
        removeWhenDone(box, after: fade)
        box.add(fade, forKey: "outline")
    }

    /// Which way and how far the page went, drifting that way as it fades.
    private func scrolled(near point: CGPoint, delta: CGVector, moved: Bool, _ begin: CFTimeInterval, _ k: CFTimeInterval) {
        let arrow: String
        if abs(delta.dy) >= abs(delta.dx) { arrow = delta.dy > 0 ? "↓" : "↑" } else { arrow = delta.dx > 0 ? "→" : "←" }
        let amount = Int(max(abs(delta.dx), abs(delta.dy)).rounded())
        let text = moved ? "\(arrow) \(amount) pt" : "\(arrow) at the end"
        // Down the page is up on screen: the chip goes the way the page's content went.
        let drift = CGVector(dx: delta.dx == 0 ? 0 : (delta.dx > 0 ? -28 : 28), dy: delta.dy == 0 ? 0 : (delta.dy > 0 ? 28 : -28))
        say(text, near: point, begin, k, drift: moved ? drift : .zero, lasting: 0.9)
    }

    /// A short word beside the pointer (or low in the middle, before it has been anywhere).
    private func say(_ text: String, near point: CGPoint, _ begin: CFTimeInterval, _ k: CFTimeInterval,
                     drift: CGVector = .zero, lasting: CFTimeInterval = 0.8) {
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let width = ceil((text as NSString).size(withAttributes: [.font: font]).width) + 16
        let label = CATextLayer()
        label.string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white])
        label.alignmentMode = .center
        label.contentsScale = scale
        label.frame = CGRect(x: 0, y: 3, width: width, height: 15)
        let back = CALayer()
        back.bounds = CGRect(x: 0, y: 0, width: width, height: 20)
        back.cornerRadius = 10
        back.backgroundColor = AgentAccess.color.cgColor
        back.shadowColor = NSColor.black.cgColor
        back.shadowOpacity = 0.25
        back.shadowRadius = 3
        back.shadowOffset = CGSize(width: 0, height: -1)
        back.addSublayer(label)
        back.anchorPoint = CGPoint(x: 0, y: 1)
        // Below and to the right of the tip, kept inside the page.
        back.position = CGPoint(x: min(max(point.x + 14, 4), bounds.maxX - width - 4), y: min(max(point.y - 22, 24), bounds.maxY - 4))
        back.opacity = 0
        back.zPosition = 11
        layer?.addSublayer(back)
        chips.append(back)
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.12, 0.7, 1]
        let move = CABasicAnimation(keyPath: "position")
        move.fromValue = NSValue(point: back.position)
        move.toValue = NSValue(point: CGPoint(x: back.position.x + drift.dx, y: back.position.y + drift.dy))
        move.timingFunction = CAMediaTimingFunction(name: .easeOut)
        let group = CAAnimationGroup()
        group.animations = [fade, move]
        group.duration = max(0.4, lasting * k)
        group.beginTime = begin
        removeWhenDone(back, after: group)
        back.add(group, forKey: "say")
    }

    /// The Mac's signs for a key the agent named ("cmd+a" → "⌘A"); a character on its own is not shown.
    static func keyName(_ key: String) -> String {
        let signs: [String: String] = ["cmd": "⌘", "command": "⌘", "meta": "⌘", "shift": "⇧", "alt": "⌥", "option": "⌥", "opt": "⌥", "ctrl": "⌃", "control": "⌃"]
        let named: [String: String] = ["enter": "↩ Return", "return": "↩ Return", "tab": "⇥ Tab", "space": "Space", "escape": "Esc", "esc": "Esc",
                                       "backspace": "⌫", "delete": "⌦", "arrowup": "↑", "arrowdown": "↓", "arrowleft": "←", "arrowright": "→",
                                       "up": "↑", "down": "↓", "left": "←", "right": "→", "home": "Home", "end": "End", "pageup": "Page Up", "pagedown": "Page Down"]
        var parts = key.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        if key == "+" { parts = ["+"] }
        guard let last = parts.last else { return "Key" }
        let held = parts.dropLast().compactMap { signs[$0.lowercased()] }.joined()
        if let name = named[last.lowercased()] { return held + name }
        // A character typed alone is typing, and stays unsaid.
        return held.isEmpty ? "Typing…" : held + last.uppercased()
    }

    /// The layer goes once its animation has run (its own end, no timer of ours).
    private func removeWhenDone(_ layer: CALayer, after animation: CAAnimation) {
        animation.delegate = Ender(layer)
        animation.isRemovedOnCompletion = true
    }

    private nonisolated final class Ender: NSObject, CAAnimationDelegate {
        weak var layer: CALayer?
        init(_ layer: CALayer) { self.layer = layer }
        func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
            // A chip shortened to make way is replaced under the same key: the first animation's end leaves it be.
            guard flag else { return }
            layer?.removeFromSuperlayer()
        }
    }
}
