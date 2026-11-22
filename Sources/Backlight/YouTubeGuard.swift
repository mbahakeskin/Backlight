import WebKit

// YouTube told "Chrome" (Settings › Tabs, for its Download) and the video stopping.
//
// On some accounts YouTube asks the browser to prove what it is (BotGuard's attestation, a "PO token") before it goes
// on sending a video, and gives about 45 seconds of it meanwhile; a browser that says it is Chrome but is WebKit
// underneath does not pass, and the player stops with "Something went wrong. Refresh or try again later." (issue #1,
// the stop at 0:45; the same in other clients that claim to be something they are not, VacuumTube #189: the stream's
// STREAM_PROTECTION_STATUS goes from pending to ATTESTATION_REQUIRED). The accounts are chosen by YouTube: neither
// ours nor a signed-out one was (measured: status OK under both agents, 2026-11-22).
//
// So with the switch on, a watch page's player is watched (from a world of its own, which the page and BotGuard
// can't see); when it shows that error, the tab goes back to Safari's agent, which passes, and the video loads again
// where it stopped.
@MainActor
final class YouTubeGuard: NSObject, WKScriptMessageHandler {
    static let shared = YouTubeGuard()
    static let world = WKContentWorld.world(name: "BacklightYouTube")
    static let name = "backlightYouTube"

    static func attach(to config: WKWebViewConfiguration) {
        config.userContentController.add(shared, contentWorld: world, name: name)
    }

    /// The script goes into the tab's next document while YouTube is told "Chrome" there; none otherwise.
    func arm(_ tab: Tab, for url: URL?) {
        guard WKUserContentController.canRemoveScripts, let controller = tab.webView?.configuration.userContentController else { return }
        controller.removeUserScripts(in: Self.world)
        guard let host = url?.host(), SiteDevelop.isYouTube(host), SiteDevelop.chromeAgentOn, !tab.youTubeAsSafari else { return }
        controller.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Self.world))
    }

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let seconds = (message.body as? [String: Any])?["t"] as? Double ?? 0
        MainActor.assumeIsolated {
            guard let web = message.webView, let url = web.url, let host = url.host(), SiteDevelop.isYouTube(host),
                  let tab = Windows.all.lazy.compactMap({ $0.shell.allTabs.first { $0.webView === web } }).first,
                  !tab.youTubeAsSafari, tab.userAgent == SiteDevelop.youTubeAgent
            else { return }
            Debug.log("youtube", "the player stopped at \(Int(seconds)) s under Chrome's agent: back to Safari's")
            tab.youTubeAsSafari = true
            tab.developHost = nil
            Viewport.setAgent(nil, for: tab)
            controller.removeUserScripts(in: Self.world)
            var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
            var items = (parts?.queryItems ?? []).filter { $0.name != "t" }
            if seconds >= 1 { items.append(URLQueryItem(name: "t", value: "\(Int(seconds))s")) }
            parts?.queryItems = items
            tab.load(parts?.url ?? url)
            (tab.host as? BrowserWindow)?.say("YouTube stopped the video under Chrome's name; this tab is Safari again")
        }
    }

    /// The player's error, once, with where the video was.
    private static let script = """
    (() => {
      if (window.__backlightYouTube) return;
      window.__backlightYouTube = true;
      let said = false;
      const look = () => {
        if (said || !location.pathname.startsWith('/watch')) return;
        const error = document.querySelector('#movie_player .ytp-error');
        if (!error || error.offsetParent === null) return;
        const video = document.querySelector('#movie_player video');
        said = true;
        window.webkit.messageHandlers.backlightYouTube.postMessage({ t: video ? video.currentTime : 0 });
      };
      new MutationObserver(look).observe(document.documentElement, { childList: true, subtree: true });
    })();
    """
}
