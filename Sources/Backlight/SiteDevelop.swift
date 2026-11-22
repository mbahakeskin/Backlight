import AppKit
import Observation
import WebKit

// The Develop menu's settings, kept for a site: its user agent, colour scheme,
// and whether JavaScript, images, styles and the cross-origin and local-file
// restrictions are off. Chosen with Develop › Keep These Settings for This Site,
// they are put on a tab as it goes to that site (and taken off again as it goes
// to another), and follow what is changed in the menu while the tab is there.
// Settings › Tabs lists the sites. Not for private tabs, and the window's
// size (Responsive Design) is the window's, not a site's.

struct DevelopSettings: Codable, Equatable {
    var userAgent: String?
    var look: String?
    var javaScriptOff = false
    var imagesOff = false
    var stylesOff = false
    var crossOriginOff = false
    var localFilesOff = false

    /// In words, for Settings.
    var summary: String {
        var parts: [String] = []
        if let userAgent {
            parts.append(Viewport.Agents.all.first { $0.agent == userAgent }?.title ?? "custom user agent")
        }
        if let look { parts.append(look.contains("Dark") ? "dark" : "light") }
        if javaScriptOff { parts.append("no JavaScript") }
        if imagesOff { parts.append("no images") }
        if stylesOff { parts.append("no styles") }
        if crossOriginOff { parts.append("cross-origin open") }
        if localFilesOff { parts.append("local files open") }
        return parts.isEmpty ? "nothing changed" : parts.joined(separator: ", ")
    }
}

@Observable
final class SiteDevelop {
    static let shared = SiteDevelop()
    private static let key = "site.develop"

    private(set) var sites: [String: DevelopSettings]
    /// Putting a site's settings on a tab calls the setters that would save them: not then.
    @ObservationIgnored private var applying = false

    private init() {
        sites = (UserDefaults.standard.data(forKey: Self.key)).flatMap { try? JSONDecoder().decode([String: DevelopSettings].self, from: $0) } ?? [:]
    }

