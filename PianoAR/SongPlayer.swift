import Foundation
import Combine
import QuartzCore

enum PracticePressResult {
    case ignored
    case correct(expectedKeyIndex: Int, noteName: String)
    case wrong(playedKeyIndex: Int, playedName: String, expectedKeyIndex: Int, expectedName: String)
}

enum PracticeHand: String, CaseIterable {
    case both, right, left

    var label: String {
        switch self {
        case .both:  return "BOTH HANDS"
        case .right: return "RIGHT HAND"
        case .left:  return "LEFT HAND"
        }
    }

    var next: PracticeHand {
        switch self {
        case .both:  return .right
        case .right: return .left
        case .left:  return .both
        }
    }
}

struct PracticeStats {
    var accepted = 0
    var mistakes = 0
    var missed = 0
    var streak = 0
    var bestStreak = 0
    var timingSamples = 0
    var totalAbsTimingMs = 0.0
    var lastTimingMs = 0.0

    var accuracy: Double {
        let total = accepted + mistakes + missed
        return total == 0 ? 1 : Double(accepted) / Double(total)
    }
    var averageTimingMs: Double {
        timingSamples == 0 ? 0 : totalAbsTimingMs / Double(timingSamples)
    }
}

/// Notes that start together (a chord, or both hands at once).
struct NoteGroup {
    let startBeat: Double
    let items: [(note: SongNote, keyIndex: Int?)]
    let allKeys: Set<Int>
    var requiredKeys: Set<Int>   // what the player must press (hand selection applied)
}

/// One key cue for the highway / key highlights.
struct KeyCue {
    let keyIndex: Int
    let isLeft: Bool
    let required: Bool
}

/// Render-thread snapshot for the HUD.
struct PracticeHUD: Equatable {
    let title: String
    let isPlaying: Bool
    let isComplete: Bool
    let progress: Float
    let accepted: Int
    let mistakes: Int
    let missed: Int
    let streak: Int
    let bestStreak: Int
    let accuracyPercent: Int
    let averageTimingMs: Int
    let prompt: String
    let feedback: String
    let tempoPercent: Int
    let hand: PracticeHand
    let waitMode: Bool
    /// 0 = fine, 1 = slow, 2 = stuck. See SongPlayer.struggle.
    let struggle: Int
}

/// Song clock + practice logic.
///
/// **Wait mode** (default): the highway stops at the next note group until
/// every required key of it has been played — the classic learning mode.
/// **Play-along**: time keeps flowing; groups not played within a short
/// window after their beat are counted as missed.
///
/// Mutated from both the main thread (menu actions) and the SceneKit render
/// thread (press registration, per-frame tick) — same trade-off as before:
/// plain stored properties, UI strings handed to main asynchronously.
final class SongPlayer: ObservableObject {
    private(set) var isPlaying = false
    private(set) var isComplete = false
    private(set) var feedback = ""

    private(set) var song: Song?
    private(set) var notes: [SongNote] = []
    private(set) var groups: [NoteGroup] = []
    private(set) var groupIndex = 0
    /// Changes whenever the current group changes (press detector uses it so
    /// one strike can't satisfy two consecutive identical chords).
    private(set) var groupSerial = 0
    private(set) var acceptedKeys: Set<Int> = []
    private(set) var stats = PracticeStats()

    /// Section practice. `loopTo` is inclusive, both are group indices.
    ///
    /// The whole point of practising is repeating the eight bars you cannot
    /// play yet, and until now the only way to reach bar 40 was to play the
    /// thirty-nine before it.
    private(set) var loopEnabled = false
    private(set) var loopFrom = 0
    private(set) var loopTo   = 0
    /// Times round the loop - shown so you can see the repetition happening.
    private(set) var loopLaps = 0

    private(set) var bpm: Double = 120
    private(set) var tempoScale: Double = 1.0
    private(set) var practiceHand: PracticeHand = .both
    private(set) var waitMode = true

    private var startHostTime: Double = 0
    private let countInBeats = 2.0
    private let earlySeconds = 0.35      // how early a press may count
    private let lateSeconds  = 0.40      // play-along: how late before it's a miss

