#!/usr/bin/env python3
"""Builds the single-file site: site/index.html from site/src/*.

    python3 site/build.py            # writes site/index.html
    FONT=/path/to/latin.woff2 python3 site/build.py

The font (Google Sans Flex, SIL Open Font License, the latin subset with the
width, weight and roundness axes) is embedded as base64, so the file works
offline and nothing is fetched when it is opened."""
import base64, html, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "src")
NAME = "Backlight"   # one place to change the name
VERSION = "0.9.10"
SIZE = "2.2 MB"      # the release zip

def esc(s): return html.escape(s, quote=False)

# ---- Highlights (the long list is FEATURES.md in the repository) ----------
HIGHLIGHTS = [
 ("The page takes the whole window", "Tabs in a sidebar, the address in a top bar. Both slide in at their edge, and either can stay pinned."),
 ("Tabs, groups, profiles, split view", "Profiles keep their own sign-ins. Tabs off screen are frozen, and unloaded after a while."),
 ("Reader, dark pages, Peek", "Just the article; dark colours for white pages; a link's page in a panel over the one you are reading."),
 ("Picture in picture, downloads", "A video in its own window. Downloads you can pause, and a button for photos and videos on the sites you list."),
 ("Private by build", "No telemetry, no account. Ads and trackers blocked by uBlock Origin Lite, tracking parameters cut from links."),
 ("Chrome extensions", "From the Chrome Web Store, a folder or a Safari app. Bitwarden works, Touch ID included."),
 ("Translate on this Mac", "The system's own translation, text by text in the page, and back with one press."),
 ("For developers", "Develop and Debug menus as in Safari, any user agent or size, settings kept per site."),
]

def highlights_html():
    return "\n".join(f'        <div class="hl"><h3>{esc(h)}</h3><p>{esc(p)}</p></div>' for h, p in HIGHLIGHTS)

# ---- FAQ ------------------------------------------------------------------
FAQ = [
 ("Why WebKit and not Chromium?", "WebKit already ships with every Mac and macOS keeps it up to date, so the browser can be a few megabytes of Swift. A few pages built only for Chrome will misbehave, as they do in Safari."),
 ("Does it run Chrome extensions?", "Many. WebKit's extension engine loads them from the Chrome Web Store, a folder or a Safari app, and one set serves every profile. An extension that needs Chrome's debugger won't work."),
 ("Does it support passkeys?", "Not yet. Apple grants browsers that entitlement on request, tied to a paid Developer ID. Password managers that work as extensions, such as Bitwarden, do work."),
 ("What does it send, and to whom?", "Only the pages you open and a daily check for a newer version, which Settings turns off. What an agent reads, when you let it, goes to that agent."),
 ("Why does the download button start with an empty list?", "A button over every picture on every site gets in the way. You add the sites you want it on, in Settings."),
 ("Why Backlight?", "A backlight is the light behind a screen. The page is lit, and the tabs and address stay out of the way until you reach for them. It was called @@OLD@@ until 0.9.0."),
]
def faq_html():
    out = []
    for q, a in FAQ:
        out.append(f'        <details><summary>{esc(q)}</summary><div class="a"><div><p>{esc(a)}</p></div></div></details>')
    return "\n".join(out)

# ---- Numbers (filled from measure/results.json when it exists) ------------
import json
RES = {"cpu_visible": 72.2, "cpu_hidden_frozen": 0.9, "cpu_hidden_unfrozen": 2.5, "first_window_ms": 74}
rp = os.path.join(HERE, "src", "results.json")
if os.path.exists(rp): RES.update(json.load(open(rp)))

def cpu_html():
    rows = [("Shown", RES["cpu_visible"], False), ("Hidden", RES["cpu_hidden_unfrozen"], False), ("Hidden, frozen", RES["cpu_hidden_frozen"], True)]
    top = max(r[1] for r in rows)
    out = []
    for name, v, me in rows:
        w = max(0.4, v / top * 100)
        out.append(f'            <div class="bar-row{" me" if me else ""}"><span class="name">{name}</span><div class="bar-track" style="--w:{w:.1f}"><span class="bar-fill"></span><span class="bar-val{" in-bar" if w > 75 else ""}">{v:.1f}%</span></div></div>')
    return "\n".join(out)