    func save(_ settings: DevelopSettings?, for site: String) {
        sites[site] = settings
        if let data = try? JSONEncoder().encode(sites) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    /// Settings Backlight gives a site itself, where the person has kept none
    /// of their own for it (theirs always win, "Default" included).
    ///
    /// YouTube: its offline downloads (Premium; Music's too) are offered only
    /// to Chrome. Told "Chrome", the page's menu has Download (measured on
    /// 2026-11-12: the video's menu has "İndir" with this agent and only
    /// "Bildir" with Safari's; the file is kept by the page, in the browser,
    /// as it is in Chrome). Settings › Tabs has the switch, off unless turned
    /// on: told "Chrome", YouTube sends Chrome's player too, and videos stalled
    /// or the page stopped answering after a while (issue #1, reported by two
    /// people, not seen here). Telling only the page's script "Chrome" (navigator
    /// and userAgentData, the requests left Safari's) kept videos playing but
    /// brought no Download: YouTube puts it in the page it sends for the agent
    /// of the request (measured on a Premium account, 2026-11-22).
    static let youTubeKey = "youtube.chromeAgent"
    static let youTubeAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"

    static var chromeAgentOn: Bool { UserDefaults.standard.object(forKey: youTubeKey) as? Bool ?? false }

    /// Experimental, with "Chrome" on: YouTube's servers are told "Chrome" (they send Download with the page) and the
    /// page's script is told the truth, Safari, which is what BotGuard finds the engine to be. The stop at 0:45 comes
    /// from that check seeing "Chrome" in a WebKit page (YouTubeGuard); whether one consistent to the script is enough,
    /// with the page's own data still saying Chrome, can only be seen on an account YouTube checks: none here is.
    static let youTubeTruthKey = "youtube.chromeAgent.scriptSafari"
    static var scriptTruthOn: Bool { chromeAgentOn && UserDefaults.standard.bool(forKey: youTubeTruthKey) }

    /// What WebKit says it is in Backlight, with no agent of the tab's own.
    static var ownAgent: String { "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) \(Web.userAgentName)" }

    /// The page script's `navigator` back to the truth while the tab tells YouTube "Chrome" (youTubeTruthKey).
    @MainActor
    static func scriptTruth(_ tab: Tab, for host: String) {
        guard let web = tab.webView else { return }
        let controller = web.configuration.userContentController
        let wanted = isYouTube(host) && scriptTruthOn && tab.userAgent == youTubeAgent
        if let truth = tab.scriptTruth, !wanted || truth.controller !== controller {
            let remove = NSSelectorFromString("_removeUserScript:")
            if truth.controller.responds(to: remove) { _ = truth.controller.perform(remove, with: truth.script) }
            tab.scriptTruth = nil
        }
        guard wanted, tab.scriptTruth == nil else { return }
        let agent = ownAgent
        let source = """
        (() => {
          const agent = \(String(reflecting: agent));
          for (const [key, value] of [["userAgent", agent], ["appVersion", agent.slice("Mozilla/".length)]]) {
            try { Object.defineProperty(Navigator.prototype, key, { get: () => value, configurable: true, enumerable: true }); } catch (e) {}
          }
        })();
        """
        let script = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
        controller.addUserScript(script)
        tab.scriptTruth = (script, controller)
    }

    static func isYouTube(_ host: String) -> Bool {
        let host = host.lowercased()
        return host == "youtube.com" || host.hasSuffix(".youtube.com")
    }

    /// `tab`: one YouTube stopped under Chrome's agent stays Safari (YouTubeGuard).
    static func builtIn(_ host: String, for tab: Tab? = nil) -> DevelopSettings? {
        guard isYouTube(host), chromeAgentOn, tab?.youTubeAsSafari != true else { return nil }
        return DevelopSettings(userAgent: youTubeAgent)
    }

    /// A tab is about to go to `host` (decided on before its request is made, so the settings reach it).
    @MainActor
    func prepare(_ tab: Tab, for host: String) {
        defer { Self.scriptTruth(tab, for: host) }
        guard !tab.isPrivate, tab.developHost != host else { return }
        if let saved = sites[host] ?? Self.builtIn(host, for: tab) {
            tab.developHost = host
            apply(saved, to: tab)
        } else if tab.developHost != nil {
            // From a site that had its own settings to one that has none: plain again.
            tab.developHost = nil
            apply(DevelopSettings(), to: tab)
        }
    }

    /// Something in the Develop menu changed on this tab: the site it is on, if it has settings, keeps up.
    @MainActor
    func changed(_ tab: Tab) {
        // A site taken out of Settings' list is not put back by the tab that still follows it.
        guard !applying, let host = tab.developHost, sites[host] != nil else { return }
        save(tab.developSettings, for: host)
    }

    @MainActor
    private func apply(_ settings: DevelopSettings, to tab: Tab) {
        applying = true
        defer { applying = false }
        tab.javaScriptOff = settings.javaScriptOff
        Viewport.setAgent(settings.userAgent, for: tab)
        Viewport.setLook(settings.look.map(NSAppearance.Name.init(rawValue:)), for: tab)
        if let web = tab.webView {
            if tab.imagesOff != settings.imagesOff { Develop.setImages(!settings.imagesOff, web) }
            if tab.stylesOff != settings.stylesOff { Develop.setStyles(!settings.stylesOff, web) }
            if tab.crossOriginOff != settings.crossOriginOff { Develop.setCrossOriginRestrictions(!settings.crossOriginOff, web) }
            if tab.localFilesOff != settings.localFilesOff { Develop.setLocalFileRestrictions(!settings.localFilesOff, web) }
        }
        tab.imagesOff = settings.imagesOff
        tab.stylesOff = settings.stylesOff
        tab.crossOriginOff = settings.crossOriginOff
        tab.localFilesOff = settings.localFilesOff
    }
}

extension Tab {
    /// What the Develop menu has set on this tab.
    var developSettings: DevelopSettings {
        DevelopSettings(userAgent: userAgent, look: look?.rawValue, javaScriptOff: javaScriptOff, imagesOff: imagesOff,
                        stylesOff: stylesOff, crossOriginOff: crossOriginOff, localFilesOff: localFilesOff)
    }
}

extension BrowserWindow {
    /// Develop › Keep These Settings for This Site: what the menu has set here is kept for the site, or let go.
    @objc func toggleKeepDevelop(_ sender: Any?) {
        guard let tab = shell.selected, !tab.isPrivate, let host = tab.url?.host() else { return }
        if tab.developHost == host {
            SiteDevelop.shared.save(nil, for: host)
            tab.developHost = nil
            say("\(host) no longer keeps developer settings")
        } else {
            tab.developHost = host
            SiteDevelop.shared.save(tab.developSettings, for: host)
            say("\(host) keeps these settings")
        }
    }
}
