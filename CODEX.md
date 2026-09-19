# PianoAR — Architecture Handoff

> **Status as of 2026-09-19, branch `v2-overhaul` (v0.2).**
> Single-source handoff so a new AI session can continue without losing
> architectural decisions. The original brief is in CLAUDE.md; where this file
> and CLAUDE.md disagree (virtual mode, MIDI import, pitch use), this file
> reflects what was actually built.

---

## 1. What this app is

An iPhone 16 Pro app (native Swift, ARKit + SceneKit + Vision + AVAudioEngine)
worn inside a Cardboard-style shell (Denver VR-20) as a head-mounted AR piano
trainer for an **acoustic piano with no MIDI**. Camera passthrough, a world-
anchored overlay on the real keys, a note waterfall behind them, and press
detection from vision (LiDAR-lifted hand tracking) + microphone.

**No simulator, no local Mac.** Every change is a GitHub Actions build →
unsigned IPA → Sideloadly → real device. Be careful with syntax and types.

---

## 2. File inventory

| File | Purpose |
|------|---------|
| `PianoARApp.swift` | `@main` entry. |
| `ContentView.swift` | Owns all model objects, routes `MenuAction`s, song import (`onOpenURL`), brightness/idle timer. Detectors publish nothing per-frame so this view doesn't re-render constantly. |
| `ARPassthroughView.swift` | `UIViewRepresentable` + Coordinator: the per-frame loop (hands → song tick → menu → press detection → highway/HUD/debug), anchor → node, hint bar, 3-D hand overlay (fingertips / skeleton / hidden). |
| `StereoViewer.swift` | `StereoARContainer`: per-eye viewports centred on the lenses (lens spacing in mm × 460 ppi), sized by view scale (orthoscopic), dual ARSCNViews or one view + CAReplicatorLayer. |
| `MotionWarp.swift` | 120 Hz CADisplayLink: integrates CoreMotion gyro from the displayed frame's capture time to display time and shifts/rolls the AR view layers (rotational timewarp). Per-axis sign self-check vs ARKit. |
| `ComfortSettings.swift` | Persisted view scale, lens spacing, motion smoothing, stereo mode, hand style; `Locked<T>` helper. |
| `ARSessionModel.swift` | ARKit config: fastest 1920-wide format (60 fps), horizontal planes, scene depth. **No mesh reconstruction** (unused, heavy). |
| `CalibrationManager.swift` | Auto-detect (VNDetectRectanglesRequest + raycasts + dimension check), fingertip calibration (index tips on A0 and C8, hold 1.2 s), 4-corner taps. All produce `keyboard_calibrated`. |
| `KeyboardLayout.swift` | 88-key geometry constants. Key tops at y = whiteKeyHeight in keyboard-local space. |
| `KeyboardNode.swift` | Faint key-region overlay (`makeOverlay`). |
| `NoteHighway.swift` | Vertical waterfall behind the keys (tilted 15°), bars per hand colour, baked labels, beat lines, key cues on the key tops, press/miss flashes. |
| `HUDOverlay.swift` | `PracticeHUDOverlay` (status bar + results card atop the waterfall), `DebugPanelOverlay` (left of the keyboard). |
| `ARMenuOverlay.swift` | 4-tab AR tablet (LIBRARY/PRACTICE/COMFORT/SETUP), ray cursor + pinch/poke/dwell, grab-to-move, minimized PAUSE·SKIP·MENU pill while playing. |
| `HandTracker.swift` | Vision hand pose (≤640 px), LiDAR near-biased depth, adaptive EMA, occlusion reconstruction, duplicate-hand dedupe (median joint distance). |
| `PressDetector.swift` | Vision trajectory state machine + guided, chord-aware audio acceptance (see §4). Lock-protected debug lines. |
| `AudioPitchDetector.swift` | Mic ingest in 512-sample hops with host-time stamps, spectral-flux onsets, staged per-attack note verification, recent attacks/verifications snapshot. |
| `NoteVerifier.swift` | Per-attack "was this expected note just struck?" with explain-away (see §4). |
| `PianoTuning.swift` | What the *actual* piano is tuned to: Railsback stretch prior, learned per register from sure notes, narrows the partial search window, persisted. |
| `SessionRecorder.swift` | SETUP › RECORD: mic WAV + JSONL of every detection decision on one clock, into Files › PianoAR › Diagnostics. |
| `SongPlayer.swift` | Note groups, wait vs play-along, tempo, hand selection, skip, stats, HUD snapshot, `groupSerial`. |
| `SongModel.swift`, `BuiltInSongs.swift`, `MIDIFileImporter.swift`, `SongLibrary.swift` | Song format, built-ins, MIDI parser, imported songs (Documents/, Documents/Songs/). |
| `LabelFactory.swift` | Baked text textures (replaces SCNText). Prewarmed on main at launch. |
| `KeyTuning.swift` | Persisted per-key X/width offsets used by `PressDetector.findKey` (no UI currently). |

