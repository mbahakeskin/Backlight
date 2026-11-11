#if AGENT
import AppKit
import WebKit

// Touch for a tab, for an agent trying a page the way a phone shows it (`resize` with `touch`, and the
// mobile and tablet presets).
//
// WebKit on a Mac has no touch events: no `TouchEvent`, `Touch` or `TouchList`, `maxTouchPoints` is 0 and a page's
// `ontouchstart` property doesn't exist (its iOS-only mouse-event policy has nothing to deliver them with). So a
// script in the page's own world, at the start of each document and in its frames, makes them:
//   - the classes, `ontouch*` as properties (and as attributes, `<div ontouchstart="…">`), `document.createTouch`,
//     and `navigator.maxTouchPoints` 5, so what a page asks to know whether it is on a touch screen says yes;
//   - the real mouse events the agent's clicks and drags are made of (a press, moves while it lasts, a release: only
//     those that came from the system, `isTrusted`) are also sent as `touchstart`, `touchmove` and `touchend` on the
//     element they began on, before the page sees the mouse's own (a phone sends those after a tap too);
//   - the pointer events the mouse makes are sent again as `pointerType: "touch"` (many libraries listen to those
//     before touch events), only while pressed;
//   - `matchMedia` is told that a pointer is coarse and that nothing hovers (a style sheet's own `@media` can't be
//     told anything: WebKit has no way to change it).
// What it can't be: there is one finger, no scrolling by touch, and the events a page gets are a script's, not the
// system's (`isTrusted` is false on them).
enum TouchEmulation {
    /// The tab's touch, on or off, in the page it shows and in those it goes to. A page that is up takes it at once
    /// (its frames that are up already, after a reload).
    static func set(_ on: Bool, for tab: Tab) {
        guard tab.touch != on else { return }
        tab.touch = on
        if let web = tab.webView { apply(to: tab, web) }
    }

    /// Put on a web view when it is made, and when the setting changes.
    static func apply(to tab: Tab, _ web: WKWebView) {
        let controller = web.configuration.userContentController
        if let old = tab.touchScript {
            let remove = NSSelectorFromString("_removeUserScript:")
            if controller.responds(to: remove) { _ = controller.perform(remove, with: old) }
            tab.touchScript = nil
        }
        if tab.touch {
            let script = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
            controller.addUserScript(script)
            tab.touchScript = script
            web.evaluateJavaScript(source, in: nil, in: .page) { _ in }
        } else {
            web.evaluateJavaScript("window.__backlightTouch && window.__backlightTouch.off()", in: nil, in: .page) { _ in }
        }
    }

