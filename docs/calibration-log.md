# Calibration log

`lat` values in `setup/*.tidal` are only valid for the chain they were
measured against. Change any link in the chain — different audio
interface, different host, different module firmware, even different
buffer size — and the calibration must be redone.

This file is the chain-record-of-truth: each entry pairs a measured
`lat` value with the complete signal path it was measured against, so
that future-Andrew can answer "is this lat value still valid?" by
checking which links of the chain have changed.

`docs/calibration-components.md` is the **shared decomposition** —
named components (e.g. `fh2-trigger-baseline`, `rample-audio-engine`)
that combine to make each setup-file `lat`. This file's per-session
entries below are where the components were originally measured.

Format per entry:

- **Date** — when measured
- **Destination** — the device line in setup/*.tidal that uses this
- **lat (ms)** — the calibrated value
- **Chain** — every component that the timing depends on
- **Method** — what was driven against what, what tool measured offset
- **Result numbers** — peak lag, mean, median, std, n
- **Recording** — path to the source recording (kept for re-analysis)
- **Notes** — caveats, outliers, anything that should travel with the number

---

## 2026-05-01 — Live drum rack (ch 1, 2, 16)

- **Destination:** `midi-device live "IAC Driver Tidal"` in
  `setup/live.tidal`
- **lat:** 30 ms
- **Chain:**
  - Mac (MBP, macOS post-update reboot 2026-05-01)
  - purerl-tidal scheduler (gen_udp socket lifecycle fix in
    MIDIScheduler.purs)
  - link-spike at b402e04, OSC→CoreMIDI dispatch on UDP 57122
  - CoreMIDI virtual port "IAC Driver Tidal"
  - Ableton Live → MIDI From "IAC Driver Tidal", Track In, Drum Rack 2
  - Live's audio engine (sample rate / buffer size at time of
    measurement: project default — record explicitly next time)
- **Method:** stereo recording L = Live's own clip playing the same
  Drum Rack pad, R = Tidal-driven `live-tick` (ch 16, note 36) hitting
  the same pad
- **Result:** peak lag -0.04 ms, std 2.2 ms (per session summary; raw
  recording not preserved — pre-dates this log)
- **Notes:** This is the rig-wide reference. The 30 ms is mostly Live's
  own audio buffer + CoreMIDI driver latency.

---

## 2026-05-01 — iPad-Patterning (Track 1)

- **Destination:** `midi-device ipad-patterning "AUDIO4c USB2"` in
  `setup/ipad.tidal`
- **lat:** 50 ms
- **Chain:**
  - Mac (MBP, macOS post-update reboot 2026-05-01)
  - purerl-tidal scheduler → link-spike → CoreMIDI
  - CoreMIDI port "AUDIO4c USB2" (Mac-side name for Audio4c USB MIDI
    port 2)
  - Audio4c USB MIDI host→device routing on USB2 (configured via
    AuracleX; iPad sees this as "AUDIO4c-USB1")
  - iPad → AUM → AUM matrix routes the USB-MIDI input to Patterning's
    plugin channel
  - Patterning AU plugin's internal MIDI subscription enabled for
    "AU HOST INPUT" (mandatory — the second-step subscription trap)
  - Patterning's `.patterningMIDIMapping` with `midiSource = "AU HOST INPUT"`
    matches the Track 1 trigger entry (note 60 ch 1)
  - iPad audio out → A4C analog input pair → Live's input channel
- **Method:** stereo recording L = Tidal-driven `live-tick` (calibrated
  Live drum rack), R = Tidal-driven `ipad-p3-1`. Both fired by Tidal on
  the same beats; cross-correlation in `/tmp/p3-analyze.py`.
- **Result (with lat 50):**
  - median offset: -0.72 ms
  - mean: +2.76 ms (skewed by one outlier)
  - first 8 beats within ±3.5 ms
  - n = 16 paired onsets
  - source: `Tidal Test Rample QD Laplace Project/Samples/Recorded/3-Audio 0005 [2026-05-01 203420].aif`
- **Pre-calibration measurement (lat 0):** median +50.87 ms, std 4.05 ms
  (`3-Audio 0004 [2026-05-01 203127].aif`) — this is what 50 ms
  compensates for.
- **Notes:**
  - One outlier beat at +45 ms — likely a single iPad audio-buffer late
    dispatch event. Not a structural problem; the other 15 beats are
    tight.
  - **Hypothesis to validate:** the ~50 ms residual is the AUM-AU dispatch
    chain, not Patterning-specific. If true, Laplace and other AUM-AU
    instruments should calibrate to similar lat values. **Validate with
    Laplace** before generalising.
  - Trigger note vocabulary currently limited to Track 1 (note 60 ch 1);
    full mapping migration pending — sed `"Patterning 3"` →
    `"AU HOST INPUT"` across the Mac mapping plist, install on iPad.

---

## 2026-05-01 — FH-2 trigger baseline (`fh2-trigger-baseline = 28 ms`)

- **What it measures:** the bare-gate path — Tidal MIDI dispatch through
  FH-2 to FHX-8GT gate output, captured directly via ES-9 input. No
  module audio engine in this chain; just the trigger plumbing.
- **Probe binding:** `fh2-tick` in `setup/rample.tidal` (FH-2 MCV slot 4
  → FHX-8GT output 5 on ch 14, lat 0)
- **Patch:** for this measurement we used FHX-8GT output 1 (the same
  output Rample's gate normally consumes), patched into ES-9 input 5,
  with Rample temporarily unplugged. `fh2-tick` will work the same way
  for future re-measurements without unplugging Rample, by patching
  FHX-8GT output 5 → an unused ES-9 input.
- **Method:** stereo recording L = `live-tick` (calibrated reference),
  R = ES-9 input 5 capturing the bare gate
- **Result:** median +28.6 ms, mean +27.2 ms, std 3.25 ms, n = 24 paired
  onsets
  - source: `Tidal Test Rample QD Laplace Project/Samples/Recorded/3-Audio 0008 [2026-05-01 213227].aif`
- **Component published:** `fh2-trigger-baseline = 28 ms` (rounded)

---

## 2026-05-01 — Rample (`fh2-rample lat 61`)

- **Destination:** `midi-device fh2-rample "FH-2"` in `setup/rample.tidal`
- **lat:** 61 ms = `fh2-trigger-baseline` (28) + `rample-audio-engine` (33)
- **Chain:**
  - All of `fh2-trigger-baseline`'s chain
  - …plus: FHX-8GT output 1 → Rample gate input → Rample voice 1 sample
    trigger → Rample DAC → Rample analog audio out → ES-9 input 5 →
    Live's input
- **Method:** stereo recording L = `live-tick`, R = Rample audio via
  ES-9 input 5
- **Result (with lat 0 on the fh2 device — i.e. before per-binding
  compensation):** median +61.4 ms, mean +60.3 ms, std 3.30 ms, n = 24
  - source: `Tidal Test Rample QD Laplace Project/Samples/Recorded/3-Audio 0009 [2026-05-01 213957].aif`
- **Component derived:** `rample-audio-engine = 33 ms` = full-chain
  median (61) − fh2-trigger-baseline (28)
- **Notes:**
  - Rample sample used was a kick — not the clickiest onset; result
    consistent with the cleaner FH-2 baseline measurement (same std
    profile), so no further refinement needed.
  - Per-binding lat compensation introduced via the new `fh2-rample`
    device alias — same physical port "FH-2" as the bare `fh2` device
    but with `lat 61` baked in. Future per-module aliases (`fh2-qd`,
    `fh2-plaits`) will follow the same pattern.

---

## 2026-05-01 — QuadDrum (`fh2-qd lat 69`)

- **Destination:** `midi-device fh2-qd "FH-2"` in `setup/qd.tidal`
- **lat:** 69 ms = `fh2-trigger-baseline` (28) + `qd-audio-engine` (41)
- **Chain:** as `fh2-trigger-baseline`, plus FHX-8GT output → QD voice
  trigger input → QD voice circuit (analog excitation, VCA) → QD audio
  out → ES-9 input → Live input
- **Method:** stereo recording L = `live-tick`, R = QD audio via ES-9
  input. Pattern fired with both bindings on the same beats; sample on
  L was a Live drum rack handclap, R was a QD voice with a similar
  handclap-ish sample for fair onset comparison.
- **Result (lat 0):** median +69.05 ms, std 7.22 ms, n = 20 (beat 1
  outlier at +35.96 ms; beats 2-8 dead flat at 69 ms).
  - source: `Tidal Test Rample QD Laplace Project/Samples/Recorded/3-Audio 0011 [2026-05-01 220109].aif`
- **Component derived:** `qd-audio-engine = 41 ms`
- **Notes:** the "dead flat at 69 ms across beats 2-8" pattern is unusual
  — almost no jitter relative to dispatch. Suggests QD's trigger input
  has very low input variance (analog comparator with tight threshold).

---

## 2026-05-01 — Plaits (`fh2-plaits lat 38`)

- **Destination:** `midi-device fh2-plaits "FH-2"` in `setup/plaits.tidal`
- **lat:** 38 ms = `fh2-trigger-baseline` (28) + `plaits-audio-engine` (10)
- **Chain:** as `fh2-trigger-baseline`, plus FHX-8GT output → Plaits
  TRIG input → Plaits envelope/excitation generator → macro-oscillator
  voice → Plaits audio out → ES-9 input → Live input
- **Method:** stereo recording L = `live-tick`, R = Plaits audio via
  ES-9 input
- **Result (lat 0):** median +38.02 ms, mean +38.04 ms, std 6.43 ms,
  n = 20 (beat 1 outlier at +17.81 ms; beats 4-8 cluster around
  33-37 ms; beats 2-3 slightly higher at 47, 46 ms — likely onset
  detection variance on Plaits's percussive setting)
  - source: `Tidal Test Rample QD Laplace Project/Samples/Recorded/3-Audio 0012 [2026-05-01 220150].aif`
- **Component derived:** `plaits-audio-engine = 10 ms` — by far the
  fastest engine measured in the rig, consistent with Plaits being a
  pure-synthesis voice (no sample lookup, just envelope generator
  and oscillator).

---

## 2026-05-02 — ES-5 trigger baseline (`es9-silentway-trigger-baseline = 54 ms`)

- **What it measures:** the second trigger pathway in the rig — Tidal-driven
  audio-rate gate via cv-router, packed into the high byte of the ES-5 L
  ADAT lane, decoded by ES-5 to a panel gate jack. Orthogonal to the
  MIDI/FH-2 path (which uses CoreMIDI for event-driven dispatch); this
  one is end-to-end audio-buffer-paced.
- **New binding:** `ES5Gate Int` in `Tidal.Binding`, dispatcher in
  `Tidal.MIDIScheduler`, FFI in `Tidal.OSC.{purs,erl}`. Setup file
  `setup/es5.tidal` exposes `es5g1..es5g8` for ES-5 panel gates 1..8.
- **Pre-conditions verified:** ES-9 loaded with `cv-router-with-es5.es9`
  (USB 5 → ES-5 L), cv-router running with default device "ES-9",
  ES-5 module connected via ADAT.
- **Patch:** ES-5 gate jack 1 → ES-9 input 9 → Live R channel
- **Method:** stereo recording L = `live-tick`, R = ES-5 gate 1.
  `live-tick "x ~ x ~ x ~ x ~"` and `es5g1 "x ~ x ~ x ~ x ~"` in unison.
- **Result:** median +54.58 ms, mean +53.91 ms, std 7.26 ms, n = 32
  (beat 1 outlier at +22 ms — same first-event scheduling artifact as
  prior calibrations; beats 2-8 cluster 48-58 ms).
  - source: `Tidal Test Rample QD Laplace Project/Samples/Recorded/3-Audio 0013 [2026-05-01 220316].aif`
- **Notes:**
  - About 2× the FH-2 baseline (28 ms). Makes physical sense — ES-5 path
    is buffer-traversal (cv-router audio callback → next audio buffer →
    ES-9 USB output buffering → ADAT → ES-5 decode). FH-2 path is
    event-driven CoreMIDI, kernel-timestamped.
  - Higher std (7.26 vs FH-2's 3.25) from audio-buffer-edge alignment.
  - Drift slope 343 µs/s — same range as previous measurements; treat as
    measurement artifact (Live input bus alignment) until proven otherwise.
- **Structural follow-up:** OSC-path bindings (`Gate`, `ESX`, `ES5Gate`)
  don't yet carry a per-binding `lat` field — that compensation lives
  only on `midi-device` lines. To phase-lock an ES-5-triggered module
  with Live's grid, the binding needs lat support added. Tracked as
  next refactor in this session.

---

## 2026-05-02 — ES-9 panel-out trigger baseline (`es9-cv-panel-baseline = 82 ms`)

- **What it measures:** the third trigger pathway — Tidal `Gate`
  binding → cv-router `/tidal/gate/trig` → cv-router IIR smoother
  ramps target → ES-9 analog DAC → analog output stage → ES-9 panel
  jack. Same dispatch shape as `Gate` bindings already used for the
  default drum aliases (`bd`, `sn`, `hh`, etc.).
- **Probe:** `bind es9-tick gate 1` issued live in Calypso (no setup
  file change). gate ch 1 = cpal bus 9 = ES-9 panel jack 2.
- **Patch:** ES-9 panel jack 2 → ES-9 input 10 → Live R channel.
- **Method:** stereo recording L = `live-tick`, R = ES-9 input 10.
- **Result (lat 0):** median +81.6 ms, mean +81.1 ms, std 6.27 ms,
  n = 40
  - source: `Tidal Test Rample QD Laplace Project/Samples/Recorded/3-Audio 0015 [2026-05-02 080529].aif`
- **Notes:**
  - 28 ms HIGHER than the ES-5 path (54 ms) — at first surprising,
    since the ES-9 panel out has no ADAT/ES-5 stage. Source of the
    extra latency: cv-router's IIR smoother (5 ms default lag, but the
    ramp adds little to threshold-crossing) + ES-9 analog DAC + analog
    output stage. The smoother is helpful for CV but pays for it on
    sharp triggers.
  - This recording established the path-quality ranking documented in
    docs/calibration-components.md ("FH-2 best, ES-5 second, panel-outs
    third").

## 2026-05-02 — link-spike vs Tidal cv-router scheduling-path divergence

- **What it measures:** internal cv-router scheduling-path difference
  between link-spike's `/cv/trig/at` (sample-accurate, audio callback
  evaluates `pending_start` at exact frame) and Tidal's
  `/tidal/gate/trig` (BEAM `timer:sleep` then immediate-on-receipt
  set_target + sample-counted release deadline). Both paths share
  cv-router's IIR smoother + ES-9 analog stage downstream.
- **Patch:** ES-9 panel jack 1 → ES-9 input 9 (link-spike's path,
  L), ES-9 panel jack 2 → ES-9 input 10 (Tidal's path, R).
- **Method:** stereo recording with link-spike running its default
  per-beat trig on bus 8 (50% duty), Tidal firing
  `es9-tick "x ~ x ~ x ~ x ~"` to bus 9.
- **Result:** median R−L = +6.5 ms, std 4.49 ms, n = 36
  - source: `Tidal Test Rample QD Laplace Project/Samples/Recorded/3-Audio 0016 [2026-05-02 081506].aif`
- **Derived:** `link-spike-cv-trigger-baseline ≈ 75 ms` (= 82 − 6.5).
  Same chain as `es9-cv-panel-baseline` but with a 6.5 ms head start
  due to cv-router's sample-accurate scheduling on `/cv/trig/at`.
- **Why this matters:** lets us reason about how link-spike's per-beat
  trig (which drives the rig's hardware clock if/when used) aligns with
  Tidal-driven gates. If both fire on the same Link beat at the same
  bus, link-spike's gate arrives 6.5 ms earlier and may pre-empt
  Tidal's set_target via cv-router's single-pending-start-slot
  contention.

---

## 2026-05-02 — Refactor: per-binding `lat` for OSC paths

Concurrent with the above measurements, refactored the `Gate`, `ESX`,
and `ES5Gate` PrimAction constructors to carry a `latencyMs` field.
Parser accepts optional trailing `lat <int>` on the action spec:

```
bind es5g1 es5gate 0          -- lat 0 (uncompensated)
bind es5g1 es5gate 0 lat 54   -- compensated by 54 ms
```

Dispatcher subtracts `latencyMs` from `delayClamped` before the BEAM
sleep, mirroring the `dev.latencyMs` adjustment already applied for
MIDI bindings. Default 0 if `lat` is omitted (preserves the existing
default-drum-binding behaviour).

`setup/es5.tidal` now bakes `lat 54` into all `es5g1..es5g8` so they
phase-lock with Live's grid out of the box.

**Verification still pending:** rebuild, restart purerl-tidal, rerun
the `live-tick` + `es5g1` recording. Expect the median offset to
collapse to near zero (analogous to ipad-patterning's behaviour after
applying lat 50).

---

## Procedure for a new destination

1. Add a `midi-device <name> "<port>" lat 0` line in a setup file.
2. Bind a single trigger to a note that the destination will produce a
   percussive sound for.
3. Drive `live-tick` (already calibrated reference) on the L of a Live
   recording channel pair, and the new destination on the R.
4. Send `name "x ~ x ~ x ~ x ~"` for both, ~8 bars; export the recording
   as a stereo AIFF.
5. Run `python3 /tmp/p3-analyze.py <path>`.
6. Apply the median offset as the new `lat` value in the setup file.
7. Re-record with the new lat, confirm median is sub-millisecond.
8. Add an entry to this file documenting the chain.

## Trigger-path decomposition (FH-2, ES-9)

Modules triggered through a shared trigger path (FH-2 → FHX-8GT for
MIDI gates; ES-9 → ES-5 → ESX-8GT for Silent-Way audio gates) are
calibrated as:

```
L_total(module) = L_path_baseline + L_module_audio
```

Measuring the path baseline once parameterises every module that hangs
off it. To add a new module triggered via FH-2 you only need a
single recording.

### FH-2 path baseline

- **Probe binding:** `fh2-tick` in `setup/rample.tidal` — fires FH-2 MCV
  slot 4 → FHX-8GT output 5 (output ID 69) on channel 14.
- **Patch:** FHX-8GT output 5 → free ES-9 input (whichever is plumbed to
  the recording R-channel in Live)
- **Measurement:** stereo recording L = `live-tick`, R = ES-9 input
  capturing the bare gate. Drive both `live-tick "x ~ x ~ x ~ x ~"` and
  `fh2-tick "x ~ x ~ x ~ x ~"`. Cross-correlate.
- The median offset is `L_FH2_baseline`.

### ES-9 / Silent-Way path baseline

(Future — not yet measured. Procedure analogous: probe a Silent-Way
gate on a known ES-9 output, loopback into a free ES-9 input.)

### Module-specific delta

After path baseline is known:
- Patch the module normally (FHX-8GT output → module gate in; module
  audio out → ES-9 input)
- Drive `live-tick` + `<module-trig>` in unison, record stereo
- `L_module_total` from cross-correlation
- `L_module_audio = L_module_total - L_path_baseline`

Set the destination's `lat` to `L_module_total` (the full-chain figure).
The decomposition is bookkeeping for future-Andrew, not a quantity that
goes into setup files.
