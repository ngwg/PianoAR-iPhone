import SceneKit
import UIKit

// MARK: - What the panel is made of
//
// Presentation only: screens, layout, the design tokens and every draw call.
// The cursor, grab, poke and dwell code lives in ARMenuOverlay and does not
// know what is being drawn — it only asks which Region a point lands in.
//
// The organising idea is that the panel has *screens*, not tabs. Tabs made
// "pick a song" and "set the lens spacing" look like peers, which they are
// not: one is the thing you came to do and the other is something you did
// once in week one. Three places to go — SONGS, PLAY, SETUP — and two more
// the app pushes you into when there is something to say: a song's own page
// when you choose it, and a result when you finish.

extension ARMenuOverlay {

    enum Screen: Int, CaseIterable {
        case browse, song, play, results, view, access, align

        /// Which primary nav item is lit while this screen is up.
        var navSlot: Int {
            switch self {
            case .browse, .song:      return 0
            case .play, .results:     return 1
            case .view, .access, .align: return 2
            }
        }
        var isSettings: Bool { self == .view || self == .access || self == .align }
        /// Pushed screens get a back arrow instead of a title.
        var isPushed: Bool { self == .song || self == .results }

        var heading: String {
            switch self {
            case .browse:  return "SONGS"
            case .song:    return "SONG"
            case .play:    return "PRACTICE"
            case .results: return "RESULT"
            case .view:    return "VIEW"
            case .access:  return "ACCESS"
            case .align:   return "ALIGN"
            }
        }
    }

    enum NavItem: Int, CaseIterable {
        case songs, play, setup
        var title: String {
            switch self {
            case .songs: return "SONGS"
            case .play:  return "PRACTICE"
            case .setup: return "SETUP"
            }
        }
        var screen: Screen {
            switch self {
            case .songs: return .browse
            case .play:  return .play
            case .setup: return .view
            }
        }
    }

    enum Region: Equatable {
        case none
        case handle
        case nav(Int)                      // primary nav slot
        case settingsTab(Int)              // VIEW / ACCESS / ALIGN
        case back, minimize
        case song(Int)                     // absolute song index
        case pagePrev, pageNext
        // song page
        case startSong, songHand, songTempoDown, songTempoUp, songWait
        // practice
        case play, restart, skip, seek
        case loopPhrase, loopA, loopB, loopOn
        case tempoDown, tempoUp, hand, wait
        // results
        case againSong, practiceWeak, backToSongs
        // view
        case viewDown, viewUp, lensDown, lensUp, smooth, stereo
        case handStyle, frameRate, comfortReset
        // access
        case textSize, contrast, dwell, colorBlind, accessReset
        // align
        case alignMode, padUp, padDown, padLeft, padRight
        case mapKeys, labels, debug, alignReset, record, calibrate
        // minimised pill
        case pillPause, pillLoop, pillSkip, pillMenu

        var actionable: Bool { self != .none && self != .handle }
    }

    /// One song as the browser shows it. Derived once when the library
    /// changes, not per frame.
    struct SongCard: Equatable {
        var title: String
        var bars: Int
        var notes: Int
        var difficulty: Int          // 1...5
        var range: String

        static func make(_ s: Song) -> SongCard {
            let midis = s.notes.compactMap { $0.midiNote }
            let lastBeat = s.notes.map { $0.startBeat + $0.durationBeats }.max() ?? 0
            let bars = max(1, Int(lastBeat / SongPlayer.beatsPerBar) + 1)
            let seconds = max(1.0, lastBeat * 60.0 / max(1, s.bpm))
            let density = Double(s.notes.count) / seconds
            let span = (midis.max() ?? 60) - (midis.min() ?? 60)
            // Density does most of the work; a wide span means the hands have
            // to move rather than sit. Neither is a real difficulty model, but
            // both are honest about what makes a piece hard to sight-read.
            let score = density / 3.0 + Double(span) / 40.0
            let names = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
            let nm: (Int) -> String = { "\(names[$0 % 12])\($0 / 12 - 1)" }
            return SongCard(title: s.title ?? "Untitled",
                            bars: bars,
                            notes: s.notes.count,
                            difficulty: min(5, max(1, Int(score.rounded()))),
                            range: midis.isEmpty ? "—" : "\(nm(midis.min()!))–\(nm(midis.max()!))")
        }
    }

    /// Everything a bake needs, captured on the render thread.
    struct PanelSnap {
        let screen: Screen
        let minimized: Bool
        let state: MenuState
        let page: Int
        let pageCount: Int
        let pageCards: [SongCard]
        let selected: SongCard?
        let grabbing: Bool
        let hotRect: CGRect?
    }

    // MARK: - Bands

    static let handleH: CGFloat = 58
    static let headerH: CGFloat = 64
    static let navH:    CGFloat = 72
    static var contentTop: CGFloat { handleH + headerH }     // 122
    static var navTop:     CGFloat { texH - navH }           // 568

    static func navRect(_ i: Int) -> CGRect {
        let w = texW / CGFloat(NavItem.allCases.count)
        return CGRect(x: CGFloat(i) * w, y: navTop, width: w, height: navH)
    }
    static func settingsTabRect(_ i: Int) -> CGRect {
        let w = (texW - 72 - 16) / 3
        return CGRect(x: 36 + CGFloat(i) * (w + 8), y: 124, width: w, height: 74)
    }

    static let backRect     = CGRect(x: 24, y: 64, width: 150, height: 52)
    static let minimizeRect = CGRect(x: 790, y: 64, width: 146, height: 52)

    // ── Browse ──────────────────────────────────────────────────────────
    static let libCols = 2, libRows = 3
    static var libPerPage: Int { libCols * libRows }
    static func libCellRect(_ i: Int) -> CGRect {
        let w: CGFloat = 436, h: CGFloat = 108
        return CGRect(x: 36 + CGFloat(i % libCols) * (w + 16),
                      y: 130 + CGFloat(i / libCols) * (h + 12), width: w, height: h)
    }
    static let pagePrevRect = CGRect(x: 36,  y: 490, width: 200, height: 68)
    static let pageNextRect = CGRect(x: 724, y: 490, width: 200, height: 68)

