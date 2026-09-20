"""Static check of the AR panel layout.

The panel is drawn with hand-placed CGRects on a 960x640 texture, and the
same rects drive hit-testing -- so a rect that overlaps its neighbour is not
just ugly, it is a button that steals another button's presses. Nothing about
that is visible until the headset is on, which is exactly why it is worth
checking on the desk.
"""
import re, sys, io

src = io.open("PianoAR/ARMenuOverlay.swift", encoding="utf-8").read()

TEX_W, TEX_H = 960, 640
HANDLE_H, TAB_BAR_H, HEADER_H = 58, 72, 56
CONTENT_TOP = HANDLE_H + HEADER_H       # 114
TAB_TOP = TEX_H - TAB_BAR_H             # 568

rects = {}
for m in re.finditer(
        r"private static let (\w+Rect)\s*=\s*CGRect\(x:\s*(-?\d+),\s*y:\s*(-?\d+),"
        r"\s*width:\s*(\d+),\s*height:\s*(\d+)\)", src):
    name, x, y, w, h = m.group(1), *map(int, m.groups()[1:])
    rects[name] = (x, y, w, h)

TABS = {
    "practice": ["seekRect", "restartRect", "playRect", "skipRect", "loopPhraseRect",
                 "loopARect", "loopBRect", "loopOnRect", "tempoDownRect", "tempoUpRect",
                 "waitRect", "handRect"],
    "access":   ["textSizeRect", "contrastRect", "dwellRect", "cbRect", "accessResetRect"],
    "comfort":  ["viewDownRect", "viewUpRect", "lensDownRect", "lensUpRect", "smoothRect",
                 "stereoRect", "handStyleRect", "comfortResetRect"],
    "setup":    ["mapRect", "debugRect", "labelsRect", "alignResetRect", "recordRect",
                 "calibRect"],
    "pill":     ["pauseRect", "pillLoopRect", "pillSkipRect", "menuRect"],
}

def overlap(a, b):
    ax, ay, aw, ah = a; bx, by, bw, bh = b
    ox = max(0, min(ax + aw, bx + bw) - max(ax, bx))
    oy = max(0, min(ay + ah, by + bh) - max(ay, by))
    return ox * oy

problems = []
for tab, names in TABS.items():
    missing = [n for n in names if n not in rects]
    if missing:
        problems.append("%s: rect not found: %s" % (tab, ", ".join(missing)))
    got = [(n, rects[n]) for n in names if n in rects]
    for i in range(len(got)):
        for j in range(i + 1, len(got)):
            a, b = got[i], got[j]
            if overlap(a[1], b[1]):
                problems.append("%s: %s overlaps %s by %d px^2" % (tab, a[0], b[0], overlap(a[1], b[1])))
    for n, (x, y, w, h) in got:
        if x < 0 or x + w > TEX_W:
            problems.append("%s: %s runs off the side (x %d..%d)" % (tab, n, x, x + w))
        if tab == "pill":
            continue
        if y < CONTENT_TOP:
            problems.append("%s: %s starts above the content area (y %d < %d)" % (tab, n, y, CONTENT_TOP))
        if y + h > TAB_TOP:
            problems.append("%s: %s runs into the tab bar (y %d > %d)" % (tab, n, y + h, TAB_TOP))

# Minimum touch target. Stricter on the screens used mid-practice -- with a
# song running you are aiming one-handed at a panel that is also moving with
# your head. SETUP is laid out once and then left alone, so its denser grid of
# nudge buttons is allowed to be smaller.
MIN_TARGET = {"practice": (108, 72), "pill": (108, 72), "access": (108, 72),
              "comfort": (108, 72), "setup": (100, 66)}
for tab, names in TABS.items():
    minw, minh = MIN_TARGET[tab]
    for n in names:
        if n not in rects:
            continue
        _, _, w, h = rects[n]
        if w < minw or h < minh:
            problems.append("%s: %s is a small target (%dx%d, floor %dx%d)"
                            % (tab, n, w, h, minw, minh))

# five tabs have to fit across the bar
tab_w = TEX_W / 5
print("tab width %.0f px for 5 tabs" % tab_w)
print("%d rects parsed" % len(rects))
for tab, names in TABS.items():
    ys = [(rects[n][1], rects[n][1] + rects[n][3]) for n in names if n in rects]
    if ys:
        print("  %-9s %2d controls, y %d..%d" % (tab, len(ys), min(a for a, _ in ys), max(b for _, b in ys)))

# Text blocks are drawn into inline CGRects that no hit-test knows about, so
# nothing stops one from being laid over a row of buttons -- which is exactly
# what happened to the VIEW and SETUP help paragraphs. Check them too.
DRAW_FN = {"drawPractice": "practice", "drawAccess": "access",
           "drawComfort": "comfort", "drawSetup": "setup"}

def val(tok):
    tok = tok.strip()
    m = re.fullmatch(r"texW\s*-\s*(\d+)", tok)
    if m:
        return TEX_W - int(m.group(1))
    m = re.fullmatch(r"-?\d+", tok)
    return int(tok) if m else None

for fn, tab in DRAW_FN.items():
    m = re.search(r"private static func %s\(_ s: PanelSnap\) \{" % fn, src)
    if not m:
        problems.append("%s: draw function not found" % tab)
        continue
    depth, i = 0, m.end() - 1
    while i < len(src):
        if src[i] == "{": depth += 1
        elif src[i] == "}":
            depth -= 1
            if depth == 0: break
        i += 1
    body = src[m.end():i]
    controls = [(n, rects[n]) for n in TABS[tab] if n in rects]
    for cm in re.finditer(r"CGRect\(x:\s*([^,]+),\s*y:\s*([^,]+),\s*"
                          r"width:\s*([^,]+),\s*height:\s*([^)]+)\)", body):
        vals = [val(g) for g in cm.groups()]
        if any(v is None for v in vals):
            continue                      # derived from another rect; skip
        x, y, w, h = vals
        if h <= 0 or w <= 0:
            problems.append("%s: text block at y %d has no area (%dx%d)" % (tab, y, w, h))
            continue
        for n, r in controls:
            if overlap((x, y, w, h), r):
                problems.append("%s: text block (x %d y %d %dx%d) covers %s"
                                % (tab, x, y, w, h, n))
        if y + h > TAB_TOP:
            problems.append("%s: text block at y %d..%d runs into the tab bar"
                            % (tab, y, y + h))

if problems:
    print("\nPROBLEMS (%d):" % len(problems))
    for p in problems:
        print("  - " + p)
    sys.exit(1)
print("\nlayout OK: no overlaps, everything inside the content area")