---

## 3. Scene graph & frames

```
keyboard_calibrated anchor node (origin = real KEY-TOP height)
└─ frameNode   position (nudge.x, −whiteKeyHeight, nudge.z)   ← unscaled
   ├─ content  scale (widthScale, 1, depthScale)               ← keyboardNode
   │  ├─ key overlay planes
   │  └─ NoteHighway (waterfall sheet + key cues + labels)
   ├─ ARMenuOverlay, PracticeHUDOverlay, DebugPanelOverlay     ← never stretched
```

**Height rule:** calibration raycasts land on the real key tops, so content is
shifted down by `whiteKeyHeight`. (v1 drew everything ~1.5 cm above the keys —
from a steep head-mounted view that parallax slid cues up to ~a key sideways.)

**World-space anchoring is sacred:** all overlay content is anchored, never
screen-space. The only head-locked element is the calibration hint bar.

Overlay materials: `writesToDepthBuffer = false`, `readsFromDepthBuffer =
false` (prevents z-fighting flicker; a solved bug — don't revert).

---

## 4. Press detection

**Vision (all modes):** per fingertip, regression-slope velocity + dip below
its own slow baseline; `idle → descending → pressed` on a real valley.

**Guided (song playing), per pending key of the current group** (v2.3).
**The sound decides.** While the mic is listening, no note is ever accepted
without audio evidence, and no note the audio is sure about is ever refused
for lack of a hand. Vision only breaks ties the sound cannot break.

1. Each recent audio attack (≤ 0.9 s old) is checked against every
   still-pending key. An attack from an earlier group carries over only if
   it accepted nothing *and* is within 0.3 s of the group changing — you may
   play slightly ahead of the app, you may not have the next note lit up by
   an onset belonging to the previous one.
   - verifier says **present** → accept, hand or no hand;
   - **unsure** (the key has fewer than two partials it doesn't share with
     something already sounding — in practice the upper note of an octave)
     + fingertip ON the key, a fresh valley within 2 keys, or its octave
     partner heard present → accept;
   - **absent** → never.
2. With the mic off or failed, vision valleys alone accept (fallback only).
3. Wrong-note flash only when nothing expected rose, one other key (not in
   the next groups) is clearly present, it isn't an octave/4th/5th relative,
   and a fingertip is on it.

**Why there is no "weak but maybe" band.** Up to v2.2 a weighted rise of
2–3.5 dB was reported `unsure`, and `unsure` + a hand anywhere near the key
was accepted. Between that and the duplicate onsets below, a note nobody
played could light up the moment the song advanced. `unsure` now means one
specific thing — masked, sound genuinely cannot decide — and everything
else is decided either way.

**NoteVerifier** (per attack, stages: 4096-pt @ +10 ms for keys ≥ C3, 8192-pt
@ +10 ms for bass, 4096-pt @ +60 ms for rolled chords): partial n at
n·f0·√(1+B·n²), ±35→±19 cents as the register's tuning is learned; must
be a real peak (no 25 dB-louder neighbour) and above the local background
(a partial buried in noise carries no information and does not vote);
partials shared with another expected chord note skipped; rise
r = 20·log10((after+NF)/(before+NF)); S = Σw·clip(r,0,15)/Σw,
w = (f0+52)/(n·f0+320). Present: S ≥ 3.5 dB & ≥ 2 rising partials, **or** ≥ 4
clean rising partials with S ≥ 2 (a soft note spreads a small rise over many
partials; a decaying or sympathetically resonating string does not).
**Explain-away:** for an expected key, if a non-expected key within ±24
semitones was clearly struck (its own unique partials present, S ≥ 4) and
shares partials with it, the expected key only stays present if its own
unique partials also rose (else absent, or unsure if it has none — octaves).
A v2.1 experiment with free-running per-key detectors on all 88 keys (no
explain-away, no hand gate) produced far too many false notes — don't repeat it.

**Onset peak-picking (v2.3).** An onset is the **local maximum** of the flux
curve, decided one hop (11 ms) late, and the flux must fall back below 40 %
of that peak before another onset counts — unless the next frame is 1.25×
louder, so repeated notes still register. Before this, one key stroke fired
two or three attacks (hammer transient, then the body of the note), and
every extra attack was another chance to accept a note nobody played.

**The expected chord is frozen at the onset.** Stages run 10–60 ms later, by
which time accepting the note may have advanced the song; reading the chord
live meant judging the sound of the note just played against the note not
yet played.

**PianoTuning** (v2.3): no real piano is at A4 = 440.000, and every one is
stretch-tuned — bass flat, treble sharp, ±30 cents at the ends (Railsback).
A fixed ±35-cent window is therefore too wide in the middle, where it lets a
neighbour's partial in, and too narrow at the ends, where the real partial
has moved further. Starts from the average stretch curve, learns the real one
per register (8 bands of 11 keys) from the median residual of partials 1–2 of
notes the verifier is sure about, with sub-bin parabolic peak interpolation,
narrows the window as it settles, and persists to UserDefaults. Read once per
strike via `snapshot()` — never per partial, this runs on the audio thread.

**Raw microphone.** `.measurement` mode, built-in mic selected explicitly,
voice processing off, omnidirectional pattern requested. Not cosmetic: every
verdict here is "did these partials get louder than they were 40 ms ago", and
AGC pulls a loud note down and a quiet room up — exactly that quantity.
Cardioid/stereo are multi-mic beamformers, i.e. more DSP, not microphones.

**Audio timing:** iOS taps deliver ~100 ms buffers regardless of the request;
ingest walks them in 512-sample hops and stamps onsets with
`AVAudioTime.seconds(forHostTime:)` (same clock as CACurrentMediaTime / the
render loop). Onset *timestamps* are therefore accurate regardless of buffer
size — only the "turns green" lag suffers.

**SessionRecorder** (SETUP › RECORD): mic to WAV + every decision to JSONL
(`expect` / `attack` / `verify` / `accept`) on one clock, into
Files › PianoAR › Diagnostics. 240 s cap. Thresholds cannot be tuned against
a piano nobody can hear; this is how a real session gets replayed offline.

---

## 5. Tuning parameters

| Parameter | File | Default | Effect |
|---|---|---|---|
| `minRMS`, `minFluxScore`, ambient ratios, `minAttackInterval` | AudioPitchDetector | 0.0010, 0.18, 2.5, 0.09 s | Onset sensitivity (v2.2: more sensitive than v2). |
| `presentDB` | NoteVerifier | 3.5 dB | Per-note verdict threshold. |
| `partialRiseDB`, `partialSNRDB` | NoteVerifier | 3, 6 dB | What counts as one rising partial. |
| `handReachKeys` | PressDetector | 6 keys | Hand-near radius (debug readout only now). |
| `strikeWindow`, `earlyPlayWindow` | PressDetector | 0.9 s, 0.3 s | How long one onset stays usable; how far ahead of the app you may play. |
| `defaultViewScale` | ComfortSettings | 0.66 | Eye image height / screen height (orthoscopic start). |
| `defaultLensSpacingMM` | ComfortSettings | 63 | Distance between eye image centres. |

---

## 6. Comfort (motion sickness) — why things are the way they are

- **Orthoscopic scale:** screen px per camera px = 18.11 px/mm · D_eff / fx.
  ~42 mm effective lens distance, fx ≈ 1366 → 0.557 → 0.66 of screen height.
  v1 filled each half-screen (~1.5× magnified): world swung against head turns.
- **Lens alignment:** v1 eye centres were 72.7 mm apart → 12–17° forced
  divergence. Now centred at ±lensSpacing/2.
- **Latency:** ARKit is 60 fps max (no 120 fps capture exists). MotionWarp
  re-projects at 120 Hz from the gyro (needs `CADisableMinimumFrameDurationOnPhone`).
- **Not done yet:** lens distortion pre-correction (Cardboard k1/k2 barrel
  shader) and a full Metal compositor with homography warp.

---

## 7. Build & deploy

1. Push; run **Build unsigned IPA** (`gh workflow run build.yml --ref <branch>`; `main` pushes build automatically).
2. `gh run download <id> -n PianoAR-unsigned-ipa`.
3. Sideloadly → iPhone. Free Apple ID: 7-day expiry, 3 apps, 10 App IDs / week.

---

## 8. Known gaps / next steps

1. **Tune against a real recording.** SETUP › RECORD now produces
   WAV + JSONL on one clock. Replay it offline, line every `accept` up against
   what was actually played, and set `presentDB` / the rising-partial counts
   per register from data instead of from argument. This is the top item —
   everything below is guesswork until it is done.
2. `AVAudioSinkNode` instead of `installTap`: ~90 ms off the strike→green
   lag on every path (tap buffers are ~100 ms despite a 10.7 ms request).
   Biggest single latency win available. Onset *timestamps* are unaffected.
3. **Second opinion on `unsure` only.** Spotify's Basic Pitch ships a
   ready-made Core ML model (269 KB, Apache-2.0, no conversion and no Mac
   needed — XcodeGen already handles `.mlpackage`). Read as a posteriorgram
   at the expected key rows around a known onset, never as a transcriber: its
   blind piano note-F1 is only ~71 %, and a blind 88-key transcriber is
   exactly the v2.1 failure. Needs ~175 ms of post-onset audio.
4. **Domain shift is real and measured.** Mobile-AMT (EUSIPCO 2024) on
   IDMT-PIANO-MM — 9 pieces × 8 rooms × 5 phones/tablets — shows studio-trained
   piano transcription falling from 96.3 to **78.8** note-F1 on a phone in a
   room (σ 14.2: some room/piano/mic combinations fail outright). Augmentation
   recovers it to 92.9, with RIR convolution the single biggest term. Read as:
   do not trust any published accuracy figure for this setup, and keep the
   score-informed framing that makes the problem tractable.
5. **The headset shell is an acoustic problem nobody has measured.** A
   Cardboard-style cavity of 50–500 cm³ with a small port resonates at roughly
   380–670 Hz — squarely on middle C to C5 — with standing-wave modes up to
   ~3 kHz. A phone's own mic chamber is deliberately tuned to 9–10 kHz to stay
   out of the voice band; an ad-hoc shell pocket is not. Rise-based detection
   is largely immune (a fixed resonance colours before and after alike), but
   give the mic port an open path rather than a sealed pocket, and foam over
   it is nearly free (<2.5 dB at 20 kHz) while buying 15–27 dB against breath.
   No published measurement of this exists — it would have to be measured.
6. Log verifier S per register during play and tune thresholds per register.
7. Lens-distortion correction (Cardboard k1/k2 barrel shader); Metal
   compositor with homography warp.
8. Loops/bookmarks, per-hand results, finger numbers on bars.
