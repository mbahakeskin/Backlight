#if AGENT
import AppKit
import Observation
import WebKit

// How the agent's tools know that what a click or a key started is over (see Call.effectsOver).
//
// Three ways, chosen in Settings › Agents, or by the agent with `settle`:
//   tracker   (the default) a small script in the page's own world, wrapping its timers, frames and requests (AgentPage.tracker);
//   inspector nothing in the page: a hidden Web Inspector is connected to it, and what WebKit's own instruments say (timers
//             set and fired, frames asked for, requests, layout and paint) is read from the inspector's page, which is
//             Backlight's own. It costs a web process for the inspector's page, about 130 MB for each tab worked in,
//             and 0.2 s when a tab is first worked in; the connection is closed a few seconds after the last action and
//             WebKit gives the process back within a minute;
//   window    the oldest: 150 ms without a change.
//
// The inspector's frontend is a page of WebKit's (`inspector-resource:///Main.html`) with `WI`, its model, in it. A hook on
// the connection its targets talk through (`dispatch`) takes the Timeline and Network messages before the frontend does,
// keeps what the decision needs (pending timers up to the cap, frames, requests) and tells Backlight only when it has
// decided; the frontend itself is left recording nothing. The debugger is switched off, so that a page's own `debugger;`
// statement stops nothing. The page can tell it is being inspected, as it can with Safari's inspector open.

enum QuietMode: String, CaseIterable, Identifiable {
    case tracker, inspector, window
    var id: String { rawValue }

    var title: String {
        switch self {
        case .tracker: "A script in the page"
        case .inspector: "The Web Inspector"
        case .window: "A pause of 150 ms"
        }
    }
}

@Observable
final class AgentQuiet {
    static let shared = AgentQuiet()
    static let key = "agent.quietMode"

    /// What is in use: the person's choice, or an agent's, which lasts until Backlight quits.
    private(set) var mode: QuietMode
    /// An agent chose it, and it is not kept.
    private(set) var byAgent = false

    private init() {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: AgentQuiet.key), let stored = QuietMode(rawValue: raw) {
            mode = stored
        } else {
            // Before this setting there was a switch for the script alone.
            mode = defaults.object(forKey: "agent.quietTracker") as? Bool == false ? .window : .tracker
        }
    }

    /// The person's choice: kept.
    func choose(_ mode: QuietMode) {
        self.mode = mode
        byAgent = false
        UserDefaults.standard.set(mode.rawValue, forKey: AgentQuiet.key)
    }

    /// An agent's: until Backlight quits, or the person chooses.
    func set(byAgent mode: QuietMode) {
        self.mode = mode
        byAgent = true
    }
}

/// One tab's connected inspector.
@MainActor
final class InspectorWatch: NSObject, WKScriptMessageHandler {
    private static var watches: [UUID: InspectorWatch] = [:]

    /// The tab's, if it has one for the page it shows now.
    static func existing(_ tab: Tab) -> InspectorWatch? {
        guard let watch = watches[tab.id] else { return nil }
        guard watch.web === tab.webView else {
            watch.detach()
            return nil
        }
        return watch
    }

    /// Connects an inspector to the tab's page, if there isn't one, and says it is ready. Nil where it can't be done
    /// (the person has the inspector open, WebKit has none) and the script is used instead.
    static func attach(to tab: Tab, _ web: WKWebView) async -> InspectorWatch? {
        if let watch = existing(tab) {
            watch.touch()
            return watch
        }
        let connect = NSSelectorFromString("connect")
        guard web.responds(to: NSSelectorFromString("_inspector")), let inspector = web.value(forKey: "_inspector") as? NSObject,
              inspector.responds(to: connect), inspector.value(forKey: "isConnected") as? Bool != true else { return nil }
        let watch = InspectorWatch(tab: tab, web: web, inspector: inspector)
        watches[tab.id] = watch
        inspector.perform(connect)
        guard await watch.prepare() else {
            watch.detach()
            return nil
        }
        watch.touch()
        return watch
    }

