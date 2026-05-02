# Calibration session pre-flight checklist

A 2-minute pre-flight that catches the most common gotchas. Distilled
from sessions 2026-04-30 / 05-01 / 05-02. The point is to fail fast and
explicitly rather than spend time chasing silent symptoms.

This is the manual MVP of `rig-doctor calibrate`'s pre-flight phase.

## Hardware + audio

- [ ] **ES-9 reset to Hosted mode if it was in Standalone** — the
  `cv-router-with-es5.es9` config is in flash slot 1 (Hosted), and ES-9
  loads slot 1 on boot only when USB-connected. Visual: ES-9 panel LED
  pattern indicates mode.
- [ ] **All ES-9 expansion cables seated** — ADAT to ES-5, ES-5 to
  ESX-8GT/ESX-8CV. Wiggle test if anything mysteriously stops working.
- [ ] **Modular mixer faders up** for any module being recorded.
- [ ] **Audio4c+ + iPad** powered if iPad sources will be tested.

## Software processes

- [ ] **cv-router running** — check with `lsof -i UDP:57120`. If absent:
  `cd music/expert-sleepers/cv-router && ./target/release/cv-router`.
- [ ] **link-spike running** — check with `lsof -i UDP:57122`. If absent:
  `cd music/link-spike && ./target/release/link-spike`. Restart it
  whenever a new MIDI destination has been added or a previously
  disconnected MIDI device has been reconnected (its destination cache
  doesn't refresh on its own).
- [ ] **purerl-tidal running with current build** — `cd
  purescript-ports/purerl-tidal && make start` (or `make run` if source
  has changed since the last build). Verify no stray `beam.smp`
  processes from prior runs.
- [ ] **fh2-config daemon if FH-2 will be used** — check Unix socket
  `~/.fh2/control.sock` exists. If absent, `cd music/expert-sleepers/fh2-config &&
  spago run -- daemon` (or whatever the start command is now).

## ES-9 SysEx config

- [ ] **`cv-router-with-es5.es9` written to ES-9 flash slot 1** if any
  ES-5 / ESX-8GT / ESX-8CV outputs will be used. Reload to be safe:
  ```
  cd music/expert-sleepers/es9-config
  spago run -- --live-set configs/cv-router-with-es5.es9
  ```
  Look for `✓ device routing matches target`.
- [ ] **Smoke test ES-5 path:** `python3 /tmp/es5gate-test.py` — ES-5
  panel gate 1 LED should flash. cv-router stdout should show
  `silent_way: auto-enabled on first /esx5gate` (once per cv-router
  startup).

## Ableton Live

- [ ] **Link enabled** in Live's preferences (Link/Tempo/MIDI tab) — Link
  icon visible and blue at top of Live window. ⚠️ Easy to miss when
  starting a fresh project; without Link, Tidal and Live are on
  independent clocks and calibration measurements are meaningless.
- [ ] **Recording channel armed and monitoring set correctly** — input
  routed to the right ES-9 input(s); monitor switch on so you hear
  what's being recorded.
- [ ] **Track grouping** — be aware of which tracks are in groups and
  what PDC consequence that may have. Different group memberships shift
  individual tracks by different amounts (~5-10 ms typical, observed
  2026-05-02). Calibration is chain-specific — when group structure
  changes, lat values may need re-tuning.
- [ ] **Drum Rack track for `live-tick` reference** — receiving "IAC
  Driver Tidal" ch 16, with a percussive (sharp-attack) sample on note
  36. This is the metronome reference.

## Calypso / Tidal

- [ ] **Pen claimed** — ignore the header label if it conflicts with the
  banner status. The banner is the source of truth.
- [ ] **Cell content sanity** — no leading whitespace; single space (not
  multi-space) between binding name and pattern. Both have been
  observed to silently fail.
- [ ] **Smoke test one binding before the full pattern** — e.g.
  `es5g1 "x"` (single hit). If smoke fails, walk down the diagnostic
  tree (cv-router stdout, link-spike stdout, Tidal stdout) before
  blaming the rig.

## Pitch calibration (V/oct)

Latency is one axis of calibration; **pitch is the other**. Any module
receiving V/oct from cv-router (ES-9 panel CV, ESX-8CV, ES-5 channels
configured for CV) needs verification that 0V/+1V produce the expected
reference pitch and exactly one octave above it. CV chains drift with
temperature and have per-DAC offset/gain errors that aren't captured by
the latency framework.

- [ ] **Tuner / reference pitch source available** — guitar tuner with
  modular input, a known-tuned reference VCO, or a calibrated synth
  voice you can A/B against.
- [ ] **Identify each CV-routed pitch destination in the session.** What
  patches to what:
  - Plaits V/oct ← which ES-9 panel out / ESX-8CV slot?
  - Other VCO V/oct inputs same question
  - Maths attenuator-as-pitch-source (rare but happens) same
- [ ] **Reference-pitch test:** send `cv <bus> 0.0 voct` and check that
  the destination module produces the expected reference note (typically
  C2 at 0V in the cv-router convention; verify with your tuner).
- [ ] **Octave test:** send `cv <bus> 1.0 voct` and verify the
  destination module produces exactly +1 octave (12 semitones up). If
  off by more than ~5 cents, compensate either in module trim (some
  modules expose this) or in software via a per-binding gain/offset
  (not yet implemented in purerl-tidal — flag for rig-doctor).
- [ ] **Multi-octave test if accuracy matters:** repeat at +2V, +3V to
  rule out cumulative DAC nonlinearity. ESX-8CV is 12-bit so expect
  some quantisation; ES-9 panel CV is 24-bit and should be linear to
  ear precision across its full range.
- [ ] **Pitch tuning is per-module, latency is per-chain.** They're
  orthogonal — don't conflate them. A module can be perfectly in tune
  but late on the trigger; or perfectly on-time but a quarter-tone flat.

## Calibration setup

- [ ] **Same audio path on both L and R if possible** — using identical
  samples on both channels eliminates attack-time-difference bias in
  the cross-correlation analyzer. When L and R are different
  instruments, the per-onset analysis is biased by the difference in
  their attack times (typically a few ms).
- [ ] **Recording side is part of the calibration chain** — different
  Live projects, track groupings, and PDC settings will produce
  different lat values for the same source-side hardware. Re-calibrate
  when moving a destination to a new Live setup.

## Acceptance test for "calibration ready"

After all the above, fire one short pattern as a sanity check before
the real session:

```
live-tick "x x x x"
es5g1 "x x x x"
```

Record one bar in Live. Run `python3 /tmp/p3-analyze.py <path>`.
Expected: median offset within ±10 ms of zero, std under 10 ms.
If either fails: troubleshoot before recording the real session.

---

## Mid-session sanity

- **Stability matters more than absolute precision.** A consistent
  offset that the operator can dial out by ear is a working rig; an
  offset that drifts during a session is a broken rig.
- **Per-voice latency micro-control is the right UX answer**, not
  ever-more-precise pre-session calibration. Once chain-specific
  latencies are reliably stable, the human ear (or a Tangle-style
  inline knob) is the final tuning step.
