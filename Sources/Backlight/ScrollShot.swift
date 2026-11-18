import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import WebKit

// ⇧⌘S: a screenshot of as much of the page as you scroll through.
//
// A part of the view is chosen (a drag; Return, or a click, takes all of it), and then the page is scrolled by hand,
// as far and as often as wanted, up and down. A picture of the chosen part is taken whenever the page moves, and each
// is laid against the ones before it. How far the page went is asked of the page: the scroll offsets of the elements
// that scroll the chosen part (the viewport and any scrolling box around its middle) are read just before and just
// after the picture, and the picture says which row, of the few the two readings leave, is the right one (a few rows
// are compared, nothing is searched for). A page that cannot say (another site's frame, a page that moves its content
// by itself) is looked at the old way: the pictures alone, the rows of the two compared at the distance that fits best
// (the scrolling's own size breaks a tie, where a blank stretch fits at any). What is new in a
// picture (the rows past the ends of what is held) is kept, as a strip of its own, so that no more is held than the
// result is. Return puts the strips together into one picture, on the clipboard (Save in the toast puts it in
// Downloads). Esc leaves it.
//
// The picture is of the page alone (WebKit's snapshot), so the frame, the dimming and the pill are not in it. What
// stays put on the page while it scrolls (a header that sticks) is in every picture, and so in the result more than
// once: the part chosen can leave it out.
//
// Pictures are taken when something says the page moved (the scroll wheel over the window, a key), one after another
// as each is done with, and once more a moment after the last of them, for a scroll that goes on by itself: that moment
// is a debounce, not a wait for the scroll to end.

/// What the pill says and shows.
@MainActor
final class ScrollShotState: ObservableObject {
    enum Phase { case choosing, capturing, putting }
    @Published var phase = Phase.choosing
    /// A word on what is wrong (the page could not be lined up, the picture is as long as it can be).
    @Published var note = ""
    /// How much has been captured, in points.
    @Published var length = 0
}

struct ScrollShotHUD: View {
    @ObservedObject var state: ScrollShotState
    let done: () -> Void
    let cancel: () -> Void

    private var text: String {
        switch state.phase {
        case .choosing: "Drag over the part to capture · Return takes all"
        case .capturing: state.note.isEmpty ? "Scroll · \(state.length.formatted()) pt captured" : state.note
        case .putting: "Putting the picture together…"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            if state.phase == .capturing {
                Button(action: done) { Text("Done  ⏎") }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            if state.phase != .putting {
                Button(action: cancel) { Text("Cancel  ⎋") }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .glassEffect(.regular, in: Capsule())
    }
}

/// Over the page: the chosen part, with the rest dimmed.
final class ScrollShotView: NSView {
    enum Phase { case choosing, capturing }
    var phase = Phase.choosing { didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) } }
    /// In this view's points, which are the web view's (this view is flipped, as it is).
    var selection: CGRect? { didSet { needsDisplay = true } }
    /// Where what has been captured lies on the screen now, from its first row to its last, in this view's points:
    /// it moves with the page as it is scrolled.
    var coverage: (from: CGFloat, to: CGFloat)? { didSet { needsDisplay = true } }
    /// Which way what has been captured lies when it is not on the screen: -1 above, 1 below, 0 not told.
    var hint = 0 { didSet { needsDisplay = true } }
    var onChosen: ((CGRect?) -> Void)?
    var onScroll: ((NSEvent) -> Void)?
    let hud: NSView
    private var anchor: CGPoint?

    override var isFlipped: Bool { true }
    /// The window's title bar zone, at the top of Backlight's own full screen, takes a press there as the start of a move
    /// of the window (which is fixed, but the drag and the release were not heard) unless the view says it does not move it.
    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(hud: NSView) {
        self.hud = hud
        super.init(frame: .zero)
        addSubview(hud)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let size = CGSize(width: min(max(bounds.width - 32, 200), 560), height: 44)
        hud.frame = CGRect(x: (bounds.width - size.width) / 2, y: max(0, bounds.height - size.height - 20), width: size.width, height: size.height)
    }

    override func resetCursorRects() {
        if phase == .choosing { addCursorRect(bounds, cursor: .crosshair) }
    }

    override func draw(_ dirty: NSRect) {
        // Three steps of light. Outside all, the page is dimmed. The rows already captured, as wide as the chosen part,
        // are dimmed much less, with a thin edge where what is held begins and ends. The chosen part, which is the
        // page as it is now, is not dimmed at all, and has the frame. No colour of its own.
        var held: CGRect?
        if phase == .capturing, let selection, let coverage {
            let band = CGRect(x: selection.minX, y: coverage.from, width: selection.width, height: coverage.to - coverage.from).intersection(bounds)
            if !band.isNull { held = band.union(selection) }
        }
        let outer = held ?? selection
        let shade = NSBezierPath(rect: bounds)
        if let outer { shade.append(NSBezierPath(rect: outer)) }
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(phase == .choosing ? 0.38 : 0.5).setFill()
        shade.fill()
        guard let selection else { return }
        if let held, held != selection {
            let veil = NSBezierPath(rect: held)
            veil.append(NSBezierPath(rect: selection))
            veil.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.2).setFill()
            veil.fill()
            let halo = NSBezierPath(rect: held.insetBy(dx: 0.5, dy: 0.5))
            halo.lineWidth = 3
            NSColor.black.withAlphaComponent(0.25).setStroke()
            halo.stroke()
            let edge = NSBezierPath(rect: held.insetBy(dx: 0.5, dy: 0.5))
            edge.lineWidth = 1
            NSColor.white.withAlphaComponent(0.55).setStroke()
            edge.stroke()
        }
        // White with a dark edge on both sides, which a page of any colour shows.
        let dark = NSBezierPath(rect: selection.insetBy(dx: 1, dy: 1))
        dark.lineWidth = 4
        NSColor.black.withAlphaComponent(0.4).setStroke()
        dark.stroke()
        let frame = NSBezierPath(rect: selection.insetBy(dx: 1, dy: 1))
        frame.lineWidth = 2
        NSColor.white.setStroke()
        frame.stroke()
        if phase == .choosing, selection.width > 60, selection.height > 30 {
            label("\(Int(selection.width)) × \(Int(selection.height))", at: CGPoint(x: selection.minX + 6, y: selection.minY + 6))
        }
        // What is held is out of sight: which way it is.
        if phase == .capturing, hint != 0 {
            let text = hint < 0 ? "↑  Captured part" : "↓  Captured part"
            let y = hint < 0 ? max(8, selection.minY - 34) : min(bounds.maxY - 80, selection.maxY + 10)
            label(text, at: CGPoint(x: selection.midX - 60, y: y), size: 12)
        }
    }