    private let tabID: UUID
    fileprivate weak var web: WKWebView?
    private let inspector: NSObject
    private var frontend: WKWebView?
    private var decided = 0
    private var serial = 0
    private let decision = Waiters()
    private var lease: Task<Void, Never>?
    private var loading: NSKeyValueObservation?

    private init(tab: Tab, web: WKWebView, inspector: NSObject) {
        tabID = tab.id
        self.web = web
        self.inspector = inspector
    }

    /// The frontend loaded, its model up, the hook in and the Timeline recording.
    private func prepare() async -> Bool {
        guard let page = inspector.value(forKey: "inspectorWebView") as? WKWebView else { return false }
        frontend = page
        // Its page has loaded when it says so; that its model has its targets, nothing says, so that is asked inside it
        // (once, for a tenth of a second), with a watchdog for the frontend that never gets there.
        if page.isLoading || page.url == nil {
            let loaded = Waiters()
            loading = page.observe(\.isLoading, options: [.new]) { page, _ in
                MainActor.assumeIsolated { if !page.isLoading, page.url != nil { loaded.wake() } }
            }
            // The watchdog is for a frontend that never loads.
            await loaded.wait(atMost: 4)
            loading = nil
        }
        page.configuration.userContentController.add(self, name: "bsQuiet")
        return await runHook()
    }

    /// The hook, run in the inspector's page. A page that is being loaded again (a connection made after one was closed:
    /// its old page is there until the new one replaces it) loses the call or has no model yet, so it is tried again for
    /// a few seconds before giving up.
    private func runHook() async -> Bool {
        guard let page = frontend else { return false }
        var result: Any?
        for attempt in 0..<30 {
            result = try? await InspectorWatch.within(3) { try await page.callAsyncJavaScript(InspectorWatch.hook, arguments: [:], in: nil, contentWorld: .page) as? String }
            if result as? String == "ready" { break }
            if attempt < 29 { try? await Task.sleep(for: .milliseconds(100)) }
        }
        Debug.log("agent", "inspector for the tab: \(String(describing: result))")
        return result as? String == "ready"
    }

