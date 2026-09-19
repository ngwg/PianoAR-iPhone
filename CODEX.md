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
| `NoteTracker.swift` | Per-key note onset detection on all 88 keys every hop (see §4); `SpectrumAnalyzer`. |
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

**Sound decides (v2.1):** while the mic is on, notes are accepted from the
sound alone; hand position plays no part (vision only if the mic is off).

**NoteTracker** (`NoteTracker.swift`, every 512-sample hop, all 88 keys):
each key follows its own partials n·f0·√(1+B·n²) (±35 cents) in a 4096-pt
spectrum (8192-pt below 130 Hz). A partial counts only if it is a local peak
≥ 6 dB above the mean of ±3–12 bins around it (hammer thumps lift everything
and fail). Score = Klapuri-weighted mean of per-partial level increases over
a 3-hop lag (5 for bass), clipped to 0–15 dB. Onset = local max of the score
≥ 2.5 dB (2.0 bass) for keys the song expects, ≥ 4 dB otherwise, with ≥ 2
rising partials (1 above 1 kHz) and a 70 ms refractory. Partials shared by
two expected keys are skipped; unexpected octave/twelfth ghosts dropped.

**Acceptance** (`PressDetector.soundEvents`): each pending key of the current
group takes the first unused onset of that key since 0.6 s before the group
became current; every onset is used once (repeated notes need a new strike).
Wrong note = an unused onset ≥ 5 dB, ≤ 2 semitones from an expected key, not
in the next groups, with no expected key struck within 120 ms. Free play:
every onset ≥ 4 dB flashes its key.

**Audio timing:** iOS taps deliver ~100 ms buffers regardless of the request;
ingest walks them in 512-sample hops and stamps onsets with
`AVAudioTime.seconds(forHostTime:)` (same clock as CACurrentMediaTime / the
render loop).

---

## 5. Tuning parameters

| Parameter | File | Default | Effect |
|---|---|---|---|
| `minRMS`, `minFluxScore` | AudioPitchDetector | 0.0015, 0.24 | Onset gates. Lower for soft playing / quiet rooms. |
| `ambientRMSRatio`, `ambientFluxRatio` | AudioPitchDetector | 3.0 | Onset must exceed ambient by this factor. |
| `expectedThreshold` / `otherThreshold` | NoteTracker | 2.5 / 4.0 dB | Onset score needed for expected / other keys. Lower if notes are missed, raise if extra notes appear. |
| `minProminence` | NoteTracker | 6 dB | How far a partial must stand above its surroundings. |
| `earlyWindow` | PressDetector | 0.6 s | How early a strike may come before its note is current. |
| `wrongStrength` | PressDetector | 5 dB | Strength needed to call a note wrong. |
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

1. **On-device validation of v2** — especially MotionWarp sign/feel, replicated
   stereo mode, fingertip calibration offsets, verifier thresholds on the real piano.
2. Log verifier S/K per register during play and tune thresholds per register.
3. `AVAudioSinkNode` instead of `installTap` for ~5 ms onset latency (tap
   buffers are ~100 ms).
4. Lens-distortion correction; sound-check step (tuning offset, inharmonicity fit).
5. Loops/bookmarks, per-hand results, finger numbers on bars.