    // ── Song page ───────────────────────────────────────────────────────
    static let songHandRect      = CGRect(x: 36,  y: 352, width: 284, height: 78)
    static let songTempoDownRect = CGRect(x: 330, y: 352, width: 96,  height: 78)
    static let songTempoUpRect   = CGRect(x: 528, y: 352, width: 96,  height: 78)
    static let songWaitRect      = CGRect(x: 640, y: 352, width: 284, height: 78)
    static let startSongRect     = CGRect(x: 36,  y: 446, width: 888, height: 112)

    // ── Practice ────────────────────────────────────────────────────────
    static let seekRect       = CGRect(x: 36,  y: 190, width: 888, height: 100)
    static let restartRect    = CGRect(x: 36,  y: 300, width: 252, height: 94)
    static let playRect       = CGRect(x: 318, y: 300, width: 324, height: 94)
    static let skipRect       = CGRect(x: 672, y: 300, width: 252, height: 94)
    static let loopPhraseRect = CGRect(x: 36,  y: 404, width: 282, height: 74)
    static let loopARect      = CGRect(x: 348, y: 404, width: 132, height: 74)
    static let loopBRect      = CGRect(x: 498, y: 404, width: 132, height: 74)
    static let loopOnRect     = CGRect(x: 648, y: 404, width: 276, height: 74)
    static let tempoDownRect  = CGRect(x: 36,  y: 488, width: 110, height: 74)
    static let tempoUpRect    = CGRect(x: 256, y: 488, width: 110, height: 74)
    static let waitRect       = CGRect(x: 396, y: 488, width: 252, height: 74)
    static let handRect       = CGRect(x: 672, y: 488, width: 252, height: 74)

    // ── Results ─────────────────────────────────────────────────────────
    static let againRect       = CGRect(x: 36,  y: 458, width: 284, height: 100)
    static let practiceWeakRect = CGRect(x: 330, y: 458, width: 300, height: 100)
    static let backToSongsRect = CGRect(x: 640, y: 458, width: 284, height: 100)

    // ── View ────────────────────────────────────────────────────────────
    static let viewDownRect  = CGRect(x: 516, y: 200, width: 124, height: 74)
    static let viewUpRect    = CGRect(x: 800, y: 200, width: 124, height: 74)
    static let lensDownRect  = CGRect(x: 516, y: 282, width: 124, height: 74)
    static let lensUpRect    = CGRect(x: 800, y: 282, width: 124, height: 74)
    static let smoothRect    = CGRect(x: 36,  y: 364, width: 432, height: 74)
    static let stereoRect    = CGRect(x: 492, y: 364, width: 432, height: 74)
    static let handStyleRect = CGRect(x: 36,  y: 446, width: 284, height: 74)
    static let frameRateRect = CGRect(x: 330, y: 446, width: 300, height: 74)
    static let comfortResetRect = CGRect(x: 640, y: 446, width: 284, height: 74)

    // ── Access ──────────────────────────────────────────────────────────
    static let textSizeRect    = CGRect(x: 36, y: 200, width: 888, height: 74)
    static let contrastRect    = CGRect(x: 36, y: 282, width: 888, height: 74)
    static let dwellRect       = CGRect(x: 36, y: 364, width: 888, height: 74)
    static let cbRect          = CGRect(x: 36, y: 446, width: 600, height: 74)
    static let accessResetRect = CGRect(x: 648, y: 446, width: 276, height: 74)

    // ── Align ───────────────────────────────────────────────────────────
    // A D-pad instead of twelve nudge buttons. Moving a keyboard overlay is a
    // spatial job, so it gets a spatial control: one pad, and a mode that
    // says what the pad is pushing.
    static let alignModeRect = CGRect(x: 306, y: 236, width: 348, height: 66)
    static let padUpRect     = CGRect(x: 425, y: 318, width: 110, height: 74)
    static let padLeftRect   = CGRect(x: 306, y: 400, width: 110, height: 74)
    static let padRightRect  = CGRect(x: 544, y: 400, width: 110, height: 74)
    static let padDownRect   = CGRect(x: 425, y: 482, width: 110, height: 74)
    static let mapRect       = CGRect(x: 36,  y: 318, width: 224, height: 74)
    static let labelsRect    = CGRect(x: 36,  y: 400, width: 224, height: 74)
    static let debugRect     = CGRect(x: 36,  y: 482, width: 224, height: 74)
    static let alignResetRect = CGRect(x: 700, y: 318, width: 224, height: 74)
    static let recordRect    = CGRect(x: 700, y: 400, width: 224, height: 74)
    static let calibRect     = CGRect(x: 700, y: 482, width: 224, height: 74)

    // ── Minimised pill ──────────────────────────────────────────────────
    static let pillRect     = CGRect(x: 40,  y: 16, width: 880, height: 116)
    static let pauseRect    = CGRect(x: 58,  y: 30, width: 206, height: 88)
    static let pillLoopRect = CGRect(x: 276, y: 30, width: 206, height: 88)
    static let pillSkipRect = CGRect(x: 494, y: 30, width: 206, height: 88)
    static let menuRect     = CGRect(x: 712, y: 30, width: 190, height: 88)

    // MARK: - Control tables

