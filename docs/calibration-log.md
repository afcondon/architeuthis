# Calibration log

`lat` values in `setup/*.tidal` are only valid for the chain they were
measured against. Change any link in the chain — different audio
interface, different host, different module firmware, even different
buffer size — and the calibration must be redone.

This file is the chain-record-of-truth: each entry pairs a measured
`lat` value with the complete signal path it was measured against, so
that future-Andrew can answer "is this lat value still valid?" by
checking which links of the chain have changed.

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
