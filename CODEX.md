# PianoAR — Codex Handoff Document

> **Status as of 2026-06-28, commit `860bda4`.**
> This file is the single-source handoff so a new AI session can continue
> without losing architectural decisions made in prior sessions.

---

## 1. What this app is

An iPhone 16 Pro app (native Swift, ARKit + SceneKit + Vision) that functions as
an AR piano trainer worn on the head inside a Google-Cardboard-style plastic lens
shell. Camera passthrough fills the screen; ARKit anchors a virtual 88-key
keyboard overlay onto a real surface (or places a fully virtual one). Falling
notes guide practice. Hand tracking + audio detect key presses.

**No MIDI input, ever.** The piano is acoustic with no MIDI-out. Every press
detection signal is vision (depth + trajectory) or audio (onset + pitch hints).
This is the hard constraint that drives most architectural choices.

**iOS simulation is impossible on Windows.** All testing requires GitHub Actions
CI build → download `.ipa` → Sideloadly → real iPhone 16 Pro. Xcode and iOS
Simulator do not run on Windows.

---

## 2. File inventory

| File | Purpose |
|------|---------|
| `PianoAR/PianoARApp.swift` | `@main` SwiftUI entry point — launches `ContentView` |
| `PianoAR/ContentView.swift` | Root SwiftUI view. Left-side VR HUD panel + AR view. Has setup mode and VR mode toggle. All state objects live here. |
| `PianoAR/ARPassthroughView.swift` | `UIViewRepresentable` wrapping `ARSCNView`. Coordinator drives the per-frame render loop: hand tracking → gesture detection → press detection → highway update. |
| `PianoAR/ARSessionModel.swift` | `ObservableObject` wrapping `ARSession`. Publishes tracking state + LiDAR availability. |
| `PianoAR/PlacementManager.swift` | Virtual-piano mode: detects horizontal ARKit planes, places `keyboard` anchor on tap. Derives keyboard orientation from camera-to-hit vector (not raw ARKit transform). |
| `PianoAR/CalibrationManager.swift` | Real-piano mode: collects 4 corner taps, raycasts each to world 3D, computes world-up homography, places `keyboard_calibrated` anchor. |
| `PianoAR/KeyboardLayout.swift` | Single source of truth for all 88-key geometry constants (key widths, depths, heights, MIDI note numbers, black/white layout). |
| `PianoAR/KeyboardNode.swift` | Builds the SCNNode tree for the 88-key virtual keyboard. `make()` for virtual mode, `makeOverlay()` for real-piano overlay. |
| `PianoAR/NoteHighway.swift` | Falling-note highway anchored to the keyboard node. Manages bar pool (48 nodes), key highlights, press flashes (green), miss flashes (red). |
| `PianoAR/HandTracker.swift` | Wraps `VNDetectHumanHandPoseRequest`. Throttled to 15-30fps. Lifts 2D landmarks to 3D using LiDAR depth (`ARFrame.smoothedSceneDepth`). Per-finger identity tracking + exponential smoothing across frames. |
| `PianoAR/Hand3DOverlay.swift` | (inside `ARPassthroughView.swift`) 3D sphere+cylinder hand skeleton anchored in world space. `readsFromDepthBuffer = false` to prevent z-fighting with key geometry. |
| `PianoAR/PressDetector.swift` | Two detection paths: **guided** (audio-primary — see §4) and **non-guided** (depth + trajectory state machine). |
| `PianoAR/AudioPitchDetector.swift` | Microphone onset detection (spectral flux, 3-band weighted, 2048-sample FFT via vDSP/Accelerate). Publishes `PitchSnapshot` with attack onset + active note hints. |
| `PianoAR/GestureDetector.swift` | Detects pinch (thumb-tip to index-tip < 30 mm) from `HandTracker.HandResult`. Returns `PinchEvent` with world-space midpoint. 550 ms debounce per hand. |
| `PianoAR/ARMenuOverlay.swift` | 3 floating SCNBox buttons above the keyboard (▶Play, ↺Restart, ▸▸Next). Hover glow + pinch-to-activate. Returned `MenuAction` is dispatched to `ContentView.handleMenuAction`. |
| `PianoAR/SongPlayer.swift` | Loads `Song`, runs beat clock, exposes `expectedKeyIndicesNow() → Set<Int>` and `expectedKeyIndexNow() → Int`. Accepts press reports via `registerPress(keyIndex:noteName:) → PracticePressResult`. |
| `PianoAR/SongModel.swift` | `Song` struct with JSON decode from custom format (`bpm`, `notes` array with `key`, `startBeat`, `durationBeats`, `isLeft`). |
| `PianoAR/MIDIFileImporter.swift` | Parses standard MIDI files into `Song`. Also has `loadBundled(named:title:)` for the built-in practice file. |
| `PianoAR/KeyTuning.swift` | Per-key X offset and width-extra adjustments. Used by `PressDetector.findKey()` to compensate for calibration drift. `panelVisible` toggles the tuning UI. |
| `PianoAR/right_hand_practice.json` | Built-in practice song (custom JSON format). |
| `PianoAR/right_hand_practice.mid` | Built-in practice song (standard MIDI). |
| `project.yml` | XcodeGen project definition. Auto-includes all `.swift` files and resources. Never edit `.xcodeproj` — it's regenerated in CI. |
| `.github/workflows/build.yml` | GitHub Actions CI: `macos-latest`, XcodeGen, `xcodebuild`, unsigned IPA artifact. |

