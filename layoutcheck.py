"""Static check of the AR panel layout.

The panel is hand-placed CGRects on a 960x640 texture and the same rects do
the hit-testing, so a rect over its neighbour is not a cosmetic problem -- it
is a button that eats another button's presses. None of it is visible until
the headset is on, which is why it is worth checking on the desk.
"""
import re, sys, io

src = io.open("PianoAR/ARMenuPanel.swift", encoding="utf-8").read()

TEX_W, TEX_H = 960, 640
HANDLE_H, HEADER_H, NAV_H = 58, 64, 72
CONTENT_TOP = HANDLE_H + HEADER_H       # 122
NAV_TOP = TEX_H - NAV_H                 # 568

rects = {}
for m in re.finditer(
        r"static let (\w+Rect)\s*=\s*CGRect\(x:\s*(-?\d+),\s*y:\s*(-?\d+),"
        r"\s*width:\s*(\d+),\s*height:\s*(\d+)\)", src):
    rects[m.group(1)] = tuple(int(g) for g in m.groups()[1:])

# Screens, as the control tables define them. Parsed from the source so a
# control added to a table without a rect shows up here rather than in the
# headset.
SCREENS = {}
for m in re.finditer(r"static let (\w+)Controls: \[\(Region, CGRect\)\] = \[(.*?)\]",
                     src, re.S):
    SCREENS[m.group(1)] = re.findall(r",\s*(\w+Rect)\)", m.group(2))
SCREENS["pill"] = ["pauseRect", "pillLoopRect", "pillSkipRect", "menuRect"]
SCREENS["browse"] = SCREENS.get("browse", []) + ["__libcells__"]

# library cells come from a formula, not constants
LIB_COLS, LIB_ROWS, LIB_W, LIB_H = 2, 3, 436, 108
lib_cells = [(36 + (i % LIB_COLS) * (LIB_W + 16),
              130 + (i // LIB_COLS) * (LIB_H + 12), LIB_W, LIB_H)
             for i in range(LIB_COLS * LIB_ROWS)]

# Read the settings sub-tabs out of their formula rather than restating it,
# so changing the Swift cannot leave the checker validating an old layout.
_st = re.search(r"static func settingsTabRect.*?y:\s*(\d+),\s*width:\s*w,"
                r"\s*height:\s*(\d+)\)", src, re.S)
_ST_Y, _ST_H = (int(_st.group(1)), int(_st.group(2))) if _st else (126, 66)
_ST_W = (TEX_W - 72 - 16) / 3
SETTINGS_TABS = [(36 + i * (_ST_W + 8), _ST_Y, _ST_W, _ST_H) for i in range(3)]

def overlap(a, b):
    ax, ay, aw, ah = a; bx, by, bw, bh = b
    return (max(0, min(ax + aw, bx + bw) - max(ax, bx))
            * max(0, min(ay + ah, by + bh) - max(ay, by)))

problems = []

def named(screen):
    out = []
    for n in SCREENS.get(screen, []):
        if n == "__libcells__":
            out += [("card%d" % i, c) for i, c in enumerate(lib_cells)]
        elif n in rects:
            out.append((n, rects[n]))
        else:
            problems.append("%s: rect not found: %s" % (screen, n))
    if screen in ("view", "access", "align"):
        out += [("settingsTab%d" % i, t) for i, t in enumerate(SETTINGS_TABS)]
    return out

MIN_TARGET = {"play": (108, 72), "pill": (108, 72), "access": (108, 72),
              "view": (96, 72), "browse": (108, 66), "song": (96, 72),
              "result": (108, 72), "align": (100, 66)}

for screen in SCREENS:
    got = named(screen)
    for i in range(len(got)):
        for j in range(i + 1, len(got)):
            if overlap(got[i][1], got[j][1]):
                problems.append("%s: %s overlaps %s" % (screen, got[i][0], got[j][0]))
    for n, (x, y, w, h) in got:
        if x < 0 or x + w > TEX_W:
            problems.append("%s: %s runs off the side (x %d..%d)" % (screen, n, x, x + w))
        if screen == "pill":
            continue
        if y < CONTENT_TOP:
            problems.append("%s: %s starts above the content area (y %d < %d)"
                            % (screen, n, y, CONTENT_TOP))
        if y + h > NAV_TOP:
            problems.append("%s: %s runs into the nav bar (y %d > %d)"
                            % (screen, n, y + h, NAV_TOP))
        minw, minh = MIN_TARGET.get(screen, (100, 66))
        if w < minw or h < minh:
            problems.append("%s: %s is a small target (%dx%d, floor %dx%d)"
                            % (screen, n, w, h, minw, minh))

# Text blocks are drawn into inline CGRects that no hit-test knows about, so
# nothing stops one being laid over a row of buttons.
DRAW_FN = {"drawBrowse": "browse", "drawSongPage": "song", "drawPractice": "play",
           "drawResults": "result", "drawView": "view", "drawAccess": "access",
           "drawAlign": "align"}

def val(tok):
    tok = tok.strip()
    m = re.fullmatch(r"texW\s*-\s*(\d+)", tok)
    if m:
        return TEX_W - int(m.group(1))
    return int(tok) if re.fullmatch(r"-?\d+", tok) else None

for fn, screen in DRAW_FN.items():
    m = re.search(r"static func %s\(_ s: PanelSnap\) \{" % fn, src)
    if not m:
        problems.append("%s: draw function not found" % screen)
        continue
    depth, i = 0, m.end() - 1
    while i < len(src):
        if src[i] == "{": depth += 1
        elif src[i] == "}":
            depth -= 1
            if depth == 0: break
        i += 1
    body, controls = src[m.end():i], named(screen)
    # An empty state and the content it replaces are mutually exclusive, so
    # a placeholder drawn over where the cards *would* be is not a collision.
    for em in re.finditer(r"isEmpty \{", body):
        d, j = 0, em.end() - 1
        while j < len(body):
            if body[j] == "{": d += 1
            elif body[j] == "}":
                d -= 1
                if d == 0: break
            j += 1
        body = body[:em.end()] + " " * (j - em.end()) + body[j:]
    for cm in re.finditer(r"CGRect\(x:\s*([^,]+),\s*y:\s*([^,]+),\s*"
                          r"width:\s*([^,]+),\s*height:\s*([^)]+)\)", body):
        vals = [val(g) for g in cm.groups()]
        if any(v is None for v in vals):
            continue                       # derived from another rect; skip
        x, y, w, h = vals
        if w <= 0 or h <= 0:
            problems.append("%s: text block at y %d has no area (%dx%d)" % (screen, y, w, h))
            continue
        for n, r in controls:
            if overlap((x, y, w, h), r):
                problems.append("%s: text block (x %d y %d %dx%d) covers %s"
                                % (screen, x, y, w, h, n))
        if y + h > NAV_TOP:
            problems.append("%s: text block at y %d..%d runs into the nav bar"
                            % (screen, y, y + h))

print("%d rects parsed, %d screens" % (len(rects), len(SCREENS)))
for screen in sorted(SCREENS):
    got = named(screen)
    if got:
        print("  %-7s %2d controls, y %d..%d" % (screen, len(got),
              min(r[1] for _, r in got), max(r[1] + r[3] for _, r in got)))

if problems:
    print("\nPROBLEMS (%d):" % len(problems))
    for p in problems:
        print("  - " + p)
    sys.exit(1)
print("\nlayout OK: no overlaps, everything inside the content area")