    /// A short text on a dark pill.
    private func label(_ text: String, at point: CGPoint, size: CGFloat = 11) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium), .foregroundColor: NSColor.white]
        let label = text as NSString
        let measured = label.size(withAttributes: attributes)
        let box = CGRect(x: point.x, y: point.y, width: measured.width + 16, height: measured.height + 8)
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
        label.draw(at: CGPoint(x: box.minX + 8, y: box.minY + 4), withAttributes: attributes)
    }

    // MARK: the choosing

    /// A point in this view, held to the view and drawn to an edge that is a few points away (the pointer cannot always
    /// reach the very last row: the notch's strip, a rounded corner), so that the edge can be chosen.
    private func place(_ event: NSEvent) -> CGPoint {
        var point = convert(event.locationInWindow, from: nil)
        point.x = min(max(point.x, 0), bounds.maxX)
        point.y = min(max(point.y, 0), bounds.maxY)
        let reach: CGFloat = 4
        if point.x < reach { point.x = 0 } else if point.x > bounds.maxX - reach { point.x = bounds.maxX }
        if point.y < reach { point.y = 0 } else if point.y > bounds.maxY - reach { point.y = bounds.maxY }
        return point
    }

    override func mouseDown(with event: NSEvent) {
        guard phase == .choosing else { return }
        anchor = place(event)
        Debug.log("shot", "choosing from \(anchor!) in \(bounds.size)")
        selection = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard phase == .choosing, let anchor else { return }
        let point = place(event)
        let box = CGRect(x: min(anchor.x, point.x), y: min(anchor.y, point.y), width: abs(point.x - anchor.x), height: abs(point.y - anchor.y))
        selection = box.intersection(bounds)
    }

    override func mouseUp(with event: NSEvent) {
        guard phase == .choosing else { return }
        anchor = nil
        // A click, or a drag too small to mean anything: all of the view.
        if let selection, selection.width >= 40, selection.height >= 40 {
            onChosen?(selection)
        } else {
            selection = nil
            onChosen?(nil)
        }
    }

    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}

    /// The wheel is the page's: it goes to the page, and the page is looked at again once it has moved.
    override func scrollWheel(with event: NSEvent) {
        onScroll?(event)
    }
}

/// One thing of the picture taken: rows not in any strip before, at their place in the page's own rows.
nonisolated struct ShotStrip: @unchecked Sendable {
    let y: Int
    let image: CGImage
}

/// A picture's rows as grey levels, as wide as is worth comparing.
nonisolated struct ShotGrey: Sendable {
    static let columns = 128
    let height: Int
    let pixels: [UInt8]
}