    /// When the current group came up, and how long a player is left waiting
    /// before the app admits it might be the one at fault.
    private var groupEnteredAt: TimeInterval = 0
    /// Groups matched by notes that ran ahead of the current one. Two in a
    /// row are needed before the song will skip forward (see registerPress).
    private var aheadRun: [Int] = []
    // Measured on a real session: stalls ran 10-18 s while the player kept
    // trying. Four seconds was too long to wait before helping.
    private let slowAfter:  TimeInterval = 2.5
    private let stuckAfter: TimeInterval = 6

    /// 0 = fine. 1 = this is taking a while: say what the microphone can
    /// hear, so the player knows whether to play louder or fix the mount.
    /// 2 = stuck: relax the verdict for the expected keys only, and point at
    /// SKIP. Never auto-advances — being moved past a note you never played
    /// teaches nothing — but the way out is always one tap away and visible.
    var struggle: Int {
        guard isPlaying, !isComplete, waitMode, groupEnteredAt > 0 else { return 0 }
        let held = CACurrentMediaTime() - groupEnteredAt
        if held >= stuckAfter { return 2 }
        if held >= slowAfter { return 1 }
        return 0
    }

    private let midiToKeyIndex: [Int: Int] = Dictionary(
        uniqueKeysWithValues: KeyboardLayout.keys.map { ($0.midiNote, $0.index) }
    )

    private var effectiveBPM: Double { bpm * tempoScale }

    // MARK: - Control (main thread)

    func load(_ song: Song) {
        self.song = song
        notes = song.notes.sorted {
            if $0.startBeat == $1.startBeat { return ($0.midiNote ?? 0) < ($1.midiNote ?? 0) }
            return $0.startBeat < $1.startBeat
        }
        bpm = song.bpm
        rebuildGroups()
        // Deliberately left empty rather than spanning the song: an unset
        // loop is what lets one press of LOOP mean "repeat the phrase I am
        // in" instead of "repeat everything".
        loopEnabled = false
        loopFrom = 0
        loopTo = 0
        loopLaps = 0
        resetProgress()
        isPlaying = false
        feedback = "Ready: \(song.title ?? "Practice")"
    }

    func play() {
        guard song != nil else { return }
        resetProgress()
        // With a loop armed, "start" means the start of the section being
        // practised. Anything else would throw you back to bar 1 every time.
        if loopEnabled, !groups.isEmpty {
            groupIndex = min(groups.count - 1, max(0, loopFrom))
            groupSerial &+= 1
        }
        loopLaps = 0
        let now = CACurrentMediaTime()
        let lead = countInBeats * 60.0 / effectiveBPM
        let offset = groups.isEmpty ? 0 : groups[groupIndex].startBeat * 60.0 / effectiveBPM
        startHostTime = now + lead - offset
        isPlaying = true
        groupEnteredAt = now + lead
        feedback = "Get ready"
    }

    func stop() {
        isPlaying = false
        feedback = "Paused"
    }

    func restart() {
        guard song != nil else { return }
        play()
    }

    /// Manual skip: a missed detection must never freeze the song in wait
    /// mode. Counts the group's unplayed notes as missed.
    func skipGroup() {
        guard isPlaying, !isComplete, groupIndex < groups.count else { return }
        let g = groups[groupIndex]
        stats.missed += g.requiredKeys.subtracting(acceptedKeys).count
        stats.streak = 0
        if waitMode { startHostTime = CACurrentMediaTime() - g.startBeat * 60.0 / effectiveBPM }
        advance()
        if groupIndex >= groups.count { finish() } else { feedback = "Skipped" }
    }

    /// 0.4× … 1.5×, applied without a jump in the song position.
    func setTempo(scale: Double) {
        let now = CACurrentMediaTime()
        let beat = rawBeat(at: now)
        tempoScale = min(1.5, max(0.4, (scale * 20).rounded() / 20))
        if isPlaying { startHostTime = now - beat * 60.0 / effectiveBPM }
    }

    func setHand(_ hand: PracticeHand) {
        practiceHand = hand
        rebuildRequired()
    }