    static let browseControls: [(Region, CGRect)] = [
        (.pagePrev, pagePrevRect), (.pageNext, pageNextRect),
    ]
    static let songControls: [(Region, CGRect)] = [
        (.songHand, songHandRect), (.songTempoDown, songTempoDownRect),
        (.songTempoUp, songTempoUpRect), (.songWait, songWaitRect),
        (.startSong, startSongRect),
    ]
    static let playControls: [(Region, CGRect)] = [
        (.play, playRect), (.restart, restartRect), (.skip, skipRect), (.seek, seekRect),
        (.loopPhrase, loopPhraseRect), (.loopA, loopARect),
        (.loopB, loopBRect), (.loopOn, loopOnRect),
        (.tempoDown, tempoDownRect), (.tempoUp, tempoUpRect),
        (.hand, handRect), (.wait, waitRect),
    ]
    static let resultControls: [(Region, CGRect)] = [
        (.againSong, againRect), (.practiceWeak, practiceWeakRect),
        (.backToSongs, backToSongsRect),
    ]
    static let viewControls: [(Region, CGRect)] = [
        (.viewDown, viewDownRect), (.viewUp, viewUpRect),
        (.lensDown, lensDownRect), (.lensUp, lensUpRect),
        (.smooth, smoothRect), (.stereo, stereoRect),
        (.handStyle, handStyleRect), (.frameRate, frameRateRect),
        (.comfortReset, comfortResetRect),
    ]
    static let accessControls: [(Region, CGRect)] = [
        (.textSize, textSizeRect), (.contrast, contrastRect), (.dwell, dwellRect),
        (.colorBlind, cbRect), (.accessReset, accessResetRect),
    ]
    static let alignControls: [(Region, CGRect)] = [
        (.alignMode, alignModeRect),
        (.padUp, padUpRect), (.padDown, padDownRect),
        (.padLeft, padLeftRect), (.padRight, padRightRect),
        (.mapKeys, mapRect), (.labels, labelsRect), (.debug, debugRect),
        (.alignReset, alignResetRect), (.record, recordRect), (.calibrate, calibRect),
    ]

    static func controls(for screen: Screen) -> [(Region, CGRect)] {
        switch screen {
        case .browse:  return browseControls
        case .song:    return songControls
        case .play:    return playControls
        case .results: return resultControls
        case .view:    return viewControls
        case .access:  return accessControls
        case .align:   return alignControls
        }
    }
    static var allControls: [(Region, CGRect)] {
        browseControls + songControls + playControls + resultControls
            + viewControls + accessControls + alignControls
    }

    // MARK: - Design tokens
    //
    // Set at the top of bake() and read by every helper. bake() only ever
    // runs on the main queue and runs start to finish, so no two bakes
    // interleave.

    static var tScale: CGFloat = 1
    static var hiCon = false