nonisolated enum ShotMatch {
    /// How the page went from `previous` to `now`: `same`, a distance (positive when the page went up, as
    /// it does when scrolled down), or `lost` when no distance fits.
    enum Result {
        case same, moved(Int), lost
        /// Several distances fit and the wheel does not say which (the page is still moving): to be looked at again.
        case unsure
    }

    static func grey(_ image: CGImage) -> ShotGrey? {
        let wide = ShotGrey.columns, high = image.height
        guard high > 0, let context = CGContext(data: nil, width: wide, height: high, bitsPerComponent: 8, bytesPerRow: wide,
                                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = context.data
        else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: wide, height: high))
        let bytes = UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: wide * high)
        return ShotGrey(height: high, pixels: Array(bytes))
    }

    /// Where `now` lies against the rows held (`canvas`, whose first row is page row `top`), as a distance from where the last
    /// good picture lay (`offset`): the page row of the picture's first row is `offset + distance`. `prior` is what the
    /// scroll wheel said since, in rows.
    static func distance(now: ShotGrey, in canvas: ShotGrey, top: Int, offset: Int, prior: Int, enforce: Bool, blind: Bool = false) -> Result {
        let height = now.height, wide = ShotGrey.columns
        guard height >= 64, canvas.height >= 1 else { return .lost }
        let minOverlap = max(48, min(height, canvas.height) / 8)
        let step = max(1, height / 80)
        let rows = Array(stride(from: 0, to: height, by: step))
        func score(_ d: Int) -> Double? {
            let base = offset + d - top
            var sum = 0, count = 0
            canvas.pixels.withUnsafeBufferPointer { p in
                now.pixels.withUnsafeBufferPointer { n in
                    for y in rows {
                        let c = base + y
                        if c < 0 || c >= canvas.height { continue }
                        var x = 0
                        let a = y * wide, b = c * wide
                        while x < wide {
                            sum += abs(Int(n[a + x]) - Int(p[b + x]))
                            x += 2
                        }
                        count += 1
                    }
                }
            }
            guard count * step >= minOverlap else { return nil }
            return Double(sum) / Double(count * (wide / 2))
        }
        // No distance at all fits as well as the page against itself, but where the wheel says the page went a good
        // way, that is no answer: a flat stretch or one that repeats fits at that distance too (a thin strip down a menu
        // does), and the search below picks, of what fits, the distance nearest the wheel's.
        if let still = score(0), still < 1.0, abs(prior) < 6 { return .same }
        var best = Double.infinity
        var bestAt = 0
        var scores: [(d: Int, score: Double)] = []
        // Anywhere the picture overlaps what is held by enough.
        var low = top - (height - minOverlap) - offset
        var high = top + canvas.height - minOverlap - offset
        // Where a trackpad says the page went, and not far from it: nothing else is looked at (it is also a third of
        // the work).
        if !blind {
            // Close to where the wheel says the page went, or to where it was if it says nothing (a key): the whole held
            // page is searched only when the pictures alone have to say (a page that was at its end, say).
            let around = enforce ? max(height / 3, abs(prior) * 35 / 100) : max(height, abs(prior) * 3 / 2)
            low = max(low, prior - around)
            high = min(high, prior + around)
        }
        guard low <= high else { return .lost }
        for d in low...high {
            guard let s = score(d) else { continue }
            scores.append((d, s))
            if s < best { best = s; bestAt = d }
        }
        // The same page drawn twice is the same to a grey level or two; a fit that is worse is of something else.
        guard best < (blind ? 2 : 4) else { return .lost }
        // Without the wheel to say where, only a fit that is as good as the page against itself, and the only such: a
        // stretch that repeats (flat colour, a table) fits in many places.
        if blind, scores.contains(where: { abs($0.d - bestAt) > 6 && $0.score <= best + 1.5 }) { return .lost }
        // Of the distances that fit as well as the best (a blank stretch fits at many), the one nearest what the wheel said.
        let fitting = scores.filter { $0.score <= best + 0.75 }
        guard let pick = fitting.min(by: { abs($0.d - prior) < abs($1.d - prior) }) else { return .lost }
        // Many distances fit (a menu, a flat stretch): the wheel has to say which, and the page has to have got there. A
        // picture taken while it is still on its way is of no use and is let go, not taken for a guess.
        if !blind, fitting.contains(where: { abs($0.d - bestAt) > 6 }), abs(pick.d - prior) > max(6, abs(prior) / 30) { return .unsure }
        // The wheel is not exact, but a page that went one way a long distance did not go the other, or only a little
        // (the match is then of something else that looks alike: the page went further than the two overlap).
        if prior != 0 {
            // A trackpad's distance is the page's; a mouse wheel's only about (the page and the system decide).
            let tolerance = enforce ? max(height / 3, abs(prior) * 35 / 100) : max(height / 2, abs(prior) * 60 / 100)
            if abs(pick.d - prior) > tolerance { return .lost }
            // The page went about as far as the picture is high, or further: there is little or no overlap to match,
            // and a match far from where the wheel puts it is of something else that looks alike.
            if abs(prior) * 100 >= height * 85, abs(pick.d - prior) > height / 4 { return .lost }
            // Without a distance, the direction still holds: a page that went one way did not go the other.
            if !enforce, abs(prior) > 16, abs(pick.d) > 16, (pick.d > 0) != (prior > 0) { return .lost }
        }
        return pick.d == 0 ? .same : .moved(pick.d)
    }

    enum Located {
        /// The page row of the picture's first row.
        case at(Int)
        /// The picture fits none of the places the page said: the page's offsets are not what moved the picture.
        case off
        /// None of the places touches the rows held: the page went further than the picture is high.
        case apart
    }

    /// Where, of the places in `range` (page rows of the picture's first row), `now` lies against the rows held: the one
    /// that fits best, and the one nearest `preferred` of those that fit as well. Only a few rows of each are compared.
    static func locate(now: ShotGrey, in canvas: ShotGrey, top: Int, range: ClosedRange<Int>, preferred: Int) -> Located {
        let height = now.height, wide = ShotGrey.columns
        guard height >= 16, canvas.height >= 1 else { return .apart }
        let step = max(1, height / 80)
        let bottom = top + canvas.height
        var found: [(p: Int, score: Double)] = []
        var touching: [Int] = []
        var verifiable = false
        for p in range {
            if p + height < top || p > bottom { continue }
            touching.append(p)
            var sum = 0.0
            var count = 0, good = 0
            canvas.pixels.withUnsafeBufferPointer { c in
                now.pixels.withUnsafeBufferPointer { n in
                    var y = 0
                    while y < height {
                        let r = p - top + y
                        if r >= 0, r < canvas.height {
                            var s = 0, x = 0
                            while x < wide {
                                s += abs(Int(n[y * wide + x]) - Int(c[r * wide + x]))
                                x += 2
                            }
                            let mean = Double(s) / Double(wide / 2)
                            // A header that sticks is the same on the screen and not in the page: its rows are let be wrong.
                            sum += min(mean, 24)
                            if mean < 8 { good += 1 }
                            count += 1
                        }
                        y += step
                    }
                }
            }
            guard count >= 6 else { continue }
            verifiable = true
            if good * 2 >= count { found.append((p, sum / Double(count))) }
        }
        if let best = found.map(\.score).min(),
           let pick = found.filter({ $0.score <= best + 0.75 }).min(by: { abs($0.p - preferred) < abs($1.p - preferred) }) {
            return .at(pick.p)
        }
        if verifiable { return .off }
        // Touching, and too little overlap to compare: the page's word is taken.
        guard let near = touching.min(by: { abs($0 - preferred) < abs($1 - preferred) }) else { return .apart }
        return .at(near)
    }

    /// The rows of `image` from `from` up to `to`, as a picture of their own (a crop would hold the whole one).
    static func strip(of image: CGImage, rows from: Int, to: Int, at y: Int) -> ShotStrip? {
        guard to > from, let cropped = image.cropping(to: CGRect(x: 0, y: from, width: image.width, height: to - from)),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: cropped.width, height: cropped.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        guard let own = context.makeImage() else { return nil }
        return ShotStrip(y: y, image: own)
    }

    /// The strips as one picture, as a PNG.
    static func compose(_ strips: [ShotStrip], top: Int, bottom: Int, width: Int) -> (png: Data, width: Int, height: Int)? {
        let high = bottom - top
        guard high > 0, width > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: high, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: high))
        for strip in strips {
            // The page's rows run down, the context's up.
            let drawn = CGRect(x: 0, y: high - (strip.y - top) - strip.image.height, width: strip.image.width, height: strip.image.height)
            context.draw(strip.image, in: drawn)
        }
        guard let image = context.makeImage() else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (out as Data, width, high)
    }
}

