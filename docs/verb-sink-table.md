# Verb-vs-sink coverage table

> Step 1 of the foundation slab from `north-star.md` §8.
> Living artefact — when verbs or sinks change, update this file.
>
> The principle (from `north-star.md` §4): **consistent shape wins
> over consistent implementation**.  Cells use the same vocabulary
> regardless of sink; each sink consumes what it understands and
> ignores the rest.  Holes are honest and fall out for free.

---

## Legend

| Symbol | Meaning                                                                 |
|--------|-------------------------------------------------------------------------|
| **D**  | Direct — the sink natively understands the verb (built-in wire mapping) |
| **M**  | Mappable — sink consumes via per-rig config (CC table, CV jack assign)  |
| **—**  | No-op — silently dropped (no meaningful interpretation on this sink)    |
| **G**  | Global — affects the engine, not a single voice                         |
| **?**  | Unknown / not yet decided                                               |

The **M** cells are where the per-rig translation layer
(`north-star.md` §8 step 6) lives.  They're configuration data on
the Studio side, not code on the sink side.

The **—** cells are the price of consistent syntax.  A cell that
writes `# vowel "a"` against a MIDI drum kit silently ignores the
vowel — and that's correct.

---

## Sinks under consideration

| Column         | Wire format / process                                          |
|----------------|----------------------------------------------------------------|
| SuperDirt      | `/dirt/play` OSC bundles → localhost:57120 (sample player)     |
| MIDI generic   | Note-On/Off + CCs on a CoreMIDI destination, single channel    |
| MIDI drumkit   | Note-On per slot (sound → MIDI-note map), single channel       |
| FH-2 daemon    | SysEx writes through `~/.fh2/control.sock` (polysignal config) |
| CvRouter       | OSC to cv-router → ES-9 V/oct + Gate jacks                     |
| Yarns poly     | MIDI multi-channel poly mode (future)                          |

---

## Coverage table

| Verb (cell-side)   | SD    | MIDI generic   | MIDI drumkit | FH-2 | CvRouter         | Yarns poly |
|--------------------|-------|----------------|--------------|------|------------------|------------|
| **Source**         |       |                |              |      |                  |            |
| `note`             | D     | D              | —            | —    | D                | D          |
| `n`                | D     | —              | —            | —    | —                | —          |
| `sound`            | D     | —              | D (slot map) | —    | —                | —          |
| **Amplitude**      |       |                |              |      |                  |            |
| `gain`             | D     | D (→ velocity) | D (→ vel)    | —    | M (→ vel-CV)     | D (→ vel)  |
| `velocity`         | D     | D              | D            | —    | M                | D          |
| `pan`              | D     | M (CC10)       | M (CC10)     | —    | M                | M (CC10)   |
| `speed`            | D     | —              | —            | —    | —                | —          |
| `accelerate`       | D     | —              | —            | —    | —                | —          |
| **Envelope**       |       |                |              |      |                  |            |
| `attack`           | D     | M (CC73)       | —            | —    | M (env-CV)       | M (CC73)   |
| `release`          | D     | M (CC72)       | —            | —    | M (env-CV)       | M (CC72)   |
| `legato`           | D     | D (note-len)   | —            | —    | D (gate-len)     | D (gate-len)|
| `sustain`          | D     | M (CC?)        | —            | —    | —                | M          |
| **Filters**        |       |                |              |      |                  |            |
| `lpf`              | D     | M (CC74)       | —            | —    | M (aux-CV)       | M (CC74)   |
| `lpq`              | D     | M (CC71)       | —            | —    | M                | M (CC71)   |
| `hpf`              | D     | M              | —            | —    | M                | M          |
| `hpq`              | D     | M              | —            | —    | M                | M          |
| `bpf`              | D     | —              | —            | —    | —                | —          |
| `bpq`              | D     | —              | —            | —    | —                | —          |
| **Effects**        |       |                |              |      |                  |            |
| `room`             | D     | M (CC91)       | —            | —    | —                | M (CC91)   |
| `size`             | D     | M (CC?)        | —            | —    | —                | M          |
| `delay`            | D     | M (CC?)        | —            | —    | —                | M          |
| `delaytime`        | D     | —              | —            | —    | —                | —          |
| `delayfeedback`    | D     | —              | —            | —    | —                | —          |
| `crush`            | D     | —              | —            | —    | —                | —          |
| `shape`            | D     | —              | —            | —    | —                | —          |
| `vowel`            | D     | —              | —            | —    | —                | —          |
| **Pitch / timing** |       |                |              |      |                  |            |
| `coarse`           | D     | M (PB)         | —            | —    | D (semitone-CV)  | M (pgm)    |
| `cut`              | D     | M (note-off)   | D (cut group)| —    | D (gate-off)     | D          |
| `nudge`            | D     | D (schedule δ) | D (schedule δ)| D   | D                | D          |
| `begin`            | D     | —              | —            | —    | —                | —          |
| `end`              | D     | —              | —            | —    | —                | —          |
| `loop`             | D     | —              | —            | —    | —                | —          |
| **Global**         |       |                |              |      |                  |            |
| `cps` / `bpm`      | G     | G              | G            | G    | G                | G          |
| `unit_`            | D     | —              | —            | —    | —                | —          |
| `orbit`            | D     | —              | —            | —    | —                | —          |
| **Sufflamen only** |       |                |              |      |                  |            |
| polysignal record  | —     | —              | —            | D    | —                | —          |
| **Vetula only**    |       |                |              |      |                  |            |
| chord / voicing    | (via N) | (via N)      | —            | —    | (via N)          | D          |