    func setWaitMode(_ on: Bool) {
        guard on != waitMode else { return }
        let now = CACurrentMediaTime()
        let beat = beatNow()          // keep what's on screen where it is
        waitMode = on
        if isPlaying { startHostTime = now - beat * 60.0 / effectiveBPM }
    }

    // MARK: - Render-thread per-frame

    /// Flows through groups with nothing (left) to play — the other hand's
    /// notes in one-hand practice — and, in play-along mode, past groups
    /// whose window has gone by (their unplayed notes count as missed).
    func tick() {
        guard isPlaying, !isComplete else { return }
        let now = CACurrentMediaTime()
        let raw = rawBeat(at: now)
        let lateBeats = lateSeconds * effectiveBPM / 60.0
        var changed = false
        while groupIndex < groups.count {
            let g = groups[groupIndex]
            let pending = requiredNow(of: g).subtracting(acceptedKeys)
            if isSatisfied(g), raw >= g.startBeat {
                advance()
                changed = true
                continue
            }
            if !waitMode, raw > g.startBeat + lateBeats {
                stats.missed += pending.count
                stats.streak = 0
                feedback = "Missed \(names(of: pending, in: g))"
                advance()
                changed = true
                continue
            }
            break
        }
        if loopEnabled, !groups.isEmpty, groupIndex > loopTo {
            loopLaps += 1
            jump(toGroup: loopFrom)
            feedback = loopLabel() + "  ·  \(loopLaps)x"
        } else if groupIndex >= groups.count, !groups.isEmpty { finish() }
        else if changed, feedback.hasPrefix("Get ready") { feedback = "" }
    }

    // MARK: - Position, seeking and section practice

    /// No time signature travels with a Song, so bars are counted in fours.
    /// That is only ever used for *labelling* and for choosing how much to
    /// loop, never for timing, so a piece in three simply gets bars that do
    /// not line up with its own — the numbers stay monotonic and evenly
    /// spaced, which is all the scrub bar needs them to be.
    static let beatsPerBar = 4.0

    /// How far through the piece we are, 0...1 — for the scrub bar.
    var progressFraction: Double {
        groups.isEmpty ? 0 : Double(groupIndex) / Double(groups.count)
    }

    func bar(ofGroup i: Int) -> Int {
        guard !groups.isEmpty else { return 0 }
        let g = groups[min(groups.count - 1, max(0, i))]
        return Int(g.startBeat / Self.beatsPerBar)
    }

    /// 1-based, for display.
    var currentBar: Int { groups.isEmpty ? 0 : bar(ofGroup: groupIndex) + 1 }
    var barCount: Int {
        guard let last = groups.last else { return 0 }
        return Int(last.startBeat / Self.beatsPerBar) + 1
    }

    var loopFromFraction: Double {
        groups.isEmpty ? 0 : Double(loopFrom) / Double(groups.count)
    }
    var loopToFraction: Double {
        groups.isEmpty ? 0 : Double(loopTo + 1) / Double(groups.count)
    }
    var loopFirstBar: Int { bar(ofGroup: loopFrom) + 1 }
    var loopLastBar:  Int { bar(ofGroup: loopTo) + 1 }

    /// Jump to a point in the piece. Practising the middle of something
    /// should not mean playing the first two minutes of it again.
    func seek(toFraction f: Double) {
        guard !groups.isEmpty else { return }
        jump(toGroup: Int(Double(groups.count) * f))
        loopLaps = 0
        feedback = ""
    }

    /// Mark the playhead as the start of the practice loop. Dragging two
    /// handles with a hand-tracked ray is a fight; pressing a button at the
    /// place you already are is not.
    func setLoopStart() {
        guard !groups.isEmpty else { return }
        loopFrom = groupIndex
        if loopTo < loopFrom { loopTo = min(groups.count - 1, loopFrom + phraseGroups() - 1) }
        loopEnabled = true
        loopLaps = 0
        feedback = loopLabel()
    }

    func setLoopEnd() {
        guard !groups.isEmpty else { return }
        loopTo = groupIndex
        if loopFrom > loopTo { loopFrom = max(0, loopTo - phraseGroups() + 1) }
        loopEnabled = true
        loopLaps = 0
        feedback = loopLabel()
    }