/// What the pictures taken so far have made of the page, carried from one picture to the next.
nonisolated struct ShotHeld: Sendable {
    /// All the rows held, as grey levels (the picture is laid against all of them, not only the last picture, so that a
    /// page scrolled back over what was captured long ago is found there).
    var canvas: ShotGrey?
    /// Where the last good picture lay in the page's rows, and the rows held (first to one past the last).
    var offset = 0, top = 0, bottom = 0
    /// What the wheel had said in all, and how many of its lines were not points, when that picture was taken: the wheel
    /// is counted from there, so that a page that did not move (it is at its top, say) leaves nothing behind.
    var wheelAt: CGFloat = 0
    var impreciseAt = 0
    /// Whether the page's scroll offsets say how far it went (they did at the first picture, and still agree with the
    /// pictures), the offset at the first picture, and how many pictures in a row they did not fit.
    var exact = false
    var scroll0 = 0
    var strikes = 0
    /// How far the pictures have reached, from the first row of the highest one to one past the last row of the lowest. What
    /// `top`..`bottom` hold (and the strips) is only what lies well in from the ends of the pictures: what sticks to the
    /// window (a header, a button in a corner) is in every picture at the same place on the screen, and rows taken from the
    /// edge of each would stack it up all down the page. The rows nearer the ends than that are kept apart, from the one
    /// picture that reached furthest (`pendTop`, `pendBottom`), and are put at the ends of the page once, at the end.
    var edgeTop = 0, edgeBottom = 0
    var pendTop: ShotStrip?
    var pendBottom: ShotStrip?
}

/// A picture of the part, with what the wheel had said when it was asked for.
nonisolated struct ShotFrame: @unchecked Sendable {
    let image: CGImage
    let wheelAt: CGFloat
    let impreciseAt: Int
    /// What the page said of its scrolling, in pixels, just before the picture and just after (nil: it said nothing).
    let scrollA: Double?
    let scrollB: Double?
    /// Taken after the page had said nothing more for a moment, so that the page is where it is going to stay.
    let settled: Bool
    /// The last one: the screenshot is over when it is dealt with.
    let final: Bool
}

/// What came of dealing with a picture.
nonisolated struct ShotStep: @unchecked Sendable {
    let held: ShotHeld
    let result: ShotMatch.Result?
    let strips: [ShotStrip]
    /// A part that was new was left out: the picture is as large as it may be.
    let full: Bool
    let width: Int
    let rows: Int
    let final: Bool
    /// The picture lay beyond the rows held, by the page's own word (it was taken after the page went further than the
    /// picture is high): the page is to be taken back over the gap, which `scrollA` (the page's scroll then) says the size of.
    let apart: Bool
    let scrollA: Double?
    /// Found in a wider look than the page's two readings leave.
    let wide: Bool
}