    static func fnt(_ size: CGFloat, _ w: UIFont.Weight) -> UIFont {
        .systemFont(ofSize: (size * tScale).rounded(), weight: w)
    }
    static func monoFnt(_ size: CGFloat, _ w: UIFont.Weight) -> UIFont {
        .monospacedDigitSystemFont(ofSize: (size * tScale).rounded(), weight: w)
    }
    static func dim(_ a: CGFloat) -> UIColor {
        UIColor(white: 1, alpha: hiCon ? min(1, a * 0.45 + 0.55) : a)
    }
    static func lift(_ c: UIColor) -> UIColor {
        guard hiCon else { return c }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard c.getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return c }
        return UIColor(hue: h, saturation: s * 0.86, brightness: min(1, b * 1.15 + 0.10), alpha: a)
    }

    static var accent:  UIColor { lift(UIColor(red: 0.52, green: 0.40, blue: 1.00, alpha: 1)) }
    static var blue:    UIColor { lift(UIColor(red: 0.32, green: 0.66, blue: 1.00, alpha: 1)) }
    static var green:   UIColor { lift(UIColor(red: 0.20, green: 0.82, blue: 0.46, alpha: 1)) }
    static var red:     UIColor { lift(UIColor(red: 1.00, green: 0.34, blue: 0.34, alpha: 1)) }
    static var amber:   UIColor { lift(UIColor(red: 1.00, green: 0.70, blue: 0.22, alpha: 1)) }
    static var neutral: UIColor { UIColor(white: 1, alpha: hiCon ? 0.34 : 0.20) }

    /// A stable colour per song so a piece looks the same every time you come
    /// back to it — the closest thing to cover art without any art.
    static func songTint(_ title: String) -> UIColor {
        var h: UInt64 = 5381
        for b in title.utf8 { h = (h &* 33) &+ UInt64(b) }
        let hues: [CGFloat] = [0.72, 0.55, 0.42, 0.08, 0.93, 0.15]
        return lift(UIColor(hue: hues[Int(h % UInt64(hues.count))],
                            saturation: 0.62, brightness: 0.95, alpha: 1))
    }

    static var seekTrack: CGRect {
        CGRect(x: seekRect.minX + 20, y: seekRect.minY + 38, width: seekRect.width - 40, height: 26)
    }

    // MARK: - Primitives

    static func card(_ r: CGRect, radius: CGFloat = 20, fill: CGFloat = 0.055) {
        UIColor(white: 1, alpha: hiCon ? fill + 0.07 : fill).setFill()
        UIBezierPath(roundedRect: r, cornerRadius: radius).fill()
        dim(0.12).setStroke()
        let b = UIBezierPath(roundedRect: r.insetBy(dx: 0.75, dy: 0.75), cornerRadius: radius)
        b.lineWidth = 1.5
        b.stroke()
    }

    static func button(_ r: CGRect, _ title: String, fill: UIColor,
                       size: CGFloat = 24, weight: UIFont.Weight = .bold,
                       text: UIColor = .white, radius: CGFloat = 22) {
        let rad = min(radius, r.height / 2)
        let path = UIBezierPath(roundedRect: r, cornerRadius: rad)
        fill.setFill()
        path.fill()
        if let ctx = UIGraphicsGetCurrentContext(),
           let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [UIColor(white: 1, alpha: 0.18).cgColor,
                                       UIColor(white: 1, alpha: 0.00).cgColor] as CFArray,
                              locations: [0, 1]) {
            ctx.saveGState()
            path.addClip()
            ctx.drawLinearGradient(g, start: CGPoint(x: r.minX, y: r.minY),
                                   end: CGPoint(x: r.minX, y: r.midY), options: [])
            ctx.restoreGState()
        }
        dim(hiCon ? 0.55 : 0.16).setStroke()
        let b = UIBezierPath(roundedRect: r.insetBy(dx: 0.9, dy: 0.9), cornerRadius: rad)
        b.lineWidth = hiCon ? 2.5 : 1.5
        b.stroke()
        guard !title.isEmpty else { return }
        centered(title, in: r, font: fnt(size, weight), color: text)
    }

    /// Label above, value below. Borrowed shamelessly: it is the clearest way
    /// to put five numbers in a row and have none of them need explaining.
    static func chip(_ r: CGRect, _ label: String, _ value: String, tint: UIColor? = nil) {
        card(r, radius: 16, fill: 0.07)
        centered(label, in: CGRect(x: r.minX, y: r.minY + 8, width: r.width, height: 22),
                 font: fnt(17, .semibold), color: dim(0.5))
        centered(value, in: CGRect(x: r.minX, y: r.minY + 26, width: r.width, height: r.height - 32),
                 font: monoFnt(28, .heavy), color: tint ?? .white)
    }

    static func centered(_ text: String, in rect: CGRect, font: UIFont, color: UIColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let sz = text.size(withAttributes: attrs)
        text.draw(at: CGPoint(x: rect.minX + (rect.width - sz.width) / 2,
                              y: rect.minY + (rect.height - sz.height) / 2), withAttributes: attrs)
    }

    static func leftTruncated(_ text: String, in rect: CGRect, font: UIFont, color: UIColor) {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let h = font.lineHeight
        (text as NSString).draw(in: CGRect(x: rect.minX, y: rect.midY - h / 2,
                                           width: rect.width, height: h),
                                withAttributes: [.font: font, .foregroundColor: color,
                                                 .paragraphStyle: para])
    }

    static func rightAligned(_ text: String, in rect: CGRect, font: UIFont, color: UIColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let sz = text.size(withAttributes: attrs)
        text.draw(at: CGPoint(x: rect.maxX - sz.width, y: rect.midY - sz.height / 2),
                  withAttributes: attrs)
    }

    static func wrapped(_ text: String, in rect: CGRect, size: CGFloat,
                        align: NSTextAlignment = .left, alpha: CGFloat = 0.55) {
        let para = NSMutableParagraphStyle()
        para.alignment = align
        para.lineBreakMode = .byWordWrapping
        (text as NSString).draw(in: rect, withAttributes: [.font: fnt(size, .medium),
                                                           .foregroundColor: dim(alpha),
                                                           .paragraphStyle: para])
    }

    static func settingRow(_ r: CGRect, _ label: String, _ value: String, on: Bool) {
        button(r, "", fill: neutral, size: 1, radius: 22)
        leftTruncated(label, in: CGRect(x: r.minX + 26, y: r.minY, width: r.width * 0.52, height: r.height),
                      font: fnt(26, .heavy), color: .white)
        rightAligned(value, in: CGRect(x: r.midX, y: r.minY, width: r.width / 2 - 26, height: r.height),
                     font: fnt(26, .heavy), color: on ? green : dim(0.72))
    }

    /// The square that stands in for cover art: the song's tint, its initial,
    /// and difficulty as a row of pips.
    static func artwork(_ r: CGRect, _ c: SongCard) {
        let tint = songTint(c.title)
        tint.withAlphaComponent(0.92).setFill()
        UIBezierPath(roundedRect: r, cornerRadius: r.width * 0.26).fill()
        let letter = String(c.title.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
        centered(letter.isEmpty ? "♪" : letter,
                 in: CGRect(x: r.minX, y: r.minY - r.height * 0.06, width: r.width, height: r.height),
                 font: fnt(r.height * 0.52, .black), color: UIColor(white: 0.08, alpha: 0.85))
        let pipW = r.width * 0.10, gap = pipW * 0.5
        let total = CGFloat(5) * pipW + CGFloat(4) * gap
        var x = r.midX - total / 2
        for i in 0..<5 {
            UIColor(white: 0.08, alpha: i < c.difficulty ? 0.8 : 0.22).setFill()
            UIBezierPath(ovalIn: CGRect(x: x, y: r.maxY - pipW - r.height * 0.09,
                                        width: pipW, height: pipW)).fill()
            x += pipW + gap
        }
    }

    static func ring(_ r: CGRect?) {
        guard let r else { return }
        let c = hiCon ? UIColor(red: 1.0, green: 0.92, blue: 0.25, alpha: 1)
                      : UIColor(red: 0.55, green: 0.95, blue: 1.0, alpha: 0.95)
        c.withAlphaComponent(0.22).setStroke()
        let glow = UIBezierPath(roundedRect: r.insetBy(dx: -9, dy: -9), cornerRadius: 26)
        glow.lineWidth = 10
        glow.stroke()
        c.setStroke()
        let p = UIBezierPath(roundedRect: r.insetBy(dx: -4, dy: -4), cornerRadius: 22)
        p.lineWidth = hiCon ? 6 : 4
        p.stroke()
    }

    // MARK: - Bake

    static func bake(_ s: PanelSnap) -> UIImage {
        tScale = s.state.access.textSize.scale
        hiCon  = s.state.access.highContrast
        let sz = CGSize(width: texW, height: texH)
        return UIGraphicsImageRenderer(size: sz).image { ctx in
            if s.minimized {
                drawPill(s)
                ring(s.hotRect)
                return
            }
            let full = CGRect(origin: .zero, size: sz)
            UIColor(red: 0.03, green: 0.025, blue: 0.07, alpha: hiCon ? 1.0 : 0.97).setFill()
            UIBezierPath(roundedRect: full, cornerRadius: 30).fill()
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: [UIColor(red: hiCon ? 0.05 : 0.12, green: hiCon ? 0.04 : 0.08,
                                                   blue: hiCon ? 0.12 : 0.26, alpha: 1).cgColor,
                                           UIColor(red: hiCon ? 0.01 : 0.03, green: hiCon ? 0.01 : 0.02,
                                                   blue: hiCon ? 0.04 : 0.09, alpha: 1).cgColor] as CFArray,
                                  locations: [0, 1]) {
                ctx.cgContext.saveGState()
                UIBezierPath(roundedRect: full, cornerRadius: 30).addClip()
                ctx.cgContext.drawLinearGradient(g, start: .zero,
                                                 end: CGPoint(x: 0, y: texH), options: [])
                ctx.cgContext.restoreGState()
            }
            drawHandle(s)
            drawHeader(s)
            switch s.screen {
            case .browse:  drawBrowse(s)
            case .song:    drawSongPage(s)
            case .play:    drawPractice(s)
            case .results: drawResults(s)
            case .view:    drawView(s)
            case .access:  drawAccess(s)
            case .align:   drawAlign(s)
            }
            drawNav(s)
            ring(s.hotRect)
        }
    }

    static func drawPill(_ s: PanelSnap) {
        UIColor(red: 0.04, green: 0.03, blue: 0.10, alpha: hiCon ? 0.98 : 0.88).setFill()
        UIBezierPath(roundedRect: pillRect, cornerRadius: pillRect.height / 2).fill()
        button(pauseRect, s.state.isPlaying ? "❚❚  PAUSE" : "▶  PLAY",
               fill: s.state.isPlaying ? red : blue, size: 31, weight: .heavy, radius: 44)
        button(pillLoopRect, s.state.loopOn ? "⟲  LOOP ON" : "⟲  LOOP",
               fill: s.state.loopOn ? amber : neutral, size: 31, weight: .heavy,
               text: s.state.loopOn ? .black : .white, radius: 44)
        button(pillSkipRect, "SKIP  ▸▸", fill: neutral, size: 31, weight: .heavy, radius: 44)
        button(menuRect, "☰  MENU", fill: accent, size: 31, weight: .heavy, radius: 44)
    }

    static func drawHandle(_ s: PanelSnap) {
        let bg: UIColor = s.grabbing
            ? UIColor(red: 0.16, green: 0.46, blue: 0.22, alpha: 0.95)
            : UIColor(red: 0.11, green: 0.07, blue: 0.24, alpha: 0.92)
        bg.setFill()
        UIBezierPath(rect: CGRect(x: 0, y: 0, width: texW, height: handleH)).fill()
        dim(s.grabbing ? 0.95 : 0.5).setFill()
        for dx in [-22, 0, 22] {
            UIBezierPath(ovalIn: CGRect(x: texW / 2 + CGFloat(dx) - 4.5,
                                        y: handleH / 2 - 4.5,
                                        width: 9, height: 9)).fill()
        }
        let title = s.grabbing ? "MOVING…" : "PIANOAR"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: fnt(24, .black),
            .foregroundColor: dim(s.grabbing ? 0.95 : 0.62),
            .kern: 3.2 as NSObject,
        ]
        title.draw(at: CGPoint(x: 24, y: (handleH - title.size(withAttributes: attrs).height) / 2),
                   withAttributes: attrs)
        if !s.grabbing {
            let hint = "PINCH & HOLD TO MOVE"
            let a: [NSAttributedString.Key: Any] = [.font: fnt(19, .semibold),
                                                    .foregroundColor: dim(0.42)]
            hint.draw(at: CGPoint(x: texW - hint.size(withAttributes: a).width - 24,
                                  y: (handleH - hint.size(withAttributes: a).height) / 2),
                      withAttributes: a)
        }
    }

    static func drawHeader(_ s: PanelSnap) {
        if s.screen.isPushed {
            button(backRect, "‹  BACK", fill: neutral, size: 22, radius: 20)
        }
        centered(s.screen.heading, in: CGRect(x: 0, y: handleH, width: texW, height: headerH),
                 font: fnt(27, .black), color: dim(0.62))
        if s.state.isPlaying {
            button(minimizeRect, "▾ HIDE", fill: neutral, size: 22, radius: 20)
        }
        // A hairline under the header keeps the content from floating.
        dim(0.10).setFill()
        UIBezierPath(rect: CGRect(x: 0, y: contentTop - 1, width: texW, height: 1)).fill()
    }

    static func drawNav(_ s: PanelSnap) {
        dim(0.05).setFill()
        UIBezierPath(rect: CGRect(x: 0, y: navTop, width: texW, height: navH)).fill()
        dim(0.14).setFill()
        UIBezierPath(rect: CGRect(x: 0, y: navTop, width: texW, height: 1)).fill()
        let slot = s.screen.navSlot
        for item in NavItem.allCases {
            let r = navRect(item.rawValue)
            if item.rawValue == slot {
                accent.setFill()
                UIBezierPath(roundedRect: r.insetBy(dx: 10, dy: 9), cornerRadius: 20).fill()
            }
            centered(item.title, in: r, font: fnt(24, .bold),
                     color: item.rawValue == slot ? .white : dim(0.5))
        }
    }

    static func drawSettingsTabs(_ s: PanelSnap) {
        let titles = ["VIEW", "ACCESS", "ALIGN"]
        let active = [Screen.view, .access, .align].firstIndex(of: s.screen) ?? 0
        for (i, t) in titles.enumerated() {
            let r = settingsTabRect(i)
            button(r, t, fill: i == active ? accent : neutral, size: 24,
                   weight: i == active ? .heavy : .semibold, radius: 18)
        }
    }

    // MARK: - Screens

    static func drawBrowse(_ s: PanelSnap) {
        if s.pageCards.isEmpty {
            centered("No songs yet", in: CGRect(x: 0, y: 220, width: texW, height: 60),
                     font: fnt(29, .semibold), color: dim(0.5))
            wrapped("Drop a .mid file into Files › On My iPhone › PianoAR and it appears here.",
                    in: CGRect(x: 120, y: 290, width: texW - 240, height: 60), size: 22, align: .center)
            return
        }
        for (i, c) in s.pageCards.enumerated() {
            let r = libCellRect(i)
            card(r, radius: 22, fill: 0.06)
            let tint = songTint(c.title)
            // a tint rail down the left edge ties the card to its artwork
            tint.setFill()
            UIBezierPath(roundedRect: CGRect(x: r.minX, y: r.minY + 14, width: 5,
                                             height: r.height - 28), cornerRadius: 2.5).fill()
            let art = CGRect(x: r.minX + 18, y: r.midY - 33, width: 66, height: 66)
            artwork(art, c)
            let textX = art.maxX + 16
            leftTruncated(c.title, in: CGRect(x: textX, y: r.minY + 22,
                                              width: r.maxX - textX - 34, height: 34),
                          font: fnt(25, .heavy), color: .white)
            leftTruncated("\(c.bars) bars · \(c.notes) notes · \(c.range)",
                          in: CGRect(x: textX, y: r.minY + 58, width: r.maxX - textX - 34, height: 28),
                          font: fnt(19, .medium), color: dim(0.55))
            rightAligned("›", in: CGRect(x: r.maxX - 34, y: r.minY, width: 22, height: r.height),
                         font: fnt(34, .heavy), color: dim(0.4))
        }
        if s.pageCount > 1 {
            button(pagePrevRect, "‹  PREV", fill: s.page > 0 ? neutral : UIColor(white: 1, alpha: 0.04),
                   size: 24, radius: 22)
            button(pageNextRect, "NEXT  ›",
                   fill: s.page < s.pageCount - 1 ? neutral : UIColor(white: 1, alpha: 0.04),
                   size: 24, radius: 22)
            centered("\(s.page + 1) / \(s.pageCount)",
                     in: CGRect(x: pagePrevRect.maxX, y: pagePrevRect.minY,
                                width: pageNextRect.minX - pagePrevRect.maxX, height: 68),
                     font: monoFnt(25, .heavy), color: dim(0.6))
        }
    }

    static func drawSongPage(_ s: PanelSnap) {
        guard let c = s.selected else {
            centered("Pick a song", in: CGRect(x: 0, y: 260, width: texW, height: 60),
                     font: fnt(29, .semibold), color: dim(0.5))
            return
        }
        let art = CGRect(x: 36, y: 134, width: 118, height: 118)
        artwork(art, c)
        leftTruncated(c.title, in: CGRect(x: art.maxX + 22, y: 140, width: texW - art.maxX - 60, height: 46),
                      font: fnt(34, .black), color: .white)
        leftTruncated("Difficulty \(c.difficulty) of 5",
                      in: CGRect(x: art.maxX + 22, y: 190, width: 420, height: 30),
                      font: fnt(21, .semibold), color: songTint(c.title))

        let chipW = (texW - 72 - 24) / 3
        chip(CGRect(x: 36, y: 262, width: chipW, height: 74), "BARS", "\(c.bars)")
        chip(CGRect(x: 36 + chipW + 12, y: 262, width: chipW, height: 74), "NOTES", "\(c.notes)")
        chip(CGRect(x: 36 + 2 * (chipW + 12), y: 262, width: chipW, height: 74), "RANGE", c.range)

        button(songHandRect, s.state.hand.label.uppercased(), fill: neutral, size: 24)
        button(songTempoDownRect, "−", fill: neutral, size: 38, weight: .black)
        button(songTempoUpRect, "+", fill: neutral, size: 38, weight: .black)
        centered("\(s.state.tempoPercent)%",
                 in: CGRect(x: songTempoDownRect.maxX, y: songTempoDownRect.minY,
                            width: songTempoUpRect.minX - songTempoDownRect.maxX,
                            height: songTempoDownRect.height),
                 font: monoFnt(30, .heavy), color: .white)
        button(songWaitRect, s.state.waitMode ? "WAIT FOR ME" : "PLAY-ALONG",
               fill: s.state.waitMode ? green : accent, size: 23)
        button(startSongRect, "▶    START", fill: blue, size: 40, weight: .black, radius: 28)
    }

    static func drawPractice(_ s: PanelSnap) {
        let st = s.state
        // Nothing below this matters if the app cannot hear the piano, so it
        // takes the place of the stats rather than sitting politely beside
        // them.
        if let problem = st.micProblem {
            let r = CGRect(x: 36, y: 126, width: texW - 72, height: 56)
            red.withAlphaComponent(0.22).setFill()
            UIBezierPath(roundedRect: r, cornerRadius: 16).fill()
            red.setStroke()
            let b = UIBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), cornerRadius: 16)
            b.lineWidth = 2
            b.stroke()
            centered("⚠︎  " + problem, in: r, font: fnt(21, .heavy), color: .white)
        }
        // ── live stats, display only ────────────────────────────────────
        let cw = (texW - 72 - 36) / 4
        let chips: [(String, String, UIColor)] = [
            ("BAR", st.barCount > 0 ? "\(st.bar)/\(st.barCount)" : "—", .white),
            ("CORRECT", "\(st.correct)", green),
            ("MISSED", "\(st.missed)", st.missed > 0 ? amber : .white),
            ("STREAK", "\(st.streak)", st.streak >= 8 ? green : .white),
        ]
        if st.micProblem == nil {
            for (i, c) in chips.enumerated() {
                chip(CGRect(x: 36 + CGFloat(i) * (cw + 12), y: 126, width: cw, height: 56),
                     c.0, c.1, tint: c.2)
            }
        }

        // ── scrub ───────────────────────────────────────────────────────
        card(seekRect)
        let track = seekTrack
        let prog = CGFloat(min(1, max(0, st.progress)))
        let cl: (Float) -> CGFloat = { CGFloat(min(1, max(0, $0))) }
        if st.barCount > 0 {
            let step = max(4, (st.barCount / 12 + 1) * 4)
            dim(0.20).setFill()
            var b = step
            while b < st.barCount {
                let x = track.minX + track.width * CGFloat(b) / CGFloat(st.barCount)
                UIBezierPath(rect: CGRect(x: x - 1, y: track.minY - 13, width: 2, height: 10)).fill()
                b += step
            }
        }
        dim(0.14).setFill()
        UIBezierPath(roundedRect: track, cornerRadius: 13).fill()
        if st.loopOn {
            let a = track.minX + track.width * cl(st.loopFrom)
            let b = track.minX + track.width * cl(st.loopTo)
            let band = CGRect(x: a, y: track.minY - 7, width: max(6, b - a), height: track.height + 14)
            amber.withAlphaComponent(0.30).setFill()
            UIBezierPath(roundedRect: band, cornerRadius: 12).fill()
            amber.setFill()
            for x in [a, b] {
                UIBezierPath(roundedRect: CGRect(x: x - 3, y: band.minY, width: 6, height: band.height),
                             cornerRadius: 3).fill()
            }
        }
        blue.setFill()
        UIBezierPath(roundedRect: CGRect(x: track.minX, y: track.minY,
                                         width: track.width * prog, height: track.height),
                     cornerRadius: 13).fill()
        let hx = track.minX + track.width * prog
        UIColor.white.setFill()
        UIBezierPath(ovalIn: CGRect(x: hx - 15, y: track.midY - 15, width: 30, height: 30)).fill()
        UIColor(red: 0.04, green: 0.03, blue: 0.10, alpha: 1).setFill()
        UIBezierPath(ovalIn: CGRect(x: hx - 5, y: track.midY - 5, width: 10, height: 10)).fill()
        let caption = st.loopOn
            ? (st.loopLaps > 0
               ? "LOOP  bars \(st.loopFirstBar)–\(st.loopLastBar)   ·   \(st.loopLaps)× round"
               : "LOOP  bars \(st.loopFirstBar)–\(st.loopLastBar)")
            : "Tap anywhere on the bar to jump there"
        centered(caption, in: CGRect(x: track.minX, y: seekRect.maxY - 28, width: track.width, height: 26),
                 font: fnt(20, .semibold), color: st.loopOn ? amber : dim(0.5))

        // ── transport ───────────────────────────────────────────────────
        button(restartRect, "↺  START", fill: neutral, size: 26)
        button(playRect, st.isPlaying ? "❚❚  PAUSE" : "▶  PLAY",
               fill: st.isPlaying ? red : blue, size: 36, weight: .black, radius: 26)
        button(skipRect, "SKIP  ▸▸", fill: neutral, size: 26)

        // ── section ─────────────────────────────────────────────────────
        button(loopPhraseRect, "⟲  LOOP 4 BARS", fill: neutral, size: 23)
        button(loopARect, "SET  A", fill: neutral, size: 22)
        button(loopBRect, "SET  B", fill: neutral, size: 22)
        button(loopOnRect, st.loopOn ? "LOOP:  ON" : "LOOP:  OFF",
               fill: st.loopOn ? amber : neutral, size: 24, text: st.loopOn ? .black : .white)

        // ── tempo / mode / hands ────────────────────────────────────────
        button(tempoDownRect, "−", fill: neutral, size: 36, weight: .black)
        button(tempoUpRect, "+", fill: neutral, size: 36, weight: .black)
        centered("\(st.tempoPercent)%",
                 in: CGRect(x: tempoDownRect.maxX, y: tempoDownRect.minY,
                            width: tempoUpRect.minX - tempoDownRect.maxX, height: tempoDownRect.height),
                 font: monoFnt(30, .heavy), color: .white)
        button(waitRect, st.waitMode ? "WAIT FOR ME" : "PLAY-ALONG",
               fill: st.waitMode ? green : accent, size: 22)
        button(handRect, st.hand.label.uppercased(), fill: neutral, size: 22)
    }

    static func drawResults(_ s: PanelSnap) {
        let st = s.state
        centered(st.currentTitle.isEmpty ? "Practice" : st.currentTitle,
                 in: CGRect(x: 40, y: 128, width: texW - 80, height: 40),
                 font: fnt(28, .heavy), color: .white)

        let acc = st.accuracy
        let tint: UIColor = acc >= 0.9 ? green : (acc >= 0.7 ? amber : red)
        centered("\(Int((acc * 100).rounded()))%",
                 in: CGRect(x: 0, y: 172, width: texW, height: 96),
                 font: monoFnt(74, .black), color: tint)
        centered("ACCURACY", in: CGRect(x: 0, y: 262, width: texW, height: 28),
                 font: fnt(20, .heavy), color: dim(0.5))

        let cw = (texW - 72 - 36) / 4
        let chips: [(String, String, UIColor)] = [
            ("CORRECT", "\(st.correct)", green),
            ("WRONG", "\(st.wrong)", st.wrong > 0 ? red : .white),
            ("MISSED", "\(st.missed)", st.missed > 0 ? amber : .white),
            ("BEST RUN", "\(st.bestStreak)", .white),
        ]
        for (i, c) in chips.enumerated() {
            chip(CGRect(x: 36 + CGFloat(i) * (cw + 12), y: 306, width: cw, height: 78),
                 c.0, c.1, tint: c.2)
        }
        // The player only tracks |error|, so this is how far off the beat
        // the notes landed, not which side of it they landed on.
        centered(st.timingMs <= 0 ? "" : String(format: "Notes landed %.0f ms off the beat on average",
                                                st.timingMs),
                 in: CGRect(x: 0, y: 396, width: texW, height: 30),
                 font: fnt(21, .semibold), color: dim(0.55))

        button(againRect, "↺  AGAIN", fill: blue, size: 26, weight: .heavy, radius: 26)
        button(practiceWeakRect, "⟲  DRILL LAST 4 BARS", fill: amber, size: 21,
               weight: .heavy, text: .black, radius: 26)
        button(backToSongsRect, "SONGS", fill: neutral, size: 26, weight: .heavy, radius: 26)
    }

    static func drawView(_ s: PanelSnap) {
        drawSettingsTabs(s)
        let c = s.state.comfort
        leftTruncated("VIEW SIZE", in: CGRect(x: 36, y: viewDownRect.minY, width: 460, height: viewDownRect.height),
                      font: fnt(26, .heavy), color: .white)
        leftTruncated("LENS SPACING", in: CGRect(x: 36, y: lensDownRect.minY, width: 460, height: lensDownRect.height),
                      font: fnt(26, .heavy), color: .white)
        for (down, up, value) in [(viewDownRect, viewUpRect, "\(Int((c.viewScale * 100).rounded()))%"),
                                  (lensDownRect, lensUpRect, String(format: "%.1f mm", c.lensSpacingMM))] {
            button(down, "−", fill: neutral, size: 36, weight: .black)
            button(up, "+", fill: neutral, size: 36, weight: .black)
            centered(value, in: CGRect(x: down.maxX, y: down.minY,
                                       width: up.minX - down.maxX, height: down.height),
                     font: monoFnt(30, .heavy), color: .white)
        }
        button(smoothRect, c.motionSmoothing ? "SMOOTHING:  ON" : "SMOOTHING:  OFF",
               fill: c.motionSmoothing ? green : neutral, size: 24)
        button(stereoRect, c.stereoMode == .dual ? "RENDER:  DUAL" : "RENDER:  SINGLE (FAST)",
               fill: c.stereoMode == .dual ? neutral : accent, size: 24)
        button(handStyleRect, "HANDS:  \(c.handStyle.label)", fill: neutral, size: 22)
        button(frameRateRect, c.frameRate.label, fill: neutral, size: 22)
        button(comfortResetRect, "RESET VIEW", fill: neutral, size: 22)
        wrapped("Motion sick? Stare at a far edge and shake your head. The world swinging AGAINST "
                + "your turn means VIEW SIZE is too high; dragging WITH you means it is too low.",
                in: CGRect(x: 40, y: 528, width: texW - 80, height: 38), size: 19, align: .center, alpha: 0.6)
    }

    static func drawAccess(_ s: PanelSnap) {
        drawSettingsTabs(s)
        let a = s.state.access
        settingRow(textSizeRect, "TEXT SIZE", a.textSize.label, on: a.textSize != .normal)
        settingRow(contrastRect, "HIGH CONTRAST", a.highContrast ? "ON" : "OFF", on: a.highContrast)
        settingRow(dwellRect, "HOVER TO SELECT", a.dwell.label, on: a.dwell != .off)
        settingRow(cbRect, "COLOUR-BLIND SAFE", a.colorBlindSafe ? "ON" : "OFF", on: a.colorBlindSafe)
        button(accessResetRect, "RESET", fill: neutral, size: 24)
        wrapped("HOVER TO SELECT fires a control by resting on it, for when a pinch will not "
                + "register. Turn it OFF to require a pinch.",
                in: CGRect(x: 40, y: 528, width: texW - 80, height: 38), size: 19, align: .center)
    }

    static func drawAlign(_ s: PanelSnap) {
        drawSettingsTabs(s)
        let st = s.state
        centered(st.alignReadout, in: CGRect(x: 20, y: 200, width: texW - 40, height: 28),
                 font: monoFnt(21, .semibold), color: UIColor(red: 0.55, green: 0.95, blue: 1.0, alpha: 0.9))

        button(alignModeRect, "PUSH:  \(st.alignMode.label)", fill: accent, size: 23, radius: 18)
        let m = st.alignMode
        button(padUpRect, m.up, fill: neutral, size: 26, weight: .black)
        button(padLeftRect, m.left, fill: neutral, size: 26, weight: .black)
        button(padRightRect, m.right, fill: neutral, size: 26, weight: .black)
        button(padDownRect, m.down, fill: neutral, size: 26, weight: .black)

        button(mapRect, "⌖  MAP KEYS", fill: blue, size: 22)
        button(labelsRect, st.keyLabels ? "LABELS:  ON" : "LABELS:  OFF",
               fill: st.keyLabels ? green : neutral, size: 22)
        button(debugRect, st.debugOn ? "DEBUG:  ON" : "DEBUG:  OFF",
               fill: st.debugOn ? green : neutral, size: 22)
        button(alignResetRect, "RESET ALIGN", fill: neutral, size: 22)
        button(recordRect, st.recording
               ? String(format: "● REC  %d:%02d", st.recordSeconds / 60, st.recordSeconds % 60)
               : "◉  RECORD", fill: st.recording ? red : neutral, size: 22)
        button(calibRect, st.calibrating ? "STOP CALIB" : "CALIBRATE",
               fill: st.calibrating ? green : neutral, size: 22)
    }
}