    /// One tap for the common case: loop the four-bar phrase the playhead is
    /// sitting in, and start it from the top.
    func loopCurrentPhrase() {
        guard !groups.isEmpty else { return }
        let startBar = (bar(ofGroup: groupIndex) / 4) * 4
        let endBar   = startBar + 3
        loopFrom = groups.firstIndex { Int($0.startBeat / Self.beatsPerBar) >= startBar } ?? 0
        loopTo   = (groups.lastIndex { Int($0.startBeat / Self.beatsPerBar) <= endBar }) ?? (groups.count - 1)
        if loopTo < loopFrom { loopTo = loopFrom }
        loopEnabled = true
        loopLaps = 0
        jump(toGroup: loopFrom)
        feedback = loopLabel()
    }

    func toggleLoop() {
        guard !groups.isEmpty else { return }
        loopEnabled.toggle()
        loopLaps = 0
        if loopEnabled {
            if loopTo <= loopFrom { loopCurrentPhrase(); return }
            if groupIndex < loopFrom || groupIndex > loopTo { jump(toGroup: loopFrom) }
            feedback = loopLabel()
        } else {
            feedback = "Loop off"
        }
    }

    private func loopLabel() -> String { "Loop bars \(loopFirstBar)–\(loopLastBar)" }

    /// Roughly four bars' worth of groups, used when only one end of the
    /// loop has been set and the other has to be guessed.
    private func phraseGroups() -> Int {
        guard !groups.isEmpty else { return 1 }
        let span = 4.0 * Self.beatsPerBar
        let here = groups[min(groups.count - 1, max(0, groupIndex))].startBeat
        let n = groups.filter { $0.startBeat >= here && $0.startBeat < here + span }.count
        return max(1, n)
    }

    private func jump(toGroup i: Int) {
        guard !groups.isEmpty else { return }
        let idx = min(groups.count - 1, max(0, i))
        groupIndex   = idx
        acceptedKeys = []
        aheadRun     = []
        groupSerial &+= 1
        groupEnteredAt = CACurrentMediaTime()
        isComplete   = false
        startHostTime = CACurrentMediaTime() - groups[idx].startBeat * 60.0 / effectiveBPM
    }

    /// Tempo actually in force, for anything that needs to convert beats to
    /// seconds (the sheet's look-ahead).
    var effectiveBPMNow: Double { effectiveBPM }

    /// True when wait mode is holding the song on a group the player has not
    /// finished — i.e. the sheet is frozen rather than scrolling.
    var isWaitingNow: Bool {
        guard isPlaying, !isComplete, waitMode, groupIndex < groups.count else { return false }
        return !isSatisfied(groups[groupIndex])
    }

    /// Current song position in beats (render thread). In wait mode it holds
    /// at the next group until that group has been played.
    func beatNow() -> Double {
        guard isPlaying else { return 0 }
        let raw = rawBeat(at: CACurrentMediaTime())
        if waitMode, !isComplete, groupIndex < groups.count {
            return min(raw, groups[groupIndex].startBeat)
        }
        return raw
    }

    /// Keys of the current group still to be played.
    func pendingKeyIndicesNow() -> Set<Int> {
        guard isPlaying, !isComplete, groupIndex < groups.count else { return [] }
        let g = groups[groupIndex]
        // Nothing counts before the note is due. This used to be gated on
        // play-along only, so in wait mode any sound during the lead-in
        // (a chair, a cough, the first note of the count-off) could be
        // accepted as the opening note of the song.
        if rawBeat(at: CACurrentMediaTime()) < g.startBeat - earlySeconds * effectiveBPM / 60.0 {
            return []
        }
        return g.requiredKeys.subtracting(acceptedKeys)
    }

    /// Every key of the current group (incl. already-played / other hand).
    func groupKeyIndicesNow() -> Set<Int> {
        guard isPlaying, !isComplete, groupIndex < groups.count else { return [] }
        return groups[groupIndex].allKeys
    }

    /// Kept for older call sites.
    func expectedKeyIndicesNow() -> Set<Int> { pendingKeyIndicesNow() }