nonisolated enum ShotWork {
    /// How far in from the ends of a picture the rows kept as they come begin: a quarter of it, and no more than 600.
    static func margin(_ rows: Int) -> Int { min(rows / 4, 600) }

    /// Off the main thread: where the picture lies against the ones before it, and the rows of it that are new.
    static func advance(_ held: ShotHeld, with frame: ShotFrame, scale: CGFloat, budget: Int) -> ShotStep {
        var held = held
        let image = frame.image, rows = image.height
        var apart = false, wide = false
        func step(_ result: ShotMatch.Result?, _ strips: [ShotStrip] = [], full: Bool = false) -> ShotStep {
            ShotStep(held: held, result: result, strips: strips, full: full, width: image.width, rows: image.height, final: frame.final,
                     apart: apart, scrollA: frame.scrollA, wide: wide)
        }
        guard let grey = ShotMatch.grey(image) else { return step(nil) }
        let cols = ShotGrey.columns
        let m = ShotWork.margin(rows)
        guard let canvas = held.canvas else {
            let strip = ShotMatch.strip(of: image, rows: m, to: rows - m, at: m)
            held = ShotHeld(canvas: ShotGrey(height: rows - 2 * m, pixels: Array(grey.pixels[(m * cols)..<((rows - m) * cols)])), offset: 0, top: m, bottom: rows - m,
                            wheelAt: frame.wheelAt, impreciseAt: frame.impreciseAt)
            held.edgeTop = 0
            held.edgeBottom = rows
            held.pendTop = ShotMatch.strip(of: image, rows: 0, to: m, at: 0)
            held.pendBottom = ShotMatch.strip(of: image, rows: rows - m, to: rows, at: rows - m)
            if let a = frame.scrollA, frame.scrollB != nil {
                held.exact = true
                held.scroll0 = Int(a.rounded())
            }
            return step(.same, strip.map { [$0] } ?? [])
        }
        var found: ShotMatch.Result?
        if held.exact {
            // The page says where, within a few rows (it may have moved between the two readings), and the picture says
            // which of them.
            if let a = frame.scrollA, let b = frame.scrollB {
                let low = Int(min(a, b).rounded(.down)) - 1 - held.scroll0, high = Int(max(a, b).rounded(.up)) + 1 - held.scroll0
                if high - low > rows * 2 {
                    found = .unsure
                } else {
                    let preferred = Int(a.rounded()) - held.scroll0
                    var located = ShotMatch.locate(now: grey, in: canvas, top: held.top, range: low...high, preferred: preferred)
                    // The picture was not taken where the page's readings put it (a page that is being scrolled on a thread
                    // of its own is a little ahead of what it says): a wider look, which the picture alone can answer.
                    if case .off = located {
                        let more = max(rows / 2, 300)
                        located = ShotMatch.locate(now: grey, in: canvas, top: held.top, range: (low - more)...(high + more), preferred: preferred)
                        if case .at = located { wide = true }
                    }
                    switch located {
                    case .at(let p):
                        held.strikes = 0
                        found = p == held.offset ? .same : .moved(p - held.offset)
                    case .apart:
                        apart = true
                        found = .lost
                    case .off:
                        held.strikes += 1
                    }
                }
            } else {
                held.strikes += 1
            }
            // The page's offsets do not move the picture at all, again and again (the part is of something else: a frame
            // of another site, fixed content): the pictures alone, from here on. Fewer than that, the picture is let go.
            if found == nil {
                if held.strikes >= 12 { held.exact = false } else { return step(.unsure) }
            }
        }
        let prior = Int((-(frame.wheelAt - held.wheelAt) * scale).rounded())
        let enforce = frame.impreciseAt == held.impreciseAt
        var result = found ?? ShotMatch.distance(now: grey, in: canvas, top: held.top, offset: held.offset, prior: prior, enforce: enforce)
        // The wheel and the page disagree (the page was at its end, or the wheel is not a distance): the pictures alone
        // may still say where, if they say it plainly.
        if found == nil, case .lost = result { result = ShotMatch.distance(now: grey, in: canvas, top: held.top, offset: held.offset, prior: 0, enforce: false, blind: true) }
        switch result {
        case .lost:
            return step(.lost)
        case .unsure:
            return step(.unsure)
        case .same:
            // The page is where it was and has said all it is going to: what the wheel said that did not move it is let go.
            if frame.settled { held.wheelAt = frame.wheelAt; held.impreciseAt = frame.impreciseAt }
            return step(.same)
        case .moved(let d):
            let placed = held.offset + d
            var strips: [ShotStrip] = []
            var room = budget / max(image.width, 1) - (held.edgeBottom - held.edgeTop)
            var full = false
            var pixels = canvas.pixels
            // Below: rows from where what is held ends, down to the margin above the picture's own foot.
            if placed + rows > held.edgeBottom, placed <= held.bottom {
                let end = placed + rows - m
                if end > held.bottom {
                    let from = held.bottom - placed
                    let count = end - held.bottom
                    if count <= room, let strip = ShotMatch.strip(of: image, rows: from, to: from + count, at: held.bottom) {
                        strips.append(strip)
                        pixels.append(contentsOf: grey.pixels[(from * cols)..<((from + count) * cols)])
                        held.bottom = end
                        room -= count
                    } else {
                        full = true
                    }
                }
                let from = held.bottom - placed
                if from < rows { held.pendBottom = ShotMatch.strip(of: image, rows: from, to: rows, at: held.bottom) }
                held.edgeBottom = placed + rows
            }
            // Above: the same, from the head of the picture.
            if placed < held.edgeTop, placed + rows >= held.top {
                let start = placed + m
                if start < held.top {
                    let count = held.top - start
                    if count <= room, let strip = ShotMatch.strip(of: image, rows: m, to: m + count, at: start) {
                        strips.append(strip)
                        pixels.insert(contentsOf: grey.pixels[(m * cols)..<((m + count) * cols)], at: 0)
                        held.top = start
                    } else {
                        full = true
                    }
                }
                let upTo = held.top - placed
                if upTo > 0 { held.pendTop = ShotMatch.strip(of: image, rows: 0, to: min(upTo, rows), at: placed) }
                held.edgeTop = placed
            }
            held.canvas = ShotGrey(height: held.bottom - held.top, pixels: pixels)
            held.offset = placed
            held.wheelAt = frame.wheelAt
            held.impreciseAt = frame.impreciseAt
            return step(result, strips, full: full)
        }
    }
}

/// One scrolling screenshot, from the choosing to the picture.
@MainActor
final class ScrollShot {
    private unowned let window: BrowserWindow
    private let web: WKWebView
    private let state = ScrollShotState()
    private var overlay: ScrollShotView!
    private var keys: Any?

    private var area = CGRect.zero
    private var scale: CGFloat = 2
    private var phase = ScrollShotState.Phase.choosing

    // What is held: strips of the page, and where the last good picture lay in the page's rows.
    private var strips: [ShotStrip] = []
    private var held = ShotHeld()
    private var pixelWidth = 0

    // What asks for the next picture.
    private var taking = false
    private var dirty = false
    private var settledNext = false
    private var finishing = false
    private var finalAsked = false
    private var ended = false
    private var settle: DispatchWorkItem?
    /// Pictures taken and not yet dealt with: dealing is in order and off the main thread, and the next picture is
    /// taken while it goes on, so that pictures follow a fast scroll closely.
    private var inFlight = 0
    private var chain = Task<ShotHeld, Never> { ShotHeld() }
    /// Everything the wheel has said, in points (down is negative), and how many of its lines were not points.
    private var wheelTotal: CGFloat = 0
    private var impreciseCount = 0
    // The scroll is slowed: every wheel event is given to the page at a part of its size (`slowed`), whatever it is, so
    // that it feels the same all through (no event is kept back, and the phases of a trackpad's gesture stay whole), and
    // none more than a part of the chosen part's height (a mouse wheel's one event can be many lines). It is what the
    // pictures, which follow one another at about a tenth of a second, can follow. What was left over by rounding is
    // carried to the next event.
    private let slowed: CGFloat = 0.4
    private var carried: Double = 0

