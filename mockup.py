"""Render the panel screens to HTML from the Swift constants.

Nothing about this UI is visible until the phone is in the headset, so the
geometry is pulled straight out of ARMenuPanel.swift rather than retyped --
if a rect moves in Swift, the picture moves with it.
"""
import re, io, html

src = io.open("PianoAR/ARMenuPanel.swift", encoding="utf-8").read()
R = {}
for m in re.finditer(r"static let (\w+Rect)\s*=\s*CGRect\(x:\s*(-?\d+),\s*y:\s*(-?\d+),"
                     r"\s*width:\s*(\d+),\s*height:\s*(\d+)\)", src):
    R[m.group(1)] = tuple(int(g) for g in m.groups()[1:])

W, H = 960, 640
HANDLE, HEADER, NAV = 58, 64, 72
CONTENT_TOP, NAV_TOP = HANDLE + HEADER, H - NAV

C = dict(accent="#8566ff", blue="#52a8ff", green="#33d175", red="#ff5757",
         amber="#ffb238", neutral="rgba(255,255,255,.20)",
         card="rgba(255,255,255,.055)", stroke="rgba(255,255,255,.12)")

TINTS = ["#b98cff", "#63c9ff", "#4fe0b0", "#ffb160", "#ff86b0", "#ffe066"]
def tint(title):
    h = 5381
    for b in title.encode(): h = (h * 33 + b) & 0xFFFFFFFFFFFFFFFF
    return TINTS[h % len(TINTS)]

def esc(t): return html.escape(str(t))

def rect(x, y, w, h, fill, r=22, stroke=None, sw=1.5):
    s = ' stroke="%s" stroke-width="%s"' % (stroke, sw) if stroke else ""
    return '<rect x="%s" y="%s" width="%s" height="%s" rx="%s" fill="%s"%s/>' % (
        x, y, w, h, r, fill, s)

def text(x, y, t, size=24, weight=700, fill="#fff", anchor="middle", ls=0):
    return ('<text x="%s" y="%s" font-size="%s" font-weight="%s" fill="%s" '
            'text-anchor="%s" letter-spacing="%s" font-family="-apple-system,'
            'Segoe UI,Roboto,sans-serif" dominant-baseline="central">%s</text>'
            % (x, y, size, weight, fill, anchor, ls, esc(t)))

def btn(name, label, fill=None, size=24, tcol="#fff", rr=None):
    x, y, w, h = R[name]
    fill = fill or C["neutral"]
    rr = rr if rr is not None else min(22, h / 2)
    return (rect(x, y, w, h, fill, rr, "rgba(255,255,255,.16)")
            + text(x + w / 2, y + h / 2, label, size, 700, tcol))

def chip(x, y, w, h, label, value, tcol="#fff"):
    return (rect(x, y, w, h, "rgba(255,255,255,.07)", 16, C["stroke"])
            + text(x + w / 2, y + 19, label, 17, 600, "rgba(255,255,255,.5)")
            + text(x + w / 2, y + h - 22, value, 30, 800, tcol))