def ram_html():
    mp = os.path.join(HERE, "src", "memory.json")
    if not os.path.exists(mp): return ""
    m = json.load(open(mp))
    def bar(name, mb, note, me, top):
        w = max(.5, mb / top * 100)
        cls = "bar-row me" if me else "bar-row"
        inb = " in-bar" if w > 75 else ""
        return ('            <div class="%s"><span class="name">%s</span><div class="bar-track" style="--w:%.1f"><span class="bar-fill"></span>'
                '<span class="bar-val%s">%s MB<small> &middot; %s</small></span></div></div>') % (cls, name, w, inb, format(round(mb), ","), note)
    def block(title, sub, rows):
        top = max(r[1] for r in rows)
        body = "\n".join(bar(n, mb, note, me, top) for n, mb, note, me in rows)
        return ('        <div class="bar-block reveal" data-bars>\n          <h3>%s<small>%s</small></h3>\n          <div class="bar-list">\n%s\n          </div>\n        </div>' % (title, sub, body))
    out = []
    e = m["empty"]
    out.append(block("Memory with one empty window", "The app and its helper processes, 25 seconds after it opens.",
        [("Chrome", e["Chrome"]["mb"], "%d processes" % e["Chrome"]["procs"], False), ("BasicShell", e["BasicShell"]["mb"], "%d processes" % e["BasicShell"]["procs"], True)]))
    f = m["five"]
    LABEL = {"BasicShell": ("BasicShell", "uBlock Origin Lite"), "BasicShell, blocker off": ("BasicShell", "no blocker"),
             "BasicShell, tabs unloaded": ("BasicShell, unloaded", "uBlock Origin Lite"), "Chrome": ("Chrome", "no blocker"),
             "Safari": ("Safari", "no blocker"), "Search": ("Search", "its short list")}
    rows = []
    for n, v in f.items():
        nm, sub = LABEL.get(n, (n, ""))
        rows.append(('%s<small>%s</small>' % (nm, sub), v["mb"], "%d processes" % round(v["procs"]), n.startswith("BasicShell")))
    rows.sort(key=lambda r: -r[1])
    out.append(block("Memory with five pages open", "The same five pages, one shown, after a minute and a half. Chrome and Safari ran with no blocker, Search with its short built-in list, Backlight with uBlock Origin Lite's 110,000 rules (and with none in the row that says so). The unloaded row is the same pages after it unloaded the four you were not looking at, which it does after six hours or when memory runs short; here the timer was two minutes.", rows))
    s = m.get("split")
    if s:
        def seg(label, v, tot, cls): return '<span class="seg-%s" style="--w:%.2f" title="%s, %d MB"><i>%s</i></span>' % (cls, v / tot * 100, label, round(v), label)
        lines = []
        for name, d in s.items():
            tot = d["pages"] + d["shell"] + d["rest"]
            lines.append('            <div class="split-row"><span class="name">%s</span><div class="split">%s%s%s</div><span class="tot">%d MB</span></div>' % (
                name, seg("Pages", d["pages"], tot, "p"), seg("The browser itself", d["shell"], tot, "s"), seg("Graphics, network, helpers", d["rest"], tot, "r"), round(tot)))
        out.append('        <div class="bar-block reveal" data-bars>\n          <h3>Where that memory goes<small>%s</small></h3>\n          <div class="bar-list">\n%s\n            <p class="legend"><span class="k-p"></span>Pages <span class="k-s"></span>The browser itself <span class="k-r"></span>Graphics, network, helpers</p>\n          </div>\n        </div>' % (m.get("split_note", ""), "\n".join(lines)))
    return "\n".join(out)

# ---- Assemble -------------------------------------------------------------
def read(p): return open(os.path.join(SRC, p), encoding="utf-8").read()

font_path = os.environ.get("FONT") or os.path.join(SRC, "GoogleSansFlex-latin.woff2")
font_b64 = base64.b64encode(open(font_path, "rb").read()).decode()

body = read("body.html").replace("<!--HIGHLIGHTS-->", highlights_html()).replace("<!--FAQ-->", faq_html()).replace("<!--CPU-->", cpu_html()).replace("<!--RAM-->", ram_html())
css = read("site.css").replace("__FONT_LATIN__", font_b64) + "\n" + read("stage.css")
js = read("app.js")

page = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>{NAME}, a quiet web browser for Mac</title>
<meta name="description" content="A small web browser for macOS, written in Swift on WebKit. The page gets the whole window; tabs and the address wait at the edges. No telemetry, no account, a 2 MB download.">
<meta name="color-scheme" content="light dark">
<meta name="theme-color" content="#14172b">
<link rel="canonical" href="https://mbahakeskin.github.io/Backlight/">
<meta property="og:type" content="website">
<meta property="og:title" content="{NAME}, a quiet web browser for Mac">
<meta property="og:description" content="A small web browser for macOS. The page gets the whole window; tabs and the address wait at the edges.">
<meta property="og:url" content="https://mbahakeskin.github.io/Backlight/">
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 28 28'%3E%3Cdefs%3E%3ClinearGradient id='g' x1='.2' y1='0' x2='.8' y2='1'%3E%3Cstop offset='0' stop-color='%232d3568'/%3E%3Cstop offset='1' stop-color='%2312162f'/%3E%3C/linearGradient%3E%3Cmask id='m'%3E%3Crect width='28' height='28' fill='white'/%3E%3Ccircle cx='16.2' cy='14.4' r='7.1'/%3E%3C/mask%3E%3C/defs%3E%3Crect x='1' y='1' width='26' height='26' rx='8.5' fill='url(%23g)'/%3E%3Ccircle cx='12.6' cy='14' r='7.6' fill='%23ffc981' mask='url(%23m)'/%3E%3Ccircle cx='16.2' cy='14.4' r='7.1' fill='%23171b3a'/%3E%3C/svg%3E">
<style>
{css}
</style>
</head>
<body>
{body}
<script>
{js}
</script>
</body>
</html>
"""
page = page.replace("@@VERSION@@", VERSION).replace("@@SIZE@@", SIZE)
page = page.replace("BasicShell", NAME) if NAME != "BasicShell" else page
page = page.replace("@@OLD@@", "BasicShell")
# site/index.html is the copy for the server, docs/index.html the one GitHub Pages serves (Settings > Pages > main, /docs)
out = os.path.join(HERE, "index.html")
open(out, "w", encoding="utf-8").write(page)
docs = os.path.join(HERE, "..", "docs")
os.makedirs(docs, exist_ok=True)
open(os.path.join(docs, "index.html"), "w", encoding="utf-8").write(page)
print(f"{out}: {len(page)/1024:.0f} KB")