---

## 3. Architecture overview

```
ContentView (SwiftUI)
│
├── ARPassthroughView (UIViewRepresentable)
│   └── Coordinator (ARSCNViewDelegate)
│       ├── HandTracker.maybeProcess(frame)     ← throttled Vision inference
│       ├── GestureDetector.update(hands, time) ← pinch events
│       ├── ARMenuOverlay.update(...)            ← button hover + activate
│       ├── PressDetector.update(...)            ← guided or non-guided
│       │   └── uses AudioPitchDetector.snapshot()
│       ├── SongPlayer.registerPress(...)        ← correct / wrong / ignored
│       └── NoteHighway.update(player)           ← falling notes + flashes
│
├── PlacementManager    ← virtual mode: ARKit plane → keyboard anchor
└── CalibrationManager  ← real mode: 4 corner taps → keyboard anchor

Both managers produce the same thing:
  ARAnchor(name: "keyboard" | "keyboard_calibrated", transform: ...)
  → renderer(nodeFor:) builds KeyboardNode + NoteHighway + ARMenuOverlay
```

**World-space anchoring rule (critical):** The keyboard overlay is a child of
the ARAnchor node, not screen-space overlay. ARKit re-projects the anchor every
frame using the live camera transform. If the overlay were screen-space, it would
drift on any head movement. Do not break this invariant.

---

## 4. Press detection approach (guided mode)

Guided mode = a song is active and we know which key(s) to expect.

Since Vision X-position has ≥1 cm error on 23.5 mm keys, we do NOT identify
keys from fingertip X position. The song already knows which key to play. We
only need to confirm "did the user play something on the piano right now?"

**Signal pipeline:**
```
1. AudioPitchDetector publishes PitchSnapshot.attack
   - onset.confidence >= 0.28  (guidedMinAttackConf)
   - |time - attack.timestamp| <= 0.22 s  (guidedAttackWindow)
   - attack.timestamp > lastGuidedAttackTime  (no duplicate)

2. Loose keyboard presence check (anyFingerInKeyboardArea):
   - Y in [-0.06, 0.10] m  (above/below key surface, not strict)
   - |X| < totalWidth × 0.55  (roughly over the keyboard)
   - |Z| < whiteKeyDepth/2 + 0.040  (with extra margin)

3. Pitch score (bestPitchScore):
   - FFT hints within ±3 semitones of expected key
   - Penalty: d=0→1.0, d=1→0.75, d=2→0.50, d=3→0.30
   - Score = max(hint.magnitude × penalty)

4. Confidence = onset×0.55 + pitchScore×0.30 + fingerPresent×0.15
   - Reject if < 0.30
   - Reject if pitch data present but pitchScore < 0.07 (contradiction)

5. If passes → emit PressEvent for each expectedKeyIndex
   → SongPlayer.registerPress() → .correct / .wrong / .ignored
   → NoteHighway flash green (correct) or red (wrong)
```