    /// The Web Inspector's own page, run in it. `WI` is its model; the hook sits on the connection its targets use.
    private static let hook = #"""
    const ready = () => !!(window.WI && WI.targets && WI.targets.length && (WI.pageTarget || WI.mainTarget));
    // A tenth of a second at most in practice; the frontend's page is Backlight's own and idle meanwhile.
    for (let i = 0; i < 400 && !ready(); i++) await new Promise((r) => setTimeout(r, 10));
    if (!ready()) return "no model";
    if (window.__bsQuiet) return "ready";
    const post = (m) => { try { webkit.messageHandlers.bsQuiet.postMessage(m); } catch (e) {} };
    const target = WI.pageTarget || WI.mainTarget;
    const protos = new Set();
    for (const t of WI.targets) {
      let p = Object.getPrototypeOf(t.connection);
      while (p && p !== Object.prototype) { if (Object.prototype.hasOwnProperty.call(p, "dispatch")) { protos.add(p); break; } p = Object.getPrototypeOf(p); }
    }
    if (!protos.size) return "no connection";
    const S = { timers: new Map(), rafs: new Set(), net: new Map(), bgTimers: new Set(), bgRafs: new Set(), bgNet: new Set(),
                last: Date.now(), clearAt: 0, probing: false, want: null, wake: null };
    const now = () => Date.now();
    const WORK = new Set(["EvaluateScript", "FunctionCall", "TimerFire", "FireAnimationFrame", "EventDispatch", "ObserverCallback",
                          "Layout", "Paint", "RecalculateStyles", "Composite"]);
    const NETMAX = 400;
    // A reaction's own work moves `last`; the page's background (a repeating timer, what was going on before the action,
    // and what those start) does not.
    const note = (rec, background) => {
      const d = rec.data || {};
      const id = d.timerId !== undefined ? d.timerId : d.id;
      switch (rec.type) {
        case "TimerInstall": S.timers.set(id, { delay: d.timeout, once: !!d.singleShot }); if (background) S.bgTimers.add(id); break;
        case "TimerRemove": S.timers.delete(id); break;
        case "TimerFire": { const t = S.timers.get(id); if (t && t.once) S.timers.delete(id); break; }
        case "RequestAnimationFrame": S.rafs.add(id); if (background) S.bgRafs.add(id); break;
        case "FireAnimationFrame": case "CancelAnimationFrame": S.rafs.delete(id); break;
      }
      if (!background && WORK.has(rec.type)) S.last = now();
      for (const c of rec.children || []) note(c, background);
    };
    const isBackground = (rec) => {
      const d = rec.data || {};
      if (rec.type === "TimerFire") { const t = S.timers.get(d.timerId); return !t || !t.once || S.bgTimers.has(d.timerId); }
      if (rec.type === "FireAnimationFrame") return S.bgRafs.has(d.id);
      return false;
    };
    const waiting = (cap) => {
      let n = 0;
      for (const [id, t] of S.timers) if (t.once && t.delay <= cap && !S.bgTimers.has(id)) n++;
      for (const id of S.rafs) if (!S.bgRafs.has(id)) n++;
      const t = now();
      for (const [id, at] of S.net) if (!S.bgNet.has(id) && t - at < NETMAX) n++;
      return n;
    };
    // A CSS transition or animation sets no timer and no request, and a covered window paints nothing to see it by: the
    // page is asked, as the inspector's console would, whether a finite animation is running. That reads and writes nothing.
    const animating = async () => {
      try {
        const r = await target.RuntimeAgent.evaluate.invoke({
          expression: "document.getAnimations().some((a) => { const t = a.effect && a.effect.getComputedTiming(); return a.playState === 'running' && t && isFinite(t.endTime); })",
          returnByValue: true, doNotPauseOnExceptionsAndMuteConsole: true, objectGroup: "bsQuiet" });
        return !!(r && r.result && r.result.value);
      } catch (e) { return false; }
    };
    const check = () => {
      const w = S.want;
      if (!w) return;
      const t = now();
      let why = null;
      if (t - w.started >= w.cap) why = "cap";
      else if (waiting(w.cap) === 0 && t - S.last >= w.settle) {
        if (S.clearAt >= S.last) why = "idle";
        else if (!S.probing) {
          S.probing = true;
          animating().then((running) => { S.probing = false; if (running) S.last = now(); else S.clearAt = now(); check(); });
        }
      }
      if (why) { S.want = null; post({ k: "quiet", id: w.id, why, ms: t - w.started }); return; }
      clearTimeout(S.wake);
      S.wake = setTimeout(check, 10);
    };
    // A network limit (`throttle`). The inspector's interception holds each request and each response until it is told to
    // go on, and they are let go after what the connection would have taken: half the delay on each way, and a response its
    // length over the speed, as one link shared by all (each waits for those before it). A response whose length isn't
    // said (a stream, a chunked page) is held by the delay alone. Offline fails every request.
    const TH = { on: false, enabled: false, ours: false, down: 0, latency: 0, offline: false, free: 0 };
    const header = (headers, name) => {
      if (!headers) return null;
      for (const key of Object.keys(headers)) if (key.toLowerCase() === name) return headers[key];
      return null;
    };
    const intercepted = (o) => {
      const stage = o.method === "Network.requestIntercepted" ? "request" : "response";
      const requestId = o.params.requestId;
      const release = () => { target.NetworkAgent.interceptContinue.invoke({ requestId, stage }).catch(() => {}); };
      // A long wait is kept by Backlight's own clock (a hidden page's timers can't be counted on for seconds), which
      // calls __bsRelease when it is over.
      const after = (ms) => { if (ms <= 1) release(); else if (ms < 400) setTimeout(release, ms); else post({ k: "hold", requestId, stage, ms }); };
      if (stage === "request") {
        if (TH.offline) { target.NetworkAgent.interceptRequestWithError.invoke({ requestId, errorType: "General" }).catch(() => {}); return; }
        return after(TH.latency / 2);
      }
      let wait = TH.latency / 2;
      const length = parseInt(header(o.params.response && o.params.response.headers, "content-length"), 10);
      if (TH.down > 0 && length > 0) {
        const start = Math.max(Date.now() + wait, TH.free);
        TH.free = start + length / TH.down * 1000;
        wait = TH.free - Date.now();
      }
      after(wait);
    };
    window.__bsRelease = (requestId, stage) => { target.NetworkAgent.interceptContinue.invoke({ requestId, stage }).catch(() => {}); return true; };
    window.__bsThrottle = async (down, latency, offline) => {
      TH.down = down; TH.latency = latency; TH.offline = offline;
      const on = down > 0 || latency > 0 || offline;
      if (on && !TH.enabled) {
        TH.on = true; TH.free = 0;
        // The inspector's own page may have switched interception on already; then it is its to switch off.
        TH.ours = true;
        try { await target.NetworkAgent.setInterceptionEnabled.invoke({ enabled: true }); } catch (e) { TH.ours = false; }
        for (const stage of ["request", "response"]) await target.NetworkAgent.addInterception.invoke({ url: ".*", stage, isRegex: true });
        TH.enabled = true;
      } else if (!on && TH.enabled) {
        TH.on = false; TH.enabled = false;
        for (const stage of ["request", "response"]) await target.NetworkAgent.removeInterception.invoke({ url: ".*", stage, isRegex: true }).catch(() => {});
        if (TH.ours) await target.NetworkAgent.setInterceptionEnabled.invoke({ enabled: false }).catch(() => {});
      }
      return "ok";
    };
    for (const p of protos) {
      const orig = p.dispatch;
      p.dispatch = function (message) {
        const o = typeof message === "string" ? JSON.parse(message) : message;
        const method = o && o.method;
        if (TH.on && (method === "Network.requestIntercepted" || method === "Network.responseIntercepted")) { intercepted(o); return; }
        if (method && method.startsWith("Timeline.")) {
          if (method === "Timeline.eventRecorded") { note(o.params.record, isBackground(o.params.record)); check(); }
          return;
        }
        if (method === "Network.requestWillBeSent") { S.net.set(o.params.requestId, now()); S.last = now(); }
        else if (method === "Network.loadingFinished" || method === "Network.loadingFailed") { S.net.delete(o.params.requestId); S.last = now(); check(); }
        else if (method === "Page.frameNavigated" && !o.params.frame.parentId) {
          S.timers.clear(); S.rafs.clear(); S.net.clear(); S.bgTimers.clear(); S.bgRafs.clear(); S.bgNet.clear(); S.last = now();
        }
        return orig.call(this, message);
      };
    }
    // Before an action: what is going on now is the page's background.
    window.__bsBegin = () => {
      S.bgTimers = new Set(S.timers.keys()); S.bgRafs = new Set(S.rafs); S.bgNet = new Set(S.net.keys());
      S.last = now(); S.want = null; return true;
    };
    window.__bsSettle = (id, settle, cap) => { S.want = { id, settle, cap, started: now() }; check(); return true; };
    await target.TimelineAgent.setInstruments(["Timeline"]);
    await target.TimelineAgent.start(0);
    // A `debugger;` statement in the page stops nothing.
    await target.DebuggerAgent.disable();
    window.__bsQuiet = true;
    return "ready";
    """#

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: Any], body["k"] as? String == "hold", let requestId = body["requestId"] as? String,
           let stage = body["stage"] as? String, let ms = (body["ms"] as? NSNumber)?.doubleValue {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(ms))
                _ = try? await self?.frontend?.callAsyncJavaScript("return window.__bsRelease(requestId, stage);", arguments: ["requestId": requestId, "stage": stage],
                                                                   in: nil, contentWorld: .page)
            }
            return
        }
        guard let body = message.body as? [String: Any], body["k"] as? String == "quiet", let id = body["id"] as? Int else { return }
        decided = max(decided, id)
        decision.wake()
    }

    /// Before an action: what is going on in the page now is its background.
    func begin() async {
        touch()
        _ = try? await frontend?.callAsyncJavaScript("return window.__bsBegin();", arguments: [:], in: nil, contentWorld: .page)
    }

    /// Until nothing the action started is pending (a timer up to the cap, a frame, a request) and nothing has
    /// been done for `margin` ms, or `cap` ms have passed. False when the inspector could not be asked.
    func settled(cap: Int, margin: Int) async -> Bool {
        guard let frontend else { return false }
        touch()
        serial += 1
        let id = serial
        let asked = try? await frontend.callAsyncJavaScript("return window.__bsSettle(id, margin, cap);",
                                                            arguments: ["id": id, "margin": max(margin, 40), "cap": cap], in: nil, contentWorld: .page)
        guard asked != nil else { return false }
        // The decision may have come while it was being asked for.
        if decided < id { await decision.wait(atMost: Double(cap) / 1000 + 0.4) }
        return true
    }

    /// A network limit on the tab's page: bytes a second towards it (0: none), delay added to a round trip in milliseconds,
    /// offline or not. It lives in the inspector's connection and ends with it, so while one is on, the connection is
    /// kept (the memory above is what it costs).
    struct Limits: Equatable {
        var down = 0
        var latency = 0
        var offline = false
        var isOn: Bool { down > 0 || latency > 0 || offline }
    }
    private(set) var limits = Limits()

    /// Puts the limits on what the page asks for from now on, or lifts them when none is on. Nil when done, else why not.
    func limit(_ new: Limits) async -> String? {
        var failure = "The inspector is not connected."
        // A connection made after one was closed has its page loaded again after the first answer: the call may be lost, or
        // the hook gone. Asked again, with the hook put back if it isn't there, for a few seconds.
        for attempt in 0..<8 {
            guard let frontend else { return failure }
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(300)) }
            do {
                let there = try await InspectorWatch.within(3) {
                    try await frontend.callAsyncJavaScript("return typeof window.__bsThrottle;", arguments: [:], in: nil, contentWorld: .page) as? String
                }
                if there != "function", !(await runHook()) { failure = "The inspector's page didn't come up."; continue }
                let answer = try await InspectorWatch.within(5) {
                    try await frontend.callAsyncJavaScript("return await window.__bsThrottle(down, latency, offline);",
                                                           arguments: ["down": new.down, "latency": new.latency, "offline": new.offline],
                                                           in: nil, contentWorld: .page) as? String
                }
                guard answer == "ok" else { failure = "The inspector did not take the limit."; continue }
                limits = new
                touch()
                return nil
            } catch {
                let said = ((error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String) ?? error.localizedDescription
                failure = "The inspector refused: \(said)"
            }
        }
        touch()
        return failure
    }

    private struct TimedOut: Error {}

    private nonisolated final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        /// True the first time.
        func first() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }

    /// A call into the inspector's page, given up on after `seconds`: one made while the page is being loaded again is
    /// sometimes never answered.
    private static func within<T: Sendable>(_ seconds: Double, _ work: @escaping @MainActor @Sendable () async throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
            let once = Once()
            Task { @MainActor in
                do {
                    let value = try await work()
                    if once.first() { continuation.resume(returning: value) }
                } catch {
                    if once.first() { continuation.resume(throwing: error) }
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                if once.first() { continuation.resume(throwing: TimedOut()) }
            }
        }
    }

    /// The agent lets a tab go: its limit goes, and the connection with it.
    static func lift(_ tab: Tab) {
        guard let watch = watches[tab.id], watch.limits.isOn else { return }
        Task { _ = await watch.limit(Limits()) }
    }

    /// The agent is gone: no limit stays on any tab.
    static func liftAll() {
        for watch in watches.values where watch.limits.isOn { Task { _ = await watch.limit(Limits()) } }
    }

    /// The connection is kept for a few seconds after the last use, then closed (WebKit gives the inspector's process back
    /// within a minute): a lease on memory, not a wait for anything. Not while a limit is on.
    private func touch() {
        lease?.cancel()
        lease = nil
        guard !limits.isOn else { return }
        lease = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.detach()
        }
    }

    func detach() {
        lease?.cancel()
        lease = nil
        limits = Limits()
        frontend?.configuration.userContentController.removeScriptMessageHandler(forName: "bsQuiet")
        frontend = nil
        inspector.perform(NSSelectorFromString("close"))
        InspectorWatch.watches[tabID] = nil
        decision.wake()
    }
}
#endif