    static let source = #"""
    (() => {
      if (window.__backlightTouch) return;
      const types = ["touchstart", "touchmove", "touchend", "touchcancel"];
      const watched = types.map((type) => "on" + type);
      const saved = [];
      const listeners = [];
      const define = (object, name, descriptor) => {
        saved.push([object, name, Object.getOwnPropertyDescriptor(object, name)]);
        Object.defineProperty(object, name, Object.assign({ configurable: true }, descriptor));
      };

      class Touch {
        constructor(init) {
          const x = init.clientX || 0, y = init.clientY || 0;
          const value = (v) => ({ value: v, enumerable: true });
          Object.defineProperties(this, {
            identifier: value(init.identifier | 0), target: value(init.target), clientX: value(x), clientY: value(y),
            pageX: value(init.pageX !== undefined ? init.pageX : x + scrollX), pageY: value(init.pageY !== undefined ? init.pageY : y + scrollY),
            screenX: value(init.screenX !== undefined ? init.screenX : x), screenY: value(init.screenY !== undefined ? init.screenY : y),
            radiusX: value(init.radiusX || 1), radiusY: value(init.radiusY || 1), rotationAngle: value(init.rotationAngle || 0),
            force: value(init.force === undefined ? 1 : init.force),
          });
        }
      }
      class TouchList {
        constructor(list) {
          list = list || [];
          list.forEach((touch, i) => Object.defineProperty(this, i, { value: touch, enumerable: true }));
          Object.defineProperty(this, "length", { value: list.length });
        }
        item(i) { return this[i] || null; }
        identifiedTouch(id) { for (let i = 0; i < this.length; i++) if (this[i].identifier === id) return this[i]; return null; }
        [Symbol.iterator]() { return Array.prototype[Symbol.iterator].call(this); }
      }
      class TouchEvent extends UIEvent {
        constructor(type, init) {
          init = init || {};
          super(type, init);
          Object.defineProperties(this, {
            touches: { value: new TouchList(init.touches) }, targetTouches: { value: new TouchList(init.targetTouches) },
            changedTouches: { value: new TouchList(init.changedTouches) },
            altKey: { value: !!init.altKey }, ctrlKey: { value: !!init.ctrlKey }, metaKey: { value: !!init.metaKey }, shiftKey: { value: !!init.shiftKey },
          });
        }
      }
      define(window, "Touch", { value: Touch, writable: true });
      define(window, "TouchList", { value: TouchList, writable: true });
      define(window, "TouchEvent", { value: TouchEvent, writable: true });
      define(Navigator.prototype, "maxTouchPoints", { get: () => 5 });
      define(Document.prototype, "createTouch", { writable: true, value(view, target, id, pageX, pageY, screenX, screenY) {
        return new Touch({ identifier: id, target, pageX, pageY, screenX, screenY, clientX: pageX - scrollX, clientY: pageY - scrollY });
      } });
      define(Document.prototype, "createTouchList", { writable: true, value(...touches) { return new TouchList(touches); } });

      // ontouchstart and the others, as properties that take a function, wherever onclick is.
      const property = new WeakMap();
      for (const type of types) {
        const accessor = {
          enumerable: true,
          get() { const set = property.get(this); return (set && set[type]) || null; },
          set(fn) {
            let set = property.get(this); if (!set) property.set(this, (set = {}));
            if (set[type]) this.removeEventListener(type, set[type]);
            set[type] = typeof fn === "function" ? fn : null;
            if (set[type]) this.addEventListener(type, set[type]);
          },
        };
        for (const holder of [HTMLElement.prototype, SVGElement.prototype, Document.prototype, window]) define(holder, "on" + type, accessor);
      }

      // The same as attributes: <div ontouchstart="…">. With these classes in place WebKit makes a handler of it itself
      // (measured: a second one made here fired twice), so one is made here only if a probe says it doesn't.
      let nativeAttributes = false;
      try {
        const probe = document.createElement("div");
        probe.setAttribute("ontouchstart", "this.__backlightProbe = true");
        probe.dispatchEvent(new TouchEvent("touchstart"));
        nativeAttributes = !!probe.__backlightProbe;
      } catch (e) {}
      const attributed = new Set();
      const sync = (element) => {
        const kept = attributed.has(element) ? element.__backlightTouchHandlers : null;
        if (kept) for (const type of types) if (kept[type]) element.removeEventListener(type, kept[type]);
        const made = {};
        for (const type of types) {
          const code = element.getAttribute("on" + type);
          if (!code) continue;
          let fn;
          try { fn = new Function("event", code); } catch (e) { continue; }
          made[type] = function (event) { return fn.call(this, event); };
          element.addEventListener(type, made[type]);
        }
        element.__backlightTouchHandlers = made;
        attributed.add(element);
      };
      const selector = watched.map((name) => "[" + name + "]").join(",");
      const scan = (root) => {
        if (root.nodeType !== 1 && root.nodeType !== 9) return;
        if (root.nodeType === 1 && root.matches(selector)) sync(root);
        for (const element of root.querySelectorAll(selector)) sync(element);
      };
      const observer = new MutationObserver((records) => {
        for (const record of records) {
          if (record.type === "attributes") sync(record.target);
          else for (const node of record.addedNodes) scan(node);
        }
      });
      if (!nativeAttributes) {
        observer.observe(document, { subtree: true, childList: true, attributes: true, attributeFilter: watched });
        scan(document);
      }

      // A pointer that is coarse and nothing that hovers, for what a script asks.
      const original = window.matchMedia;
      const rewrite = (query) => String(query)
        .replace(/\(\s*(?:any-)?pointer\s*:\s*coarse\s*\)/gi, "(min-width: 0px)").replace(/\(\s*(?:any-)?pointer\s*:\s*fine\s*\)/gi, "(min-width: 1000000px)")
        .replace(/\(\s*(?:any-)?hover\s*:\s*none\s*\)/gi, "(min-width: 0px)").replace(/\(\s*(?:any-)?hover\s*:\s*hover\s*\)/gi, "(min-width: 1000000px)");
      define(window, "matchMedia", { writable: true, value: function matchMedia(query) {
        const list = original.call(window, rewrite(query));
        return new Proxy(list, { get(target, key) {
          if (key === "media") return String(query);
          const member = Reflect.get(target, key, target);
          return typeof member === "function" ? member.bind(target) : member;
        } });
      } });

      // The pointer is the finger: pressed, moved while it is, let go. Only what came from the system.
      let finger = null;
      const fire = (type, target, event) => {
        const touch = new Touch({ identifier: 1, target, clientX: event.clientX, clientY: event.clientY, screenX: event.screenX, screenY: event.screenY });
        const live = type === "touchend" || type === "touchcancel" ? [] : [touch];
        target.dispatchEvent(new TouchEvent(type, { bubbles: true, cancelable: true, composed: true, view: window, touches: live, targetTouches: live,
          changedTouches: [touch], altKey: event.altKey, ctrlKey: event.ctrlKey, metaKey: event.metaKey, shiftKey: event.shiftKey }));
      };
      const listen = (type, fn) => { window.addEventListener(type, fn, true); listeners.push([type, fn]); };
      listen("mousedown", (e) => { if (e.button !== 0 || !e.isTrusted) return; finger = e.target; fire("touchstart", finger, e); });
      // The agent's drags have no button down in what the page is told, so the press is kept here.
      listen("mousemove", (e) => { if (finger && e.isTrusted) fire("touchmove", finger, e); });
      listen("mouseup", (e) => { if (!finger || !e.isTrusted) return; const target = finger; finger = null; fire("touchend", target, e); });

      // Pointer events, which many libraries use before touch events: what the mouse makes is taken and sent again as a
      // touch pointer (pointerType "touch", only while pressed, no hovering), as a screen would. Its id is the mouse's, so
      // setPointerCapture on it still finds a pointer that is down.
      let pressed = null;
      const pointer = (type, target, event, buttons) => target.dispatchEvent(new PointerEvent(type, { bubbles: true, cancelable: true, composed: true, view: window,
        pointerId: 1, pointerType: "touch", isPrimary: true, width: 1, height: 1, pressure: buttons ? 0.5 : 0, button: type === "pointermove" ? -1 : 0, buttons,
        clientX: event.clientX, clientY: event.clientY, screenX: event.screenX, screenY: event.screenY,
        altKey: event.altKey, ctrlKey: event.ctrlKey, metaKey: event.metaKey, shiftKey: event.shiftKey }));
      if (typeof PointerEvent === "function") {
        listen("pointerdown", (e) => { if (!e.isTrusted || e.pointerType !== "mouse" || e.button !== 0) return; e.stopImmediatePropagation(); pressed = e.target; pointer("pointerdown", pressed, e, 1); });
        listen("pointermove", (e) => { if (!e.isTrusted || e.pointerType !== "mouse") return; e.stopImmediatePropagation(); if (pressed) pointer("pointermove", pressed, e, 1); });
        listen("pointerup", (e) => { if (!e.isTrusted || e.pointerType !== "mouse" || !pressed) return; e.stopImmediatePropagation(); const target = pressed; pressed = null; pointer("pointerup", target, e, 0); });
      }

      window.__backlightTouch = { off() {
        for (const [type, fn] of listeners) window.removeEventListener(type, fn, true);
        observer.disconnect();
        for (const element of attributed) { const made = element.__backlightTouchHandlers || {}; for (const type of types) if (made[type]) element.removeEventListener(type, made[type]); delete element.__backlightTouchHandlers; }
        for (const [object, name, descriptor] of saved.reverse()) { if (descriptor) Object.defineProperty(object, name, descriptor); else delete object[name]; }
        delete window.__backlightTouch;
      } };
    })();
    """#
}
#endif