    /// At most this many pixels in the picture, as for the page's own (PageShot.swift).
    private let budget = 40_000_000

    /// The page's own scroll offsets are read in a world of their own, so that nothing of the page's can reach them. What
    /// is read is, in pixels, the sum of the scroll offsets of everything that scrolls the middle of the chosen part: the
    /// viewport, and any box that scrolls around it (a frame of the same site too).
    private let world = WKContentWorld.world(name: "BacklightScrollShot")
    private var sampling = false
    /// The page is being taken over a gap it jumped across (a flick went further than the part is high between two pictures),
    /// to this scroll (in the page's pixels), a part at a time; the wheel is not given to the page meanwhile.
    private var closing: Double?
    private var closingToken = 0
    private static func samplerScript(x: Double, y: Double) -> String {
        """
        (function (x, y) {
          try {
            var doc = document, cx = x, cy = y, list = [], seen = new Set();
            function add(e) { if (e && !seen.has(e)) { seen.add(e); list.push(e); } }
            for (var depth = 0; depth < 5; depth++) {
              var hit = doc.elementFromPoint(cx, cy);
              if (!hit) break;
              while (hit.shadowRoot && hit.shadowRoot.elementFromPoint) {
                var inner = hit.shadowRoot.elementFromPoint(cx, cy);
                if (!inner || inner === hit) break;
                hit = inner;
              }
              add(doc.scrollingElement);
              for (var n = hit; n; n = n.parentElement || (n.getRootNode && n.getRootNode().host)) {
                if (n !== doc.documentElement && n !== doc.body) add(n);
              }
              if (/^i?frame$/i.test(hit.tagName)) {
                var inside = null;
                try { inside = hit.contentDocument; } catch (e) {}
                if (!inside) break;
                var r = hit.getBoundingClientRect();
                cx -= r.left; cy -= r.top; doc = inside;
                continue;
              }
              break;
            }
            var prev = list.map(function (e) { return e.scrollTop; }), mover = null;
            var shot = window.__backlightShot = { list: list, read: function () {
              var sum = 0, most = 0;
              for (var i = 0; i < list.length; i++) {
                var top = list[i].scrollTop;
                if (Math.abs(top - prev[i]) > most) { most = Math.abs(top - prev[i]); mover = list[i]; }
                prev[i] = top;
                sum += top;
              }
              return sum * window.devicePixelRatio;
            }, to: function (target) {
              // The page taken to a scroll (in pixels, as read gives it) by the one of its boxes that has been moving.
              var now = shot.read(), el = mover || list[0];
              var old = el.style.scrollBehavior;
              el.style.scrollBehavior = 'auto';
              el.scrollTop = el.scrollTop + (target - now) / window.devicePixelRatio;
              el.style.scrollBehavior = old;
              return shot.read();
            } };
            return shot.read();
          } catch (e) { return null; }
        })(\(x), \(y))
        """
    }

    /// The page taken to a scroll in its own pixels, at once; then `done`.
    private func scrollPage(to target: Double, then done: @escaping () -> Void) {
        web.evaluateJavaScript("window.__backlightShot ? window.__backlightShot.to(\(target)) : null", in: nil, in: world) { _ in
            MainActor.assumeIsolated { done() }
        }
    }

    /// The page's scroll, in pixels now (nil: it cannot say).
    private func readScroll(_ then: @escaping (Double?) -> Void) {
        guard sampling else { return then(nil) }
        web.evaluateJavaScript("window.__backlightShot ? window.__backlightShot.read() : null", in: nil, in: world) { result in
            let value: Double? = { if case .success(let any) = result { return (any as? NSNumber)?.doubleValue } else { return nil } }()
            MainActor.assumeIsolated { then(value) }
        }
    }

    init(window: BrowserWindow, web: WKWebView) {
        self.window = window
        self.web = web
        scale = window.window?.backingScaleFactor ?? 2
        let hud = NSHostingView(rootView: ScrollShotHUD(state: state, done: { [weak self] in self?.finish() }, cancel: { [weak self] in self?.cancel() }))
        hud.sizingOptions = []
        hud.safeAreaRegions = []
        overlay = ScrollShotView(hud: hud)
        overlay.onChosen = { [weak self] box in self?.chosen(box) }
        overlay.onScroll = { [weak self] event in self?.scrolled(event) }
    }

    var view: NSView { overlay }