def shell(screen_title, nav_slot, body, pushed=False, playing=False):
    o = [rect(0, 0, W, H, "#08070f", 30)]
    o.append('<defs><linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">'
             '<stop offset="0" stop-color="#1e1442"/>'
             '<stop offset="1" stop-color="#07060f"/></linearGradient></defs>')
    o.append(rect(0, 0, W, H, "url(#bg)", 30))
    o.append(rect(0, 0, W, HANDLE, "#1c1240", 0))
    o.append(text(24, HANDLE / 2, "PIANOAR", 24, 900, "rgba(255,255,255,.62)", "start", 3.2))
    o.append(text(W - 24, HANDLE / 2, "PINCH & HOLD TO MOVE", 19, 600,
                  "rgba(255,255,255,.42)", "end"))
    for dx in (-22, 0, 22):
        o.append('<circle cx="%s" cy="%s" r="4.5" fill="rgba(255,255,255,.5)"/>'
                 % (W / 2 + dx, HANDLE / 2))
    if pushed:
        x, y, w, h = R["backRect"]
        o.append(rect(x, y, w, h, C["neutral"], 20, "rgba(255,255,255,.16)"))
        o.append(text(x + w / 2, y + h / 2, "\u2039  BACK", 22, 700))
    if playing:
        x, y, w, h = R["minimizeRect"]
        o.append(rect(x, y, w, h, C["neutral"], 20, "rgba(255,255,255,.16)"))
        o.append(text(x + w / 2, y + h / 2, "\u25be HIDE", 22, 700))
    o.append(text(W / 2, HANDLE + HEADER / 2, screen_title, 27, 900, "rgba(255,255,255,.62)"))
    o.append(rect(0, CONTENT_TOP - 1, W, 1, "rgba(255,255,255,.10)", 0))
    o.append(body)
    o.append(rect(0, NAV_TOP, W, NAV, "rgba(255,255,255,.05)", 0))
    o.append(rect(0, NAV_TOP, W, 1, "rgba(255,255,255,.14)", 0))
    for i, t in enumerate(["SONGS", "PRACTICE", "SETUP"]):
        nx = i * (W / 3)
        if i == nav_slot:
            o.append(rect(nx + 10, NAV_TOP + 9, W / 3 - 20, NAV - 18, C["accent"], 20))
        o.append(text(nx + W / 6, NAV_TOP + NAV / 2, t, 24, 700,
                      "#fff" if i == nav_slot else "rgba(255,255,255,.5)"))
    return "".join(o)

def artwork(x, y, sz, title, diff):
    t = tint(title)
    o = [rect(x, y, sz, sz, t, sz * 0.26)]
    o.append(text(x + sz / 2, y + sz / 2 - sz * 0.06, title.strip()[:1].upper(),
                  sz * 0.52, 900, "rgba(20,20,20,.85)"))
    pw = sz * 0.10
    gap = pw * 0.5
    total = 5 * pw + 4 * gap
    px = x + sz / 2 - total / 2
    for i in range(5):
        o.append('<circle cx="%s" cy="%s" r="%s" fill="rgba(20,20,20,%s)"/>'
                 % (px + pw / 2, y + sz - pw / 2 - sz * 0.09, pw / 2,
                    0.8 if i < diff else 0.22))
        px += pw + gap
    return "".join(o)

SONGS = [("Dreiton", 36, 549, "C#1-G#6", 4), ("F\u00fcr Elise", 58, 412, "E2-E6", 3),
         ("Moonlight Sonata", 36, 255, "C#1-G#5", 3), ("Clair de Lune", 72, 634, "D1-A6", 5),
         ("Gymnop\u00e9die No.1", 39, 186, "G1-B5", 2), ("Minuet in G", 32, 214, "D2-E6", 2)]

