# PianoAR

Head-mounted AR piano trainer for iPhone 16 Pro inserted into a Cardboard-style lens shell (Denver VR-20). See [CLAUDE.md](CLAUDE.md) for the original project brief and [CODEX.md](CODEX.md) for the architecture handoff.

## Status — v0.2 ("v2")

Real-piano mode on an acoustic piano (no MIDI anywhere). What's in the app:

- **Calibration** — automatic keyboard detection, or rest both index fingers on the lowest and highest key and hold still, or tap the 4 corners. Fine-tune with SETUP › NUDGE.
- **Note waterfall** standing behind the keys (notes fall onto the key they belong to), pulsing cues on the keys to play, key letters on the keys.
- **Press detection** — Vision hand tracking + LiDAR depth + microphone. Chords are verified note-by-note from the sound (each expected note's own partials), so all members of a chord register from one strike.
- **Practice** — wait mode or play-along, tempo 40–150 %, practice right / left / both hands, skip, results card with accuracy, streak, timing.
- **Comfort (motion sickness)** — life-size passthrough, per-eye images centred on the lenses, 120 Hz gyro re-projection between 60 fps camera frames.
- **AR menu** — LIBRARY · PRACTICE · COMFORT · SETUP tabs; point with your index finger and pinch to select, pinch-and-hold the title bar to move it. It shrinks to a PAUSE · SKIP · MENU pill while a song plays.

## First-time headset setup (important for motion sickness)

1. Slide the VR-20 lenses (left/right) to your eyes and set the focus slider.
2. Open **COMFORT**. Adjust **LENS SPACING** until the view looks single and sharp without effort.
3. Stare at a far edge and shake your head: if the world swings *against* your head turn, lower **VIEW SIZE**; if it *drags along* with you, raise it. Right size = the world stays put.
4. Keep **MOTION SMOOTHING** on unless the image feels jumpy. Try **RENDER: SINGLE** — it halves GPU work (cooler phone, steadier frame rate); if the right eye goes black, switch back to DUAL.
5. Take a 10–15 min break every 30 min.

## Adding songs

Put `.mid` / `.midi` files (or the simple JSON format below) into **Files › On My iPhone › PianoAR**, or share/AirDrop a MIDI file and choose *Open in PianoAR*. They appear in the LIBRARY after the built-in songs. MIDI format-1 files: track 1 = right hand, track 2 = left hand.

```json
{ "title": "C Major Scale", "bpm": 72,
  "notes": [ {"key": "C4", "startBeat": 0, "durationBeats": 1, "hand": "right"} ] }
```

## How this repo is built (no local Mac required)

The `.xcodeproj` is **not** committed — it is generated from [`project.yml`](project.yml) by [XcodeGen](https://github.com/yonaskolb/XcodeGen) inside GitHub Actions.

1. Push to `main`, or run the **Build unsigned IPA** workflow on any branch (`gh workflow run build.yml --ref <branch>`).
2. Wait for the `macos-latest` build (~5–10 min).
3. Download the `PianoAR-unsigned-ipa` artifact (`gh run download <run-id> -n PianoAR-unsigned-ipa`).
4. Sideloadly on the PC: drag in the IPA, sign with your Apple ID, install over USB.

### Sideloadly limits (free Apple ID)

- Sideloaded apps **expire every 7 days** and need re-signing.
- Max **3 sideloaded apps** at once; max **10 new App IDs per rolling 7 days** — don't change the bundle ID casually.
- A **paid $99/year Apple Developer account** removes the 7-day expiry.

## File layout

```
PianoAR/
  PianoARApp.swift, ContentView.swift   app entry + menu-action routing
  ARPassthroughView.swift               AR view + per-frame loop, hint bar, hand overlay
  StereoViewer.swift, MotionWarp.swift  headset stereo layout, 120 Hz gyro re-projection
  ComfortSettings.swift                 view size / lens spacing / smoothing (persisted)
  ARSessionModel.swift                  ARKit session configuration
  CalibrationManager.swift              auto-detect, fingertip and corner calibration
  HandTracker.swift                     Vision hand pose + LiDAR depth + smoothing
  PressDetector.swift                   vision trajectory + chord-aware audio acceptance
  AudioPitchDetector.swift              mic onsets + staged note verification
  NoteVerifier.swift                    per-note "was it struck?" spectral check
  SongPlayer.swift                      song clock, wait/play-along, stats
  NoteHighway.swift, HUDOverlay.swift   waterfall, key cues, HUD, debug panel
  ARMenuOverlay.swift                   the AR tablet menu
  KeyboardLayout.swift, KeyboardNode.swift, LabelFactory.swift
  BuiltInSongs.swift, SongLibrary.swift, MIDIFileImporter.swift, SongModel.swift
.github/workflows/build.yml             CI: XcodeGen → xcodebuild → unsigned IPA
```