    /// Required keys of the next `count` groups after the current one —
    /// playing slightly ahead is not a mistake.
    func upcomingKeyIndices(count: Int = 2) -> Set<Int> {
        guard isPlaying, !isComplete, groupIndex + 1 < groups.count else { return [] }
        let end = min(groups.count, groupIndex + 1 + count)
        var keys = Set<Int>()
        for g in groups[(groupIndex + 1)..<end] { keys.formUnion(g.requiredKeys) }
        return keys
    }

    /// Start beat of the group being waited on / played right now.
    func currentGroupStartBeat() -> Double? {
        guard isPlaying, !isComplete, groupIndex < groups.count else { return nil }
        return groups[groupIndex].startBeat
    }

    /// Cues to light on the keys right now: the current group minus keys
    /// already played (other-hand notes included as non-required).
    func currentCues() -> [KeyCue] {
        guard isPlaying, !isComplete, groupIndex < groups.count else { return [] }
        let g = groups[groupIndex]
        return g.items.compactMap { item in
            guard let k = item.keyIndex, !acceptedKeys.contains(k) else { return nil }
            return KeyCue(keyIndex: k, isLeft: item.note.isLeft, required: g.requiredKeys.contains(k))
        }
    }

    func isRequired(_ note: SongNote) -> Bool {
        switch practiceHand {
        case .both:  return true
        case .right: return !note.isLeft
        case .left:  return note.isLeft
        }
    }

    /// `strikeTime`: when the key was actually struck (sound onsets arrive a
    /// little after the fact); used for the early/late timing stats.
    func registerPress(keyIndex: Int, noteName: String,
                       at strikeTime: TimeInterval? = nil) -> PracticePressResult {
        guard isPlaying, !isComplete, groupIndex < groups.count else { return .ignored }
        let g = groups[groupIndex]
        let now = CACurrentMediaTime()
        let raw = rawBeat(at: min(now, strikeTime ?? now))
        if !waitMode, raw < g.startBeat - earlySeconds * effectiveBPM / 60.0 { return .ignored }

        // Caught up. In wait mode the song holds on one group while the
        // player, who cannot hear the app, carries on with the piece — so a
        // missed note can cost ten seconds of playing into a wall.
        //
        // But one stray note is not evidence of having moved on, and acting
        // on one is what made the song teleport two steps ahead: Fur Elise
        // alternates E5 and D#5, so whenever the app fell a single note
        // behind, the very next thing played matched the *following* group
        // and it leapt forward again and again — measured at 7 and 11 jumps
        // in two recordings, skipping 8 and 19 notes. It now takes two notes
        // in a row that both fit the run ahead, after six seconds stuck.
        // Replayed offline against both recordings that is zero teleports,
        // and it still reaches further through the piece than jumping eagerly
        // did (87 % against 67 %).
        if waitMode, struggle >= 2, !g.allKeys.contains(keyIndex),
           let jump = upcomingGroupIndex(containing: keyIndex) {
            aheadRun.append(jump)
            if aheadRun.count < 2 { return .ignored }          // not yet convinced
            let target = aheadRun.min() ?? jump
            aheadRun = []
            let skipped = groups[groupIndex..<target]
                .reduce(0) { $0 + $1.requiredKeys.count }
            stats.missed += skipped
            stats.streak = 0
            groupIndex = target
            acceptedKeys = []
            groupSerial &+= 1
            groupEnteredAt = CACurrentMediaTime()
            feedback = "Caught up"
            return registerPress(keyIndex: keyIndex, noteName: noteName, at: strikeTime)
        }
        if g.allKeys.contains(keyIndex) { aheadRun = [] }

        guard g.allKeys.contains(keyIndex) else {
            stats.mistakes += 1
            stats.streak = 0
            let expected = names(of: g.requiredKeys.subtracting(acceptedKeys), in: g)
            feedback = "Try \(expected) again"
            return .wrong(playedKeyIndex: keyIndex, playedName: noteName,
                          expectedKeyIndex: g.requiredKeys.sorted().first ?? keyIndex,
                          expectedName: expected)
        }
        guard g.requiredKeys.contains(keyIndex), !acceptedKeys.contains(keyIndex) else {
            return .ignored
        }

        acceptedKeys.insert(keyIndex)
        stats.accepted += 1
        stats.streak += 1
        stats.bestStreak = max(stats.bestStreak, stats.streak)
        let timingMs = (raw - g.startBeat) * 60.0 / effectiveBPM * 1000.0
        stats.lastTimingMs = timingMs
        stats.totalAbsTimingMs += abs(timingMs)
        stats.timingSamples += 1
        let played = g.items.first { $0.keyIndex == keyIndex }?.note.key ?? noteName

        if requiredNow(of: g).isSubset(of: acceptedKeys) {
            // Wait mode restarts the clock from this group's beat, so an
            // early press pulls the song forward and a late one resumes it.
            if waitMode { startHostTime = now - g.startBeat * 60.0 / effectiveBPM }
            advance()
            if groupIndex >= groups.count { finish() } else { feedback = "Good \(played)" }
        } else {
            let remaining = names(of: g.requiredKeys.subtracting(acceptedKeys), in: g)
            feedback = "Good \(played) — add \(remaining)"
        }
        return .correct(expectedKeyIndex: keyIndex, noteName: played)
    }

