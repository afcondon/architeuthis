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
