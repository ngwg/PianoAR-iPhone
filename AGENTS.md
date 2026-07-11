# Project: PianoAR-iPhone

## What this is
An iOS app (Swift, ARKit + Vision framework, native — no Unity/Unreal) that turns an
iPhone 16 Pro into a head-mounted AR piano trainer, conceptually similar to
PianoVisionAR (a Meta Quest app) but built for a phone inserted into a cheap
plastic lens viewer (Google-Cardboard-style), worn on the head, looking down at
either (a) a real acoustic 88-key piano, or (b) a flat surface like a desk with
no real piano at all — a fully virtual keyboard placed in space (this is "mode
B," equivalent to PianoVision's "Air Piano" option). The phone's rear camera
provides passthrough video shown on-screen; ARKit anchors a virtual overlay
(keyboard guide, falling notes, fingertip markers) onto the real world in 3D so
it stays visually locked in place as the wearer's head moves. There is no
real-time conversational component — this is a fully native iOS app, built
locally in Xcode, with GitHub Actions used only to produce a clean exportable
.ipa for sideloading via Sideloadly. Target: iOS 26.5+, iPhone 16 Pro (has
LiDAR — use it).

**Important: this is an acoustic piano with no MIDI-out, and there is no plan
to add MIDI hardware.** Unlike PianoVision, which leans on a connected MIDI
keyboard for its most reliable mode, there is no MIDI fallback anywhere in
this project. Every bit of note/press detection has to come from vision (plus
optionally audio onset as a secondary cross-check). This means hand-tracking
and press-detection quality are not a nice-to-have polish phase — they are a
primary deliverable on par with the AR anchoring problem, because there's
nothing else to fall back on if they're mediocre. Do not treat hand tracking
as "use the standard API and move on" — see the dedicated constraint below.

## Two calibration modes — build both, in this order
1. **Virtual piano mode (build first):** no real piano involved. The user
   places a fully virtual 88-key keyboard on a detected flat surface (desk,
   table, floor) using ARKit plane detection. This is the easier calibration
   problem — you're placing a new virtual object with known dimensions on a
   detected plane, not aligning to the ambiguous edges of a real keyboard.
   Build and validate the entire rendering/anchoring/note/UI pipeline against
   this mode first, since it removes the hardest unknown (real-piano
   alignment) from the early phases.
2. **Real piano mode (build second):** the user taps the 4 corners of their
   actual real keyboard on screen; each tap is hit-tested against the real
   world (via LiDAR/plane detection) to get a 3D position; a homography maps
   the known 88-key layout into that real-world quad. This is harder because
   real keyboards have ambiguous/low-contrast edges (white key boundaries
   especially), inconsistent lighting, and zero margin for error before the
   overlay visibly doesn't match the real keys.

Both modes share everything downstream (note rendering, hand tracking, press
detection, song UI) — only the calibration step differs. Architect the
keyboard model as a self-contained world-anchored object so both calibration
paths just need to produce one of these and the rest of the app doesn't care
which mode produced it.

## Ground truth about the reference product (do not assume more than this)
PianoVisionAR (Quest) does NOT reliably do audio- or vision-based key-press
*verification* — it primarily relies on either (a) a connected MIDI keyboard for
ground-truth note input, or (b) hand-tracking purely to show a "what to play"
overlay aligned to a real keyboard via manual calibration, without confirming
correctness of the actual press in the no-MIDI case. It also offers (c) a fully
virtual "Air Piano" mode with no real keyboard at all. This project has no
access to (a) at all (acoustic piano, no MIDI-out) — so unlike PianoVision,
where vision-only is the fallback mode, here vision-only is the *only* mode,
permanently. Build a "what to play, when, here" visual guide first (this part
is straightforward); then invest real, sustained effort into making the
vision-based press detection as good as it can be (this part is the actual
hard problem in this whole project, more so than for PianoVision itself).

## Hard constraints — read before writing any code
1. **No Unity/Unreal/cross-platform engine.** Native Swift, ARKit, RealityKit
   or SceneKit for rendering, Vision framework for hand pose. Keep the
   dependency graph minimal — no CocoaPods/SPM packages unless there's a very
   strong reason; this needs to build cleanly and predictably in CI later.
2. **This is a phone worn on the head via an external plastic lens shell.**
   There is no direct see-through — the screen is 100% camera passthrough,
   viewed through lenses a few cm from the eyes, looking down/forward at the
   piano. This means:
   - The viewing angle to the piano is steep and asymmetric (near keys large,
     far keys small and compressed) — never assume a top-down or
     straight-ahead camera angle.
   - The overlay MUST be anchored in ARKit world space (ARAnchor), not screen
     space. If the overlay is calculated in 2D screen pixels and just drawn on
     top of the video feed without being tied to a 3D ARAnchor that gets
     re-projected every frame as the camera moves, it will drift and break
     immediately on head movement. This is the single most important
     architectural rule in this entire project.
3. **Calibration has two paths, sharing one downstream representation.**
   - *Virtual mode:* use ARKit horizontal plane detection to find a flat
     surface; let the user confirm/adjust placement (position + rotation) of
     a virtual 88-key keyboard model of known real-world dimensions, anchored
     to that plane.
   - *Real mode:* one-time 4-corner tap, done by the wearer indicating the
     four corners of the real 88-key keyboard on screen while looking at it
     through the headset. Each tapped 2D screen point must be converted to a
     3D world-space point via an ARKit raycast/hit-test against the real-world
     surface (use LiDAR scene depth / ARKit plane detection —
     `ARWorldTrackingConfiguration` with `sceneReconstruction` and/or
     `personSegmentationWithDepth` enabled as appropriate). From those 4 world
     points, construct a full projective homography (NOT a simple affine
     transform — the perspective skew from a head-worn steep angle is too
     strong for affine) to map any of the 88 key positions (precomputed as
     fractional positions along the keyboard's width) into the calibrated
     quad.
   - Both paths must produce the same downstream representation: a
     world-anchored keyboard object exposing the 3D world position of each of
     the 88 keys' bounding regions. Nothing past calibration should need to
     know or care which mode produced the anchor. Every frame, re-project the
     anchor into current screen space using the live ARKit camera transform —
     this is what makes the overlay "stick" in place as the wearer's head
     moves, in both modes.
4. **Use LiDAR.** iPhone 16 Pro has a LiDAR Scanner — use `ARFrame.sceneDepth`
   /`smoothedSceneDepth` to get real depth at any pixel. This is needed for
   (a) getting a true 3D position for real-mode calibration corners, (b)
   plane detection quality in virtual mode, and (c) sampling depth under
   detected hand/fingertip landmarks to give Vision's 2D hand-pose output a
   real Z coordinate. Don't approximate depth analytically if LiDAR data is
   available — it's the main hardware advantage this project has over the
   Quest version, which lacks LiDAR, and matters more here than it would for
   PianoVision because there's no MIDI fallback if vision-derived depth is
   sloppy.
5. **Hand tracking is a primary deliverable, not a bolt-on API call.** iOS has
   no Quest-style native hand-tracking API — use Vision framework's
   `VNDetectHumanHandPoseRequest` on camera frames (throttled independently of
   ARKit's render rate, e.g. 15-30fps, to manage thermal load from running
   camera + ARKit + Vision + LiDAR simultaneously for an extended practice
   session). It returns up to 21 2D joint landmarks per hand with per-point
   confidence. Because there's no MIDI fallback anywhere in this project, do
   not stop at "call the API, use the raw per-frame output" — build a real
   tracking layer on top:
   - Discard landmarks below a confidence threshold (start ~0.3-0.5, tune
     empirically) rather than rendering/using noisy points.
   - Maintain per-finger identity across frames (associate "this is the same
     right-hand index finger as last frame," not just independent per-frame
     detections) via simple nearest-neighbor matching keyed by hand+finger
     index, so downstream smoothing and press detection have continuity to
     work with.
   - Apply frame-to-frame smoothing (exponential smoothing or a simple Kalman
     filter per landmark) to reduce jitter before using positions for
     anything — both visually (markers) and functionally (press detection).
   - Sample LiDAR depth at each landmark's 2D pixel to get a real Z, rather
     than approximating depth analytically — fingers constantly leave the
     known keyboard plane during normal piano playing, which breaks plane-
     based depth approximation.
6. **Press detection is the actual core deliverable of this project, not an
   experimental afterthought** — there is no MIDI ground truth anywhere here,
   so this is the difference between the app being useful and not. Build it
   in explicit layers, in this order:
   - **Primary signal:** a tracked fingertip's LiDAR-derived 3D position
     crossing a small threshold distance below the calibrated key-surface
     plane, at the calibrated (x,y) region of a specific key.
   - **Trajectory shape, not single-frame thresholding:** track the last N
     frames of a fingertip's vertical position and look for a real
     press-motion signature (descend, sharp deceleration at the surface,
     often a small rebound) rather than triggering on any single frame
     crossing the depth threshold. This is what separates "actually pressed"
     from "hovering close to the surface," which a naive single-frame
     threshold will get wrong constantly.
   - **Optional secondary cross-check:** listen on the iPhone mic for a sharp
     amplitude transient (note-attack onset) at approximately the time vision
     predicts a press. This cannot identify *which* key was hit (full
     polyphonic pitch detection is a separate hard problem and explicitly out
     of scope — do not attempt it), but a transient at roughly the right time
     is decent corroborating evidence that something was struck, useful to
     suppress vision false-positives that have no acoustic evidence behind
     them at all.
   - Build this with a debug overlay mode from day one (live depth values vs.
     threshold per key region, trajectory state per tracked finger) — this is
     experimental, tunable territory and needs to be debuggable, not a black
     box. Be explicit in the UI that detection is confidence-based, not
     ground truth (e.g. a simple confidence indicator on detected presses)
     rather than presenting uncertain detections as verified fact.
7. **Song/note data is a simple custom format, not MIDI.** Use a plain JSON
   structure like:
   ```json
   { "bpm": 90, "notes": [ {"key": "C4", "startBeat": 0, "durationBeats": 1},
     {"key": "E4", "startBeat": 1, "durationBeats": 0.5} ] }
   ```
   There is no MIDI import planned for this project at all — the piano has no
   MIDI-out and there's no other source of MIDI data in scope, so don't build
   a MIDI parser or leave hooks for one; keep song data exactly this simple.

## Build phases — work through these in order, do not skip ahead
Confirm each phase is actually working on a real device (not just "compiles")
before starting the next one. Ask the user to test on-device and report back
rather than assuming success.

- **Phase 0:** Minimal ARKit app. `ARWorldTrackingConfiguration`, camera
  passthrough rendered full-screen, nothing else. Goal is just confirming the
  phone-in-lens-shell setup is usable and the build/run/sideload loop works
  end to end before any piano-specific code exists.
- **Phase 1 (virtual piano mode):** ARKit horizontal plane detection, let the
  user place/confirm a virtual 88-key keyboard model on a detected surface,
  anchored in world space, rendered on top of passthrough and staying locked
  in place as the head moves. Build this before real-mode calibration since
  it's the easier version of the same anchoring problem and validates the
  rendering pipeline without also fighting real-keyboard edge ambiguity.
- **Phase 2 (real piano mode):** 4-corner tap calibration → world-space quad
  ARAnchor → homography-mapped virtual 88-key overlay rendered on top of
  passthrough, locked to the real piano as the head moves. Reuse the same
  downstream keyboard representation from Phase 1 — only the calibration
  step should differ between the two modes. Do not proceed to Phase 3 until
  both modes are confirmed solid on-device (overlay does not drift noticeably
  during normal practice-posture head movement).
- **Phase 3:** Add Vision hand-pose detection, sample LiDAR depth at each
  detected landmark, build the per-finger identity tracking + smoothing layer
  described in constraint 5, and render 3D markers at each fingertip position
  in the AR scene, anchored correctly relative to the Phase 1/2 keyboard
  anchor. Validate against both virtual and real piano modes. Validate
  visually that fingertip markers track real fingers accurately and stay
  spatially consistent with the keyboard overlay.
- **Phase 4:** Load the custom JSON note format, render a falling-note /
  highlighted-key "what to play next" UI on top of the keyboard overlay,
  driven by a simple clock/BPM scheduler. No press detection yet — this phase
  is purely the visual guide working correctly and in sync, in both modes.
- **Phase 5:** Press detection per constraint 6 above — depth threshold +
  trajectory shape + optional audio-onset cross-check, with the debug overlay
  mode built in from the start. This is the riskiest phase and the actual
  core deliverable of the project since there's no MIDI fallback — budget the
  most real-device iteration time here, more than any other phase.
- **Phase 6:** Interactive AR UI elements — song selection, basic settings,
  replay/restart — using pinch or simple deliberate hand gestures detected via
  the same Vision hand-pose pipeline from Phase 3, since there's no touchscreen
  access while the phone is in the headset shell.

## Local dev workflow
- **Reality of this checkout: the user is on Windows with no local Mac.** All
  builds happen via GitHub Actions on a `macos-latest` runner. The project is
  defined as a single `project.yml` consumed by **XcodeGen** so the
  `.xcodeproj` is regenerated fresh in CI and never needs to be hand-edited
  or committed. Edit Swift sources and `project.yml` directly here; the
  workflow at `.github/workflows/build.yml` produces an unsigned `.ipa` as a
  build artifact.
- This means there is **no fast local iteration loop**. Every change is a CI
  round-trip. Implication: be unusually careful about syntax/types before
  pushing — there is no simulator or `swift build` available to catch trivial
  errors locally. Prefer small, well-typed changes. When you complete a
  phase, ask the user to download the artifact, sign+install via Sideloadly,
  and report back real-device behavior — do not assume success from "CI is
  green."
- The CI workflow builds with `CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`,
  exports an unsigned `.ipa`, and uploads it as an artifact. Sideloadly does
  all signing locally with the user's Apple ID at install time. Do not add
  Apple Developer certificates or provisioning profiles to GitHub Secrets
  unless explicitly asked.
- Sideloadly free-account limits to keep in mind: apps expire after 7 days
  (requiring re-signing), 3 simultaneously installed sideloaded apps max, 10
  new App IDs per rolling 7-day window. A $99/year paid Apple Developer
  account removes the 7-day cap and is worth recommending if iteration speed
  becomes the bottleneck.

## What to ask the user rather than assume
- Whether the lens shell setup is comfortable/usable at all (Phase 0) before
  investing in anything piano-specific — this is a real hardware/ergonomics
  unknown, not just software.
- Real on-device behavior at every phase gate above — do not assume a
  phase "works" from code review or simulator behavior alone; ARKit world
  tracking, LiDAR depth, and Vision hand-pose all require a real device and
  real physical testing against the user's actual piano and headset shell.
- Whether to pursue audio-onset cross-checking (the secondary signal in
  constraint 6) early or defer it — it's optional polish on top of the
  primary depth+trajectory signal, not a replacement for it, so don't let it
  become a distraction from getting the core vision-based detection solid
  first.
- Real-device accuracy/usability feedback on press detection specifically
  once Phase 5 has a first pass — this is the part with no MIDI fallback to
  fall back on, so it's worth checking in with the user more often here than
  on other phases, and iterating based on actual playing sessions rather than
  synthetic testing.