    func hudSnapshot() -> PracticeHUD {
        let pending: String
        if isPlaying, !isComplete, groupIndex < groups.count {
            let g = groups[groupIndex]
            let keys = g.requiredKeys.subtracting(acceptedKeys)
            pending = keys.isEmpty ? "" : names(of: keys, in: g)
        } else {
            pending = ""
        }
        let s = stats
        return PracticeHUD(
            title: song?.title ?? "No song",
            isPlaying: isPlaying,
            isComplete: isComplete,
            progress: groups.isEmpty ? 0 : Float(groupIndex) / Float(groups.count),
            accepted: s.accepted, mistakes: s.mistakes, missed: s.missed,
            streak: s.streak, bestStreak: s.bestStreak,
            accuracyPercent: Int((s.accuracy * 100).rounded()),
            averageTimingMs: Int(s.averageTimingMs.rounded()),
            prompt: pending,
            feedback: hint(pending) ?? feedback,
            tempoPercent: Int((tempoScale * 100).rounded()),
            hand: practiceHand,
            waitMode: waitMode,
            struggle: struggle
        )
    }

    /// The nearest group just ahead of the current one that wants this key.
    /// Deliberately short-sighted: two groups, so a wrong note that happens
    /// to appear later in the piece cannot throw the song forward.
    private func upcomingGroupIndex(containing key: Int) -> Int? {
        let end = min(groups.count, groupIndex + 3)
        guard groupIndex + 1 < end else { return nil }
        for i in (groupIndex + 1)..<end where groups[i].requiredKeys.contains(key) {
            return i
        }
        return nil
    }

    /// The notes of a group that actually have to be heard.
    ///
    /// A phone microphone in a headset shell hears roughly three octaves of
    /// the piano well. Measured against a recording of every key played in
    /// order, the played note came out in the detector's top three 83-100 %
    /// of the time between C3 and B5, but only 27 % in the bottom octave and
    /// 52 % above C6. Requiring a note the microphone cannot hear does not
    /// make the app stricter, it makes it stuck — which is exactly what a
    /// left-hand bass note was doing to Fur Elise.
    ///
    /// So a group advances on the notes inside that range, and the rest are
    /// credited with it. The trade is deliberate and worth being honest
    /// about: the app is no longer checking the far ends of the keyboard, it
    /// is taking them on trust. A group made up entirely of such notes is
    /// still required, since there is nothing else to go on.
    private static let trustedLow = 27      // C3
    private static let trustedHigh = 62     // B5

    func requiredNow(of g: NoteGroup) -> Set<Int> {
        let trusted = g.requiredKeys.filter { $0 >= Self.trustedLow && $0 <= Self.trustedHigh }
        return trusted.isEmpty ? g.requiredKeys : Set(trusted)
    }

