# Calibration components

Each `lat` in `setup/*.tidal` is a sum of one or more of these
components. The list is the source of truth for measured latencies in
the rig; if a component changes (firmware update, hardware swap, host
app version), update the value here and re-derive every `lat` that
references it.

## Granularity

Components are measured at the granularity our recording rig actually
supports — bare-gate vs. full-chain, per-destination. We do **not**
attempt to decompose into wire-level pieces (USB cable propagation, hub
delay, AC line latency, etc.) — those are sub-millisecond and not worth
chasing within an amateur measurement budget.

A component captures **everything that contributes to the latency
between Tidal scheduling an event and the resulting sound being
recorded back into Live, that is invariant across destinations sharing
that part of the chain.**

## Components (as of 2026-05-01)

| Name | Value (ms) | Description | Measurement |
|---|---:|---|---|
| `fh2-trigger-baseline` | 28 | Tidal MIDI dispatch → CoreMIDI "FH-2" → FH-2 MCV processing → FHX-8GT gate output → ES-9 input ADC → Live input | Bare-gate recording 0008: median 28.6 ms, std 3.25 ms, n=24 |
| `rample-audio-engine` | 33 | Rample sample-trigger decision + sample lookup + DAC + analog audio out (gate-rising-edge to first audio output) | Rample full-chain (0009) median 61.4 ms minus `fh2-trigger-baseline` |
| `qd-audio-engine` | 41 | QuadDrum trigger-to-first-audio: voice circuit excitation + analog VCA + analog audio out | QD full-chain (0011) median 69.05 ms minus `fh2-trigger-baseline` |
| `plaits-audio-engine` | 10 | Plaits gate-to-first-audio: envelope/excitation + macro-oscillator + DAC. Pure synthesis, no sample-lookup phase | Plaits full-chain (0012) median 38.02 ms minus `fh2-trigger-baseline` |
| `aum-au-path` | 50 | A4C USB-MIDI host→device + iPad CoreMIDI → AUM matrix routing → AU plugin internal MIDI subscription → AU plugin instrument engine + AUM mixbus → A4C analog out → Live input | iPad-Patterning recording 0004 (lat 0): median 50.9 ms, std 4.05 ms, n=20 |
| `live-drum-rack` | 30 | "IAC Driver Tidal" CoreMIDI port → Live's MIDI input quantization to next audio buffer → Drum Rack pad → Live audio bus | Pre-existing Live calibration (vs Live's own internal clip); peak -0.04 ms at lat 30, std 2.2 ms |
| `es9-silentway-trigger-baseline` | 54 | Tidal `ES5Gate` binding → cv-router `/esx5gate` (UDP 57120) → cv-router atomic write → audio callback packs byte into ES-5 L lane (24-bit PCM ADAT) → ES-9 USB out 5/6 → ES-5 decodes high byte → panel gate jack | Bare ES-5 gate (recording 0013): median 54.6 ms, std 7.26 ms, n=32. Roughly 2× the FH-2 path baseline — buffer-traversal end-to-end vs CoreMIDI's event-driven dispatch |

## Pending components

- **`es9-cv-trigger-baseline`** — Tidal `Gate` binding → cv-router
  `/tidal/gate/trig` → cpal bus 8-15 → ES-9 panel jack 1-8. The other
  audio-rate trigger path (direct ES-9 panel CV/Gate, no ADAT/ES-5).
  About to measure (panel jack 1 is conveniently flashing from
  link-spike's per-beat trig, so just patch it to a free ES-9 input).

## Setup-file references

| Setup line | Composition |
|---|---|
| `midi-device live "IAC Driver Tidal" lat 30` | `live-drum-rack` |
| `midi-device ipad-patterning "AUDIO4c USB2" lat 50` | `aum-au-path` |
| `midi-device fh2-rample "FH-2" lat 61` | `fh2-trigger-baseline` + `rample-audio-engine` |
| `midi-device fh2-qd "FH-2" lat 69` | `fh2-trigger-baseline` + `qd-audio-engine` |
| `midi-device fh2-plaits "FH-2" lat 38` | `fh2-trigger-baseline` + `plaits-audio-engine` |

## Future automation

This file is the input to a planned `rig-doctor calibrate` utility
(not yet built — see Marginalia project). The utility will:

1. Drive Tidal patterns over the WS interface
2. Capture audio via the aggregate device
3. Cross-correlate (port of `/tmp/p3-analyze.py`)
4. Update component values here in place
5. Optionally regenerate setup files from templates with composed `lat`
   values

Until then, components are measured by hand using the procedure in
`calibration-log.md`, and setup files carry the resolved sum on the
`lat` line plus the composition in a comment.