"via N" = via the `Notation`-shaped expansion of a chord into N parallel
note events; each note event then follows the row's column rules.

---

## How to read this table

- **A row tells you "which sinks understand this verb."**  `gain` is
  D-or-M everywhere except FH-2 (which is a config sink, not a note
  emitter).  `vowel` is D on SD only — that's a SuperDirt-specific
  formant filter.  Cells writing `# vowel "a"` against any other
  sink silently no-op.

- **A column tells you "what this sink accepts."**  SD's column is
  almost all D — it's the canonical sample-player target and the
  vocab was designed against it.  CvRouter's column is mostly M —
  modular synthesis requires per-rig patching decisions.  FH-2's
  column is almost all — — it doesn't emit events at all, it
  consumes polysignal config records.

- **The M cells are work, but configurable.**  Each M cell becomes
  one line in a Studio-level destination declaration:

  ```purescript
  ableton_piano1 = midiInstrument
    { channel: 5
    , ccMap:
        { lpf:     CC 74
        , room:    CC 91
        , attack:  CC 73
        , release: CC 72
        , pan:     CC 10
        }
    , defaults: { velocity: 90 }
    }
  ```

  The cell that writes `# lpf 800 # room 0.4 # gain 0.7` then emits
  the right CC frames at runtime, no sink-side code change required.

- **The — cells are the price of consistent syntax.**  We
  deliberately don't make `vowel` work on a MIDI drum kit by some
  contrived mapping.  If you want vowel-filter formant
  modulation, route to a sink that has it (SD) or to a soft-synth
  whose formant CC you've mapped via the **M** layer.

---

## What this table is missing (TODO)

- **Sufflamen-specific verbs.**  Once Sufflamen's typed PolySignal
  record is firmed up (currently in `Tidal.Polysignal*` modules under
  task #59), add its verb surface as a separate row group.
- **Vetula-specific verbs.**  Once Vetula lands (task #134), add its
  `voicing`, `progression`, `leading` etc. as a row group, with the
  caveat that they expand to N parallel `note` events per chord.
- **Live-control bus verbs.**  `live "name"`-style reads are
  cross-cutting and not per-sink; document separately when the
  typed-bus work (task #150) lands.

---

## Provenance

Initial population from a survey of `src/Tidal/Controls.purs` (atlantis,
14 verbs) + the wider SuperDirt vocab implemented in
`purerl-tidal-port` (34 verbs, the lpf/hpf/room/vowel family
expansion), 2026-05-22.  Sinks surveyed from
`src/Tidal/Dispatch/`, `src/balistes_voice.erl`, `src/rene_voice.erl`,
`src/repetitor_voice.erl`, and `src/virtual_polysignal_voice.erl`.

The wider SD vocab (lpf/hpf/room/attack/etc.) is in purerl-tidal-port
but not yet in atlantis.  Either port back, or add new SD-only verbs
incrementally as cells call for them.