**Non-guided mode** uses a depth+trajectory state machine:
`idle → descending (vel < −1mm/frame, depth < 25mm) → pressed (depth < −8mm + deceleration check) → idle`

---

## 5. Tuning parameters

All in `PressDetector.swift` lines ~26–36 and `AudioPitchDetector.swift` lines ~47–50:

| Parameter | File | Default | Effect |
|-----------|------|---------|--------|
| `guidedMinAttackConf` | PressDetector | 0.28 | Min onset confidence to fire. Raise to cut false positives from ambient noise. |
| `guidedAttackWindow` | PressDetector | 0.22 s | How long after audio onset to accept a press. Raise if detection feels late. |
| `pitchSemitoneWindow` | PressDetector | 3 | Semitone tolerance for pitch bonus. |
| `minRMS` | AudioPitchDetector | 0.0015 | Min signal level. Raise if quiet room produces false onsets. |
| `ambientRMSRatio` | AudioPitchDetector | 3.0 | Onset must be 3× ambient RMS. Raise for noisier environments. |
| `minFluxScore` | AudioPitchDetector | 0.24 | Min spectral flux to count as onset. |
| `ambientFluxRatio` | AudioPitchDetector | 3.0 | Onset flux must be 3× ambient flux. |

**If detection is too sensitive** (false positives): raise `minRMS`, `minFluxScore`, `ambientRMSRatio`.
**If detection misses real presses**: lower those same values, or lower `guidedMinAttackConf`.
**For soft piano playing** (lighter attack): lower `minRMS` to ~0.0008 and `minFluxScore` to ~0.16.

---

## 6. AR overlay geometry (depth buffer)

All overlay materials must have:
```swift
material.writesToDepthBuffer  = false
material.readsFromDepthBuffer = false
```

If `readsFromDepthBuffer = true`, the overlay z-fights with the 3D key boxes and
flickers whenever a hand or highlight occupies the same depth. This was a solved
bug — do not revert it. Affected nodes: key highlight quads, press/miss flash
quads, hand sphere/cylinder joints.

---

## 7. Keyboard orientation derivation

**Virtual mode (`PlacementManager`):**
```swift
let toUser   = normalize(camPos - hitPos)            // camera → hit point
let kbZ      = normalize(SIMD3(toUser.x, 0, toUser.z))  // near edge → user
let kbY      = SIMD3(0, 1, 0)                        // always world-up
let kbX      = cross(kbZ, kbY)                       // keyboard right (low→high notes)
```

**Real piano mode (`CalibrationManager`):**
```swift
let zRaw     = (nl + nr)*0.5 - (fl + fr)*0.5        // near-center − far-center
let kbZ      = normalize(SIMD3(zRaw.x, 0, zRaw.z))  // project to horizontal plane
let kbY      = SIMD3(0, 1, 0)                        // always world-up (never derive from corners)
let kbX      = cross(kbZ, kbY)
```

**Critical:** Never derive the Y axis from corner cross-products. LiDAR height noise
in tapped corners produces a tilted Y axis, making the overlay lean and per-key
X positions drift off the real keys.

---

## 8. Build and deploy workflow

1. Push changes to `main` on GitHub
2. `.github/workflows/build.yml` runs automatically on `macos-latest`
3. XcodeGen regenerates `.xcodeproj` from `project.yml`
4. `xcodebuild archive` → export unsigned `.ipa`
5. Download `PianoAR.ipa` from GitHub Actions Artifacts
6. Sideloadly: drag `.ipa` onto the app, connect iPhone, sign with Apple ID
7. Apps expire after 7 days with free Apple ID (re-sign via Sideloadly)
8. No iOS Simulator on Windows — all testing is real-device only