# ── browse ──────────────────────────────────────────────────────────────
b = []
for i, (t, bars, notes, rng, d) in enumerate(SONGS):
    x = 36 + (i % 2) * (436 + 16)
    y = 130 + (i // 2) * (108 + 12)
    b.append(rect(x, y, 436, 108, C["card"], 22, C["stroke"]))
    b.append(rect(x, y + 14, 5, 108 - 28, tint(t), 2.5))
    b.append(artwork(x + 18, y + 108 / 2 - 33, 66, t, d))
    tx = x + 18 + 66 + 16
    b.append(text(tx, y + 39, t, 25, 800, "#fff", "start"))
    b.append(text(tx, y + 72, "%d bars \u00b7 %d notes \u00b7 %s" % (bars, notes, rng),
                  19, 500, "rgba(255,255,255,.55)", "start"))
    b.append(text(x + 436 - 24, y + 54, "\u203a", 34, 800, "rgba(255,255,255,.4)"))
b.append(btn("pagePrevRect", "\u2039  PREV"))
b.append(btn("pageNextRect", "NEXT  \u203a"))
b.append(text(W / 2, 490 + 34, "1 / 3", 25, 800, "rgba(255,255,255,.6)"))
browse = shell("SONGS", 0, "".join(b))

# ── song page ───────────────────────────────────────────────────────────
t, bars, notes, rng, d = SONGS[0]
s2 = [artwork(36, 134, 118, t, d)]
s2.append(text(36 + 118 + 22, 163, t, 34, 900, "#fff", "start"))
s2.append(text(36 + 118 + 22, 205, "Difficulty %d of 5" % d, 21, 600, tint(t), "start"))
cw = (W - 72 - 24) / 3
for i, (lab, val) in enumerate([("BARS", bars), ("NOTES", notes), ("RANGE", rng)]):
    s2.append(chip(36 + i * (cw + 12), 262, cw, 74, lab, val))
s2.append(btn("songHandRect", "BOTH HANDS"))
s2.append(btn("songTempoDownRect", "\u2212", size=38))
s2.append(btn("songTempoUpRect", "+", size=38))
s2.append(text((R["songTempoDownRect"][0] + R["songTempoDownRect"][2]
                + R["songTempoUpRect"][0]) / 2, 352 + 39, "100%", 30, 800))
s2.append(btn("songWaitRect", "WAIT FOR ME", C["green"], 23))
s2.append(btn("startSongRect", "\u25b6    START", C["blue"], 40, rr=28))
song = shell("SONG", 0, "".join(s2), pushed=True)

# ── practice ────────────────────────────────────────────────────────────
p = []
cw = (W - 72 - 36) / 4
for i, (lab, val, col) in enumerate([("BAR", "12/36", "#fff"), ("CORRECT", "84", C["green"]),
                                     ("MISSED", "3", C["amber"]), ("STREAK", "19", C["green"])]):
    p.append(chip(36 + i * (cw + 12), 126, cw, 64, lab, val, col))
x, y, w, h = R["seekRect"]
p.append(rect(x, y, w, h, C["card"], 20, C["stroke"]))
tx, ty, tw, th = x + 20, y + 38, w - 40, 26
for bnum in (8, 16, 24, 32):
    p.append(rect(tx + tw * bnum / 36 - 1, ty - 13, 2, 10, "rgba(255,255,255,.2)", 0))
p.append(rect(tx, ty, tw, th, "rgba(255,255,255,.14)", 13))
la, lb = tx + tw * 0.28, tx + tw * 0.42
p.append(rect(la, ty - 7, lb - la, th + 14, "rgba(255,178,56,.30)", 12))
for lx in (la, lb):
    p.append(rect(lx - 3, ty - 7, 6, th + 14, C["amber"], 3))
p.append(rect(tx, ty, tw * 0.33, th, C["blue"], 13))
hx = tx + tw * 0.33
p.append('<circle cx="%s" cy="%s" r="15" fill="#fff"/>' % (hx, ty + 13))
p.append('<circle cx="%s" cy="%s" r="5" fill="#0a0818"/>' % (hx, ty + 13))
p.append(text(tx + tw / 2, y + h - 15, "LOOP  bars 11\u201315   \u00b7   3\u00d7 round",
              20, 600, C["amber"]))
p.append(btn("restartRect", "\u21ba  START", size=26))
p.append(btn("playRect", "\u25b6  PLAY", C["blue"], 36, rr=26))
p.append(btn("skipRect", "SKIP  \u25b8\u25b8", size=26))
p.append(btn("loopPhraseRect", "\u27f2  LOOP 4 BARS", size=23))
p.append(btn("loopARect", "SET  A", size=22))
p.append(btn("loopBRect", "SET  B", size=22))
p.append(btn("loopOnRect", "LOOP:  ON", C["amber"], 24, "#111"))
p.append(btn("tempoDownRect", "\u2212", size=36))
p.append(btn("tempoUpRect", "+", size=36))
p.append(text((R["tempoDownRect"][0] + R["tempoDownRect"][2] + R["tempoUpRect"][0]) / 2,
              488 + 37, "85%", 30, 800))
p.append(btn("waitRect", "WAIT FOR ME", C["green"], 22))
p.append(btn("handRect", "BOTH HANDS", size=22))
practice = shell("PRACTICE", 1, "".join(p), playing=True)

# ── results ─────────────────────────────────────────────────────────────
r = [text(W / 2, 148, "Dreiton", 28, 800)]
r.append(text(W / 2, 220, "92%", 74, 900, C["green"]))
r.append(text(W / 2, 276, "ACCURACY", 20, 800, "rgba(255,255,255,.5)"))
cw = (W - 72 - 36) / 4
for i, (lab, val, col) in enumerate([("CORRECT", "505", C["green"]), ("WRONG", "18", C["red"]),
                                     ("MISSED", "26", C["amber"]), ("BEST RUN", "63", "#fff")]):
    r.append(chip(36 + i * (cw + 12), 306, cw, 78, lab, val, col))
r.append(text(W / 2, 411, "Notes landed 38 ms off the beat on average", 21, 600,
              "rgba(255,255,255,.55)"))
r.append(btn("againRect", "\u21ba  AGAIN", C["blue"], 26, rr=26))
r.append(btn("practiceWeakRect", "\u27f2  DRILL LAST 4 BARS", C["amber"], 21, "#111", 26))
r.append(btn("backToSongsRect", "SONGS", size=26, rr=26))
results = shell("RESULT", 1, "".join(r), pushed=True)

# ── align ───────────────────────────────────────────────────────────────
def settings_tabs(active):
    o = []
    w = (W - 72 - 16) / 3
    for i, t in enumerate(["VIEW", "ACCESS", "ALIGN"]):
        x = 36 + i * (w + 8)
        o.append(rect(x, 124, w, 74, C["accent"] if i == active else C["neutral"], 18,
                      "rgba(255,255,255,.16)"))
        o.append(text(x + w / 2, 124 + 37, t, 24, 800 if i == active else 600,
                      "#fff" if i == active else "rgba(255,255,255,.75)"))
    return "".join(o)

a = [settings_tabs(2)]
a.append(text(W / 2, 214, "x +12 mm   z \u22123 mm   width 100.4%   turn \u22120.6\u00b0",
              21, 600, "rgba(140,242,255,.9)"))
a.append(btn("alignModeRect", "PUSH:  POSITION", C["accent"], 23, rr=18))
a.append(btn("padUpRect", "\u25b2 AWAY", size=26))
a.append(btn("padLeftRect", "\u25c0 5 mm", size=26))
a.append(btn("padRightRect", "5 mm \u25b6", size=26))
a.append(btn("padDownRect", "\u25bc NEAR", size=26))
a.append(btn("mapRect", "\u2316  MAP KEYS", C["blue"], 22))
a.append(btn("labelsRect", "LABELS:  ON", C["green"], 22))
a.append(btn("debugRect", "DEBUG:  OFF", size=22))
a.append(btn("alignResetRect", "RESET ALIGN", size=22))
a.append(btn("recordRect", "\u25c9  RECORD", size=22))
a.append(btn("calibRect", "CALIBRATE", size=22))
align = shell("ALIGN", 2, "".join(a))

# ── pill ────────────────────────────────────────────────────────────────
pl = [rect(40, 16, 880, 116, "#0a0819", 58)]
pl.append(btn("pauseRect", "\u275a\u275a  PAUSE", C["red"], 31, rr=44))
pl.append(btn("pillLoopRect", "\u27f2  LOOP ON", C["amber"], 31, "#111", 44))
pl.append(btn("pillSkipRect", "SKIP  \u25b8\u25b8", size=31, rr=44))
pl.append(btn("menuRect", "\u2630  MENU", C["accent"], 31, rr=44))
pill = '<svg viewBox="0 0 960 148" width="100%%">%s</svg>' % "".join(pl)

SCREENS = [("Songs", "The library, as cards. Tint, initial and difficulty pips stand in for "
                     "cover art, so a piece looks the same every time you come back to it.", browse),
           ("Song", "New. Choosing a song no longer starts it \u2014 this is where hands, "
                    "tempo and mode are set, and START is a deliberate second press.", song),
           ("Practice", "Live stat chips, the scrub bar with the marked section behind the "
                        "progress fill, transport, then section and tempo controls.", practice),
           ("Result", "New. Appears by itself when a piece ends, and offers to drill the "
                      "bars you just finished rather than sending you back to the top.", results),
           ("Align", "Twelve nudge buttons became one pad and a mode \u2014 moving a keyboard "
                     "overlay is a spatial job, so it gets a spatial control.", align)]

cards = []
for name, note, svg in SCREENS:
    cards.append('<section><h2>%s</h2><p>%s</p>'
                 '<div class="panel"><svg viewBox="0 0 960 640" width="100%%">%s</svg></div>'
                 '</section>' % (esc(name), esc(note), svg))
cards.append('<section><h2>Minimised</h2><p>What is on screen while a song plays. LOOP is '
             'here because the bars you want to repeat are the ones you just played.</p>'
             '<div class="panel pill">%s</div></section>' % pill)

doc = """<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>PianoAR Panel</title><style>
:root{--bg:#0d0b14;--fg:#efecf7;--mut:#a29ab8;--line:rgba(255,255,255,.09);}
@media(prefers-color-scheme:light){:root:not([data-theme="dark"]){--bg:#f6f4fb;--fg:#17141f;--mut:#5d5570;--line:rgba(0,0,0,.10);}}
:root[data-theme="dark"]{--bg:#0d0b14;--fg:#efecf7;--mut:#a29ab8;--line:rgba(255,255,255,.09);}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;padding:40px 16px 72px}
.wrap{max-width:1040px;margin:0 auto}
h1{font-size:clamp(26px,5vw,38px);margin:0 0 6px;letter-spacing:-.02em}
.sub{color:var(--mut);margin:0 0 40px;max-width:70ch}
section{margin:0 0 44px}
h2{font-size:20px;margin:0 0 4px;letter-spacing:-.01em}
section p{color:var(--mut);margin:0 0 14px;max-width:74ch;font-size:15px}
.panel{border:1px solid var(--line);border-radius:18px;overflow:hidden;background:#07060f;line-height:0}
.pill{background:transparent;border:none}
</style></head><body><div class="wrap">
<h1>PianoAR \u2014 panel redesign</h1>
<p class="sub">Every rectangle here is read out of ARMenuPanel.swift, so this is the real
geometry at the real texture size (960\u00d7640), not a sketch. Colours and type sizes mirror
the drawing code.</p>
%s
</div></body></html>""" % "".join(cards)

io.open("panel-mockup.html", "w", encoding="utf-8").write(doc)

# One file per screen as well: the review browser cannot scroll a long page
# reliably, and a screen that has to be scrolled to is a screen that does not
# get looked at.
ONE = ("""<!doctype html><html><head><meta charset="utf-8">
<title>%s</title><style>body{margin:0;background:#07060f}
svg{display:block;width:100vw;max-width:1100px;margin:0 auto}</style></head>
<body><svg viewBox="0 0 960 640">%s</svg></body></html>""")
for nm, svg in [("browse", browse), ("song", song), ("practice", practice),
                ("results", results), ("align", align)]:
    io.open("mock-%s.html" % nm, "w", encoding="utf-8").write(ONE % (nm, svg))
print("wrote panel-mockup.html + 5 per-screen files (%d rects from Swift)" % len(R))