    /// How many of a group's notes have to be heard before it counts as
    /// played.
    ///
    /// Hearing one pitch out of a strike and hearing five out of the same
    /// strike are not the same problem. A wide chord puts the bass note's
    /// harmonics directly on top of the upper notes' fundamentals, so the
    /// detector has to get its ranked decision right five times over from one
    /// burst of sound — and at the ~85 % per-note rate measured in the
    /// trusted range, all five land only about 44 % of the time. Requiring
    /// every note does not make the app stricter, it makes it stop dead on
    /// chords the player got right.
    ///
    /// Ones and twos are still required in full: they are most of the music,
    /// they are the easy case for the detector, and that is where being
    /// honest about correctness matters. The slack only opens up where the
    /// measurement genuinely cannot keep up.
    func neededCount(of trusted: Set<Int>) -> Int {
        switch trusted.count {
        case 0, 1, 2: return trusted.count
        case 3:       return 2
        case 4:       return 3
        default:      return trusted.count - 2
        }
    }

    /// True when enough of the group has been heard to move on.
    func isSatisfied(_ g: NoteGroup) -> Bool {
        let trusted = requiredNow(of: g)
        return acceptedKeys.intersection(trusted).count >= neededCount(of: trusted)
    }

    /// What to say when a note is not coming through. Silence is the worst
    /// answer here: the player cannot tell "the app can't hear me" from
    /// "I am playing it wrong", and with no way to tell, people end up
    /// hammering a note that was right the first time.
    private func hint(_ pending: String) -> String? {
        guard !pending.isEmpty else { return nil }
        switch struggle {
        case 1:  return "Waiting for \(pending) — play it again, or carry on"
        case 2:  return "Still can't hear \(pending) — tap SKIP to move on"
        default: return nil
        }
    }

    // MARK: - Private

    private func rawBeat(at time: Double) -> Double {
        (time - startHostTime) * effectiveBPM / 60.0
    }

    /// How far apart two onsets can be and still be the same chord.
    ///
    /// It was 0.001 beats — half a millisecond — which is fine for a file
    /// written by a notation program and wrong for every file played by a
    /// person. A rolled or simply human chord lands its notes 20–40 ms apart,
    /// and at half a millisecond each of those became its own step you had to
    /// play on its own. 35 ms is comfortably inside that and comfortably
    /// outside a real thirty-second note, which is 73 ms even at 102 bpm.
    private var chordWindowBeats: Double { 0.035 * bpm / 60.0 }

    private func rebuildGroups() {
        var out: [NoteGroup] = []
        var i = 0
        let window = chordWindowBeats
        while i < notes.count {
            let start = notes[i].startBeat
            var items: [(note: SongNote, keyIndex: Int?)] = []
            while i < notes.count, notes[i].startBeat - start < window {
                let note = notes[i]
                items.append((note: note, keyIndex: note.midiNote.flatMap { midiToKeyIndex[$0] }))
                i += 1
            }
            let all = Set(items.compactMap { $0.keyIndex })
            out.append(NoteGroup(startBeat: start, items: items, allKeys: all, requiredKeys: all))
        }
        groups = out
        rebuildRequired()
    }

    private func rebuildRequired() {
        for gi in groups.indices {
            let required = groups[gi].items.compactMap { item -> Int? in
                isRequired(item.note) ? item.keyIndex : nil
            }
            groups[gi].requiredKeys = Set(required)
        }
    }

    private func resetProgress() {
        groupIndex = 0
        acceptedKeys.removeAll()
        stats = PracticeStats()
        isComplete = false
        groupSerial &+= 1
    }

    private func advance() {
        groupIndex += 1
        aheadRun = []
        acceptedKeys.removeAll()
        groupSerial &+= 1
        groupEnteredAt = CACurrentMediaTime()
    }

    private func finish() {
        guard !isComplete else { return }
        isComplete = true
        isPlaying = false
        feedback = "Song complete"
    }

    private func names(of keys: Set<Int>, in group: NoteGroup) -> String {
        let list = group.items.compactMap { item -> String? in
            guard let k = item.keyIndex, keys.contains(k) else { return nil }
            return item.note.key
        }
        return list.isEmpty ? "—" : list.joined(separator: " + ")
    }
}