/// What the ALIGN pad is pushing. Twelve nudge buttons became one pad and a
/// mode, which is both fewer targets and a better match for the job: you are
/// moving a thing in space, not editing six numbers.
enum AlignMode: Int, CaseIterable {
    case nudge, keys, shape

    var label: String {
        switch self {
        case .nudge: return "POSITION"
        case .keys:  return "WHOLE KEYS"
        case .shape: return "SIZE & TURN"
        }
    }
    var up: String {
        switch self {
        case .nudge: return "▲ AWAY"
        case .keys:  return "▲ UP"
        case .shape: return "↺ TURN"
        }
    }
    var down: String {
        switch self {
        case .nudge: return "▼ NEAR"
        case .keys:  return "▼ DOWN"
        case .shape: return "↻ TURN"
        }
    }
    var left: String {
        switch self {
        case .nudge: return "◀ 5 mm"
        case .keys:  return "◀◀ KEY"
        case .shape: return "− WIDE"
        }
    }
    var right: String {
        switch self {
        case .nudge: return "5 mm ▶"
        case .keys:  return "KEY ▶▶"
        case .shape: return "+ WIDE"
        }
    }
    var next: AlignMode {
        switch self {
        case .nudge: return .keys
        case .keys:  return .shape
        case .shape: return .nudge
        }
    }
}