    func begin() {
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Nil takes the key away from everything else.
            let taken = MainActor.assumeIsolated { self?.key(event) ?? false }
            return taken ? nil : event
        }
    }

    // MARK: choosing and the keys

    private func chosen(_ box: CGRect?) {
        area = (box ?? overlay.bounds).integral
        guard area.width >= 40, area.height >= 40 else { return cancel() }
        Debug.log("shot", "chosen \(area) of \(overlay.bounds.size)")
        overlay.selection = area
        overlay.phase = .capturing
        phase = .capturing
        state.phase = .capturing
        // What the page says of its scrolling, to begin with; then the first picture, of the page where it is.
        let zoom = max(web.pageZoom, 0.1)
        web.evaluateJavaScript(ScrollShot.samplerScript(x: Double(area.midX / zoom), y: Double(area.midY / zoom)), in: nil, in: world) { [weak self] result in
            let said: Bool = { if case .success(let any) = result { return any is NSNumber } else { return false } }()
            MainActor.assumeIsolated {
                guard let self, !self.ended else { return }
                self.sampling = said
                Debug.log("shot", said ? "the page says its scroll offsets" : "the page says nothing of its scroll: the pictures alone")
                self.dirty = true
                self.kick()
            }
        }
    }

    /// Whether the key was this screenshot's.
    private func key(_ event: NSEvent) -> Bool {
        guard event.window === window.window else { return false }
        switch event.keyCode {
        case 53:
            cancel()
            return true
        case 36, 76:
            if phase == .choosing { chosen(nil) } else { finish() }
            return true
        default:
            // Space, the arrows, Page Down: the page may move.
            if phase == .capturing { moved(by: 0) }
            return false
        }
    }

    private func scrolled(_ event: NSEvent) {
        guard phase == .capturing else { return web.scrollWheel(with: event) }
        // The page is being taken back over a gap: the wheel waits (what it says now would only undo it).
        if closing != nil { return }
        let precise = event.hasPreciseScrollingDeltas
        guard event.scrollingDeltaY != 0 else { return web.scrollWheel(with: event) }
        // What the page is given, and how far that goes, in points: a trackpad's is a distance and is cut as it is; a
        // mouse wheel's is a number of whole lines (the page goes 40 points to a line, and takes no part of one), at
        // least one, and so many that none is more than a part of the chosen part's height.
        let cap = area.height * 0.4
        let given: CGFloat
        if precise {
            given = event.scrollingDeltaY * min(slowed, cap / abs(event.scrollingDeltaY * 1))
            web.scrollWheel(with: shortened(event, to: given / event.scrollingDeltaY, lines: nil))
        } else {
            let wanted = abs(event.scrollingDeltaY) * slowed
            let lines = max(1, min(wanted.rounded(), (cap / 40).rounded(.down)))
            given = (event.scrollingDeltaY < 0 ? -lines : lines) * 40
            impreciseCount += 1
            web.scrollWheel(with: shortened(event, to: 1, lines: event.scrollingDeltaY < 0 ? -lines : lines))
        }
        moved(by: given)
    }

    /// The same event with its distance changed: a copy made from the system's own, with its distance fields set, to
    /// `part` of what it was (a trackpad's) or to a number of lines (a mouse wheel's).
    private func shortened(_ event: NSEvent, to part: CGFloat, lines: CGFloat?) -> NSEvent {
        guard let cg = event.cgEvent?.copy() else { return event }
        if let lines {
            cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(lines))
            cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(lines * 10))
            cg.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64(lines))
        } else {
            let fixed = Double(event.scrollingDeltaY * part)
            cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: fixed)
            // Rounding is carried to the next event, so that nothing is lost.
            carried += fixed
            let whole = carried.rounded(.towardZero)
            carried -= whole
            cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(whole))
            cg.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64(whole))
        }
        return NSEvent(cgEvent: cg) ?? event
    }

    // MARK: taking pictures

    /// The page may have moved; `by` is how far the wheel says, in points (down is negative).
    private func moved(by points: CGFloat) {
        wheelTotal += points
        dirty = true
        kick()
        // A scroll that goes on by itself (a key's, a smooth scroll, the page at its end) says nothing more: one look
        // after the last word, taken as the page's resting place.
        settle?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.settledNext = true
                self?.dirty = true
                self?.kick()
            }
        }
        settle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }

    private func kick() {
        guard !ended, !taking, inFlight < 2, phase != .choosing, !(finishing && finalAsked), dirty || finishing else { return }
        guard window.shownWeb === web else { return cancel() }
        dirty = false
        taking = true
        let last = finishing
        if last { finalAsked = true }
        let settled = settledNext || last
        settledNext = false
        let (wheelAt, impreciseAt) = (wheelTotal, impreciseCount)
        let config = WKSnapshotConfiguration()
        config.rect = area
        // Points: the picture is as many pixels wide as the screen has to a point.
        config.snapshotWidth = NSNumber(value: Double(area.width))
        config.afterScreenUpdates = true
        token += 1
        let mine = token
        // The page's scroll, the picture, the page's scroll again: the page's messages are dealt with in order.
        readScroll { [weak self] before in
            guard let self, self.token == mine else { return }
            self.web.takeSnapshot(with: config) { [weak self] image, _ in
                MainActor.assumeIsolated {
                    guard let self, self.token == mine else { return }
                    self.readScroll { after in
                        guard self.token == mine else { return }
                        self.received(image, mine, wheelAt: wheelAt, impreciseAt: impreciseAt, scroll: (before, after), settled: settled, final: last)
                    }
                }
            }
        }
        // The page that never answers.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.taking, self.token == mine else { return }
                self.taking = false
                self.token += 1
                if last { self.putWhenDealt() }
            }
        }
    }

    /// Which picture is being asked for, for the watchdog above.
    private var token = 0

    private func received(_ image: NSImage?, _ mine: Int, wheelAt: CGFloat, impreciseAt: Int, scroll: (Double?, Double?), settled: Bool, final: Bool) {
        guard mine == token else { return }
        taking = false

        guard phase != .putting, let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            if final { putWhenDealt() }
            return kickAgain()
        }
        let frame = ShotFrame(image: cg, wheelAt: wheelAt, impreciseAt: impreciseAt, scrollA: scroll.0, scrollB: scroll.1, settled: settled, final: final)
        let previous = chain
        let (scale, budget) = (scale, budget)
        inFlight += 1
        let began = DispatchTime.now()
        chain = Task.detached(priority: .utility) { [weak self] in
            let before = await previous.value
            let step = ShotWork.advance(before, with: frame, scale: scale, budget: budget)
            let took = DispatchTime.now().uptimeNanoseconds - began.uptimeNanoseconds
            await MainActor.run { self?.dealt(step, took: took) }
            return step.held
        }
        // The next picture is taken while this one is dealt with.
        kickAgain()
    }

    private func kickAgain() {
        if finishing, !finalAsked { return kick() }
        kick()
    }

    private func dealt(_ step: ShotStep, took: UInt64) {
        inFlight -= 1
        Debug.log("shot", "picture \(step.result.map { "\($0)" } ?? "unreadable") (\(step.held.exact ? (step.wide ? "by the page's offsets, wider" : "by the page's offsets") : "by the pictures")), \(took / 1_000_000) ms with the wait, \(step.width) px wide, held \(step.held.edgeBottom - step.held.edgeTop) rows, \(inFlight) more on the way")
        guard phase != .putting, !ended else { return }
        if !step.held.exact { sampling = false }
        pixelWidth = step.width
        switch step.result {
        case .some(.unsure):
            // Taken while the page was moving: while it is being taken back, once more.
            if closing != nil { dirty = true }
        case .some(.lost):
            // A jump over rows not held: the page is taken back, a part at a time, and then to where it was going.
            if closing != nil { break }
            if step.apart, step.held.exact, let target = step.scrollA {
                closing = target
                Debug.log("shot", "the page went further than the part is high between two pictures: taking it back over the gap")
                held = step.held
                closeGap(with: step)
                break
            }
            // Which way the captured part lies: the page went the way the wheel has said since the last good picture.
            let wentDown = wheelTotal - held.wheelAt < 0
            overlay.coverage = nil
            overlay.hint = wentDown ? -1 : 1
            state.note = wentDown ? "Too far down: scroll back up" : "Too far up: scroll back down"
        case .some:
            state.note = ""
            strips.append(contentsOf: step.strips)
            held = step.held
            state.length = Int(CGFloat(held.edgeBottom - held.edgeTop) / scale)
            overlay.hint = 0
            showCoverage()
            if step.full { state.note = "As long as it gets: press Return" }
            if closing != nil { closeGap(with: step) }
        case nil:
            break
        }
        if step.final { return put() }
        // Fewer in flight: the next can be taken.
        kick()
    }

    /// The next part of the way back over a gap: the page goes to where the rows held end (a little inside them, so that the
    /// picture can be checked against them), and when the place it was going to is within reach of them, to that.
    private func closeGap(with step: ShotStep) {
        guard let target = closing else { return }
        let held = step.held
        let place = Int(target.rounded()) - held.scroll0
        let overlap = max(24, step.rows / 10)
        var next = target
        var last = true
        if place > held.bottom {
            next = Double(held.bottom - overlap + held.scroll0)
            last = false
        } else if place + step.rows < held.top {
            next = Double(held.top - step.rows + overlap + held.scroll0)
            last = false
        }
        if last { closing = nil }
        closingToken += 1
        let mine = closingToken
        scrollPage(to: next) { [weak self] in
            guard let self, !self.ended else { return }
            self.dirty = true
            self.kick()
        }
        // The page that does not take the offset (it never answers, or the pictures do not follow): not stuck there.
        if !last {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.closing != nil, self.closingToken == mine else { return }
                    self.closing = nil
                    self.state.note = "Too far: scroll back"
                }
            }
        }
    }

    /// Where the rows held lie on the screen, as of the last good picture.
    private func showCoverage() {
        guard phase == .capturing, !strips.isEmpty else { return overlay.coverage = nil }
        let here = CGFloat(held.offset)
        let (from, to) = (area.minY + (CGFloat(held.edgeTop) - here) / scale, area.minY + (CGFloat(held.edgeBottom) - here) / scale)
        overlay.coverage = (from, to)
        // Out of sight, above or below: which.
        overlay.hint = to < 0 ? -1 : (from > overlay.bounds.maxY ? 1 : 0)
    }

    // MARK: the end

    func finish() {
        guard phase == .capturing, !finishing else { return }
        finishing = true
        settle?.cancel()
        // One last look, for where the page is now.
        dirty = true
        kick()
    }

    /// The pictures before it dealt with, then the end.
    private func putWhenDealt() {
        let waiting = chain
        Task { @MainActor in
            _ = await waiting.value
            self.put()
        }
    }

    func cancel() {
        guard phase != .putting else { return }
        end()
        window.say("Scrolling screenshot cancelled")
    }

    private func end() {
        ended = true
        settle?.cancel()
        if let keys { NSEvent.removeMonitor(keys) }
        keys = nil
        overlay.removeFromSuperview()
        window.scrollShot = nil
    }

    private func put() {
        guard phase != .putting else { return }
        phase = .putting
        state.phase = .putting
        guard !strips.isEmpty else {
            end()
            return window.say("Nothing was captured")
        }
        end()
        window.say("Putting the picture together…")
        // The rows at the ends of the page come from the pictures that reached furthest: once each.
        let (pieces, top, bottom, width) = (strips + [held.pendTop, held.pendBottom].compactMap { $0 }, held.edgeTop, held.edgeBottom, pixelWidth)
        let window = window
        Task.detached(priority: .utility) {
            let made = ShotMatch.compose(pieces, top: top, bottom: bottom, width: width)
            await MainActor.run {
                guard let made else { return window.say("The picture couldn't be put together") }
                let board = NSPasteboard.general
                board.clearContents()
                board.setData(made.png, forType: .png)
                let save = Toast.Action(title: "Save", symbol: "square.and.arrow.down", help: "Save the picture in Downloads", label: "Save screenshot") { [weak window] in
                    window?.say(ScrollShot.save(made.png))
                }
                window.say("Screenshot copied (\(made.width.formatted()) × \(made.height.formatted()))", actions: [save])
            }
        }
    }

    /// In Downloads, named for when it was taken. What to say about it.
    static func save(_ png: Data) -> String {
        guard let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return "Downloads couldn't be found" }
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let file = folder.appendingPathComponent("Backlight Screenshot \(stamp.string(from: Date())).png")
        do {
            try png.write(to: file)
            return "Saved to Downloads"
        } catch {
            return "The picture couldn't be saved"
        }
    }
}

private extension ShotMatch.Result {
    nonisolated var isSame: Bool { if case .same = self { true } else { false } }
}