---

## 9. Phase completion status

| Phase | Status | Notes |
|-------|--------|-------|
| 0: ARKit passthrough | ✅ Done | Confirmed on device |
| 1: Virtual piano | ✅ Done | Plane detection + keyboard anchor |
| 2: Real piano calibration | ✅ Done | 4-corner tap + homography |
| 3: Hand tracking | ✅ Done | Vision + LiDAR depth + smoothing |
| 4: Note highway | ✅ Done | Falling bars + key highlights |
| 5: Press detection | ✅ Done | Audio-primary guided + depth/trajectory non-guided |
| 6: AR gesture UI | ✅ Done | Pinch gestures + 3-button AR overlay |
| 7: VR HUD redesign | ✅ Done | Left-side panel, VR mode toggle |

---

## 10. Known issues / next tuning work

- **Detection sensitivity**: `AudioPitchDetector` thresholds (`minRMS=0.0015`,
  `minFluxScore=0.24`) were raised to cut false positives from ambient noise.
  For soft pianists or quieter rooms, lower these. All tuning knobs are listed
  in §5 above.
- **Right vs left hand note color**: `NoteHighway` uses `note.isLeft` to pick
  blue (right) vs pink (left) bar color. Ensure `SongPlayer` / MIDI import sets
  `isLeft` correctly per channel.
- **AR menu button text centering**: `SCNText` anchors at lower-left, so the
  character-offset centering in `ARMenuOverlay` is approximate. For non-ASCII
  labels it may be slightly off.
- **Keyboard scale on real piano**: `CalibrationData.widthScale` and
  `depthScale` applied to `KeyboardNode.makeOverlay()` via `node.scale`. If the
  overlay looks stretched, verify the 4 corner taps match actual keyboard corners.
- **Song progress not resetting on redo-calibration**: `pressDetector.reset()`
  is called in `renderer(nodeFor:)` when the anchor is created, but
  `songPlayer.restart()` is not. If needed, call `songPlayer.restart()` from
  `CalibrationManager.reset()` or after re-calibration.

---

## 11. Next steps (suggested)

1. **Test detection on device** with real piano playing. The main tuning target
   is the audio threshold values in §5. Keep a session log of false positive /
   false negative rates to guide empirical tuning.
2. **Add more songs** — just drop `.mid` files into the Xcode project (they're
   auto-included via `project.yml`). The app already has MIDI import from Files
   app in the UI.
3. **Stereo / dual-eye mode** (optional): if the lens shell is binocular, the
   screen could be split into L/R eye views. This would require rendering two
   viewpoints per frame and is a significant additional undertaking.
4. **Polyphonic pitch detection** (explicit non-goal per CLAUDE.md): identifying
   which specific key was hit from audio alone requires full polyphonic pitch
   detection — this is explicitly out of scope. The current design uses pitch
   only as a soft confidence boost, not for key identification.
5. **Detection in non-guided mode**: the depth+trajectory path works on any
   surface but requires the keyboard anchor to be accurate. Improve by adding
   the audio onset check as a cross-check in non-guided mode too (currently
   audio is only used in guided mode).

---

## 12. Codex tips for continuation

- `project.yml` auto-includes all `.swift` under `PianoAR/` and all resource
  files — just add new files, no manual project editing needed.
- The `.xcodeproj` is **never committed** and is regenerated in CI. Ignore it.
- All geometry values (key widths, depths) are in `KeyboardLayout.swift` as
  static constants — change them there and everything downstream updates.
- The render loop runs on SceneKit's background thread. All `@Published`
  property updates must use `DispatchQueue.main.async { }`.
- LiDAR depth sampling is in `HandTracker.swift`. If `ARFrame.smoothedSceneDepth`
  returns nil (non-LiDAR device or LiDAR data not yet available), the tracker
  falls back to a plane-based approximation.
