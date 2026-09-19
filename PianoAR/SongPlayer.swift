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

    private(set) var bpm: Double = 120
    private(set) var tempoScale: Double = 1.0
    private(set) var practiceHand: PracticeHand = .both
    private(set) var waitMode = true

    private var startHostTime: Double = 0
    private let countInBeats = 2.0
    private let earlySeconds = 0.35      // play-along: how early a press may count
    private let lateSeconds  = 0.40      // play-along: how late before it's a miss

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
        resetProgress()
        isPlaying = false
        feedback = "Ready: \(song.title ?? "Practice")"
    }

    func play() {
        guard song != nil else { return }
        resetProgress()
        startHostTime = CACurrentMediaTime() + countInBeats * 60.0 / effectiveBPM
        isPlaying = true
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
            let pending = g.requiredKeys.subtracting(acceptedKeys)
            if pending.isEmpty, raw >= g.startBeat {
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
        if groupIndex >= groups.count, !groups.isEmpty { finish() }
        else if changed, feedback.hasPrefix("Get ready") { feedback = "" }
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
        if !waitMode,
           rawBeat(at: CACurrentMediaTime()) < g.startBeat - earlySeconds * effectiveBPM / 60.0 {
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

    func registerPress(keyIndex: Int, noteName: String) -> PracticePressResult {
        guard isPlaying, !isComplete, groupIndex < groups.count else { return .ignored }
        let g = groups[groupIndex]
        let now = CACurrentMediaTime()
        let raw = rawBeat(at: now)
        if !waitMode, raw < g.startBeat - earlySeconds * effectiveBPM / 60.0 { return .ignored }

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

        if g.requiredKeys.isSubset(of: acceptedKeys) {
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
            feedback: feedback,
            tempoPercent: Int((tempoScale * 100).rounded()),
            hand: practiceHand,
            waitMode: waitMode
        )
    }

    // MARK: - Private

    private func rawBeat(at time: Double) -> Double {
        (time - startHostTime) * effectiveBPM / 60.0
    }

    private func rebuildGroups() {
        var out: [NoteGroup] = []
        var i = 0
        while i < notes.count {
            let start = notes[i].startBeat
            var items: [(note: SongNote, keyIndex: Int?)] = []
            while i < notes.count, abs(notes[i].startBeat - start) < 0.001 {
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
        acceptedKeys.removeAll()
        groupSerial &+= 1
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
