# Studio Pane Day — vmods, low-latency Studio.purs, visual port claims

**Status:** Plan draft (2026-05-18).  Sketched after the Phase 2
reservations work shipped and the BEAM-native virtual modules idea
expanded into three orthogonal axes.

**Premise:** the Studio pane in Calypso is the music IDE's "Audio/
MIDI Setup" view — the read-mostly, configuration-shaped surface
where the rig is described.  This plan converges three workstreams
that all hinge on the Studio pane's data model and lifecycle:

1. **BEAM-native virtual modules** (vmods) — first-class
   instruments in the Studio, peer to today's `Instrument` and
   `DrumKit`.  Substrate, then polysignal family ported as device-
   agnostic vmods (runnable against FH-2 or ES-9).
2. **Low-latency Studio.purs editing from Calypso** — the
   composition pane's per-cell compile pipeline applied to the
   Studio module.  Sub-second iteration on rig declarations.
3. **Visual port claims (SVG)** — render the rig graphically with
   per-port glyphs showing which alias claims what, click-to-jump
   from port to declaration, optional gate-flash verify.

The framing: a music IDE is a tool that lets you **operate directly
on the structure of the music-making machine**.  All three of
these workstreams make the rig-machine structure more directly
manipulable.  The "polyfacetic peer pattern languages" idea is
parked — it's not what this is about; this is about a substrate
that's *itself* compositionally rich enough to need a serious IDE.

## Companion docs

- `docs/frontend-reservations-plan.md` — Phase 1a/1b shipped, Phase
  2 (unified PortClaim + ES-9 banks) shipped, Phase 1b-2 (visual
  Studio) is workstream 3 here.
- `fh2-config/docs/port-claims-design.md` — the backend model the
  visual layer renders.
- Memory `project_beam_native_virtual_modules` — original idea
  capture; the three-axes framing below extends it.

---

## The three orthogonal axes

The vmod design space is three-dimensional.  Each axis adds a
degree of freedom; a given vmod sits at a point.

| Axis              | Range                                              |
|-------------------|----------------------------------------------------|
| **Device**        | FH-2 / ES-9 / future devices (any with banks)      |
| **Complexity**    | Fixed CV → Bare LFO → Marbles → Metropolix         |
| **Multiplicity**  | 1 output → 3 outputs → N outputs (clock groups)    |

Designing the vmod ABI to be orthogonal in all three axes is the
core technical bet.  Each new vmod then lives at a point in the
space without forcing redesign of the substrate.

### Axis 1: Device-agnosticism

Today's FH-2 polysignals (polylfo, polyclock, polyenv, polyeuclid,
polyeuclid-pairs, polyrand) are *family vocabularies* — a parameter
language for a kind of generator.  The hardware that runs them is
incidental.

**Key realisation:** the polysignal family can run *just as well*
on the ES-9, with cv-router as the transport.  Same parameter
vocabulary, same algorithm, different output tail.  The PortClaim
machinery shipped 2026-05-17 already supports both bank families;
the polysignal vocabulary becomes the first device-agnostic
construct in the system.

```
polylfo myL rate=0.5 spread=0.3 routedTo fh2.main      -- runs in fh2-config
polylfo myL rate=0.5 spread=0.3 routedTo es9.panel     -- runs as vmod
```

Implementation: each polysignal becomes a vmod with two transport
backends (FH-2 SysEx via fh2-config, cv-router OSC for ES-9).  The
vmod's PureScript-side algorithm is shared.

### Axis 2: Complexity

The complexity range goes from "fixed value" (trivial) to
"Marbles-class algorithm" (rich) to "Metropolix-class mod-matrix"
(rich + structurally non-trivial).

The substrate work happens at the *low* end — a fixed CV emitter
is the simplest possible vmod.  Building it first proves out the
architectural surface (gen_server lifecycle, PortClaim integration,
parameter mutation, PrimAction emission) without the additional
weight of algorithm design.

### Axis 3: Output multiplicity

Single-output vmods are the common case.  But multi-output vmods
unlock compositional compactness: one declaration emits N
coordinated streams sharing one piece-structural awareness.

Section dispatchers are the canonical multi-output case:

```
clock-group {
  grid:     16ths
  pulse:    4-on-the-floor
  marker:   bar triggers
  sections: A B C D                -- four section gates
}
```

Seven outputs from one declaration.  Each level is a pattern of
the previous level's triggers (16th < beat < bar < section).  This
is where the parameter language really earns its keep — without
it, you'd need seven separate declarations awkwardly correlated
by shared parameters.

---

## Workstream 1: vmod substrate

### Building order

1. **`cv-preset`** — the simplest vmod possible.  Emits a constant
   voltage in [-5V, +5V] on a single bus until told otherwise.  No
   clock subscription.  One parameter: the value.
   ```
   cv-preset bassA volts=2.4 routedTo es9.panel.0
   ```
   Exercises: gen_server lifecycle, PortClaim with new `OwnVmod`
   kind, parameter mutation via live-control bus, PrimAction
   emission via cv-router transport.  ~50 lines of Erlang + ~30
   lines of PureScript parser.  Sibling: `note-preset` (V/oct).

2. **Section dispatcher** — the canonical multi-output vmod.
   Declares a piece form `[A B C D]` with cycle counts; emits
   16ths, beats, bars, and one gate per section.  Owns the form
   (drives the conductor's section state).  Tests: time-hierarchy,
   multi-output, parameter-language compactness.

3. **`polylfo` as device-agnostic vmod** — the first polysignal
   ported.  Same parameter vocabulary as the FH-2 version;
   `routedTo fh2.main` dispatches via fh2-config, `routedTo es9.X`
   dispatches via cv-router.  Tests: device-agnosticism axis.

4. **Marbles clone** — the algorithm-rich case.  Stochastic gates
   with deja-vu / spread / bias / shift.  Three gates + three CVs.
   Tests: complexity axis at the high end.

Each step is independently shippable.  Steps 1 and 2 must come
first; 3 and 4 are interchangeable.

### Architectural surface

- **gen_server per vmod instance.**  Spawned on Studio walk;
  registered under `tidal_vmod_<alias>`.
- **Clock subscription.**  For vmods that need a clock tick
  (everything except `cv-preset` and `note-preset`), subscribe
  to the existing `tidal_clock` (or whatever the BEAM-side primary
  is — confirm during impl).
- **Parameter mutation via live-control bus.**  Existing substrate
  (`reference_purerl_tidal_live_control_substrate`); each vmod
  reads named-parameter updates from the same ETS-backed bus.
- **PortClaim integration.**  New `OwnerKind` constructor
  `OwnVmod`; claim made at vmod spawn; released at terminate.
  Conflicts surface in the Studio pane via the existing pipeline.
- **PrimAction emission.**  Vmod outputs flow through the
  dispatcher's `PrimAction` family.  No new wire protocol; vmods
  are upstream sources feeding existing downstream tails.

### Open design questions

- **Parameter language: uniform vs per-vmod-family?**  My instinct:
  uniform substrate (`name=value`, ramps, modulations) + family-
  specific *leaves* (rate / spread for Marbles; shape / smoothness
  for Tides).  One parser; family-specific schema.
- **Vmod lifecycle: Studio-declaration-only, or fireable from
  cells?**  Studio for the *binding* (which vmod where + initial
  params); cells for *parameter mutation* during play.  Mirrors
  the Studio-vs-Composition split.
- **State persistence: do running vmod states survive
  reload-baseline?**  Yes — gen_servers persist, only their
  initial parameters get reloaded; existing state stays unless
  the vmod's owner alias is removed from Studio.purs.

---

## Workstream 2: low-latency Studio.purs editing

### The problem today

Editing Studio.purs requires:

1. Edit the file (in an editor or the eventual Studio editor pane)
2. `make erl` — full spago build + purs-backend-erl + erlc over
   all output (~5–10s)
3. `deepstar restart purerl-tidal` (~3–5s)
4. `reload-baseline` from Calypso (~200ms)

Total: 10–20 seconds for any change.  Worse, the BEAM restart
loses all volatile state (current bindings, live-control values,
running vmod states once they exist).  This is the "Order(minutes)"
concern from the 2026-05-17 design discussion.

### What the per-cell compile pipeline does

Calypso's existing per-cell compile pipeline:

```
edit cell text
  → write tiny PS module to disk
  → purs compile (cached glob, ~200ms)
  → purs-backend-erl --filter <ModuleName> (~200ms)
  → erlc one .erl → .beam (~100ms)
  → WS hot-load into BEAM (code:purge + code:load_file, ~10ms)
  → reload-baseline (~200ms)
```

Total: ~700ms warm-toolchain.  See
`reference_purs_backend_erl_filter_scoped_emit`.

### What we want for Studio

Studio.purs is *structurally* one more module to compile and
hot-load.  The pipeline above applies as-is.

Implementation steps:

1. **Calypso server gets a `POST /studio-source` route** (mirror of
   `/session-source`).  Takes the new Studio.purs text; writes to
   `src/Studio.purs`; runs the same compile pipeline targeting
   `Studio` instead of `Calypso.Generated.Session`.
2. **Calypso frontend gets an editable Studio pane**, alongside
   the existing read-mostly view (Cmd-8 today).  Switch between
   view/edit mode.  Mirror the composition pane's CodeMirror
   surface.
3. **File ownership invariant:** Studio.purs has *one* writer
   (Calypso server when the user fires "save Studio").  External
   edits (in a text editor) are detected on next save with a
   "this file has diverged" prompt — mirrors what we need for
   the existing composition pane footgun
   (`reference_calypso_buffer_overwrites_disk`).

### Acceptance

- Adding `bass5 = midi iac 5` to Studio.purs via the Calypso
  editor + fire takes < 1 second to appear in the dispatcher.
- Conflict cases (`bass1b = midi iac 1`) surface in the Studio
  pane within the same < 1s window.
- External edits don't silently disappear; Calypso warns on
  divergence.

---

## Workstream 3: visual port claims (SVG)

### What the data model already supports

The Phase 2 PortClaim machinery exposes everything the visual
layer needs:

- Per-device declarations (`MidiDevice`, future `Es9Device`)
- Per-instrument / drum-kit / vmod claims with explicit slot
  ranges
- Capability per bank (Gate / CV / GateOrCV)
- Conflict surfaces with structured fields
  (`describeClaimError` for the human form, `claimErrorToBoundary`
  for the wire form)

The frontend can render this entirely from the existing
`get-studio` WS verb's output — no new backend protocol needed.

### What we want to render

Per-device SVG cards with port glyphs:

- **FH-2** — 8 panel jacks (the main bank), plus the GT bank
  (8 jacks) and CV bank (8 jacks) for FHX-8GT / FHX-8CV
  expanders if declared.  ES-5 bank for stages-style expanders.
- **ES-9** — main panel (8 jacks, the configurable ones) plus
  Phones L/R and Main L/R.  ES-5 + ESX-8CV / ESX-8GT regions
  if attached.
- **MIDI device** — 16-channel grid; each channel a port glyph.
  Drum kits with multiple per-hit channels span multiple cells.

Each port glyph carries:

- Owner alias (shown on hover, or always if zoomed)
- Capability (colour-coded: red gate-only, blue CV-only, purple
  GateOrCV)
- Conflict state (red border + warning glyph if conflicted)

Interactions:

- Click a port → jump to the Studio.purs line that claims it
  (requires Calypso server to track line numbers per claim during
  the SessionWalker pass — small extra in the registration event)
- "Verify" button per device → fires gate-flash on the daemon
  (FH-2 already has the fh2-config daemon; ES-9 needs the
  equivalent in cv-router, deferred)

### Layout: hand-curated or procedural?

My recommendation: **hand-curated SVG templates per device** in a
known location (`frontend/public/devices/fh-2.svg`,
`frontend/public/devices/es-9.svg`).  Each template has named
slots (`<rect id="panel-0">`, `<rect id="panel-1">`, …) that the
frontend addresses by name and overlays claim glyphs on.

Pros: drawings look right (each device has its real industrial-
design proportions); easy to add a new device (one SVG file).
Cons: requires drawing each device once, manually.

Alternative — procedural layout: render each bank as a grid of
N cells with text labels.  Less accurate visually but works for
any device automatically.

The hand-curated path matches Andrew's typographic priorities
better.  Start hand-curated; fall back to procedural for devices
without a template.

---

## Phasing

### Phase A: substrate + first vmod (the "day")

Single-session scope, roughly half a day if substrate goes well:

- `OwnerKind` extended with `OwnVmod`
- New PureScript module `Tidal.VMod` — the abstract vmod surface
  (lifecycle, parameter receive, output emit)
- New Erlang module `tidal_vmod_supervisor` — gen_server spawn/
  terminate, registry lookup
- `cv-preset` vmod implementation
- Studio.purs grows a vmod declaration form:
  `myA = cvPreset 2.4 (es9 0)`
- SessionWalker extracts vmod declarations as
  `RegisterVMod` registration events
- Round-trip test: declare → spawn → emit → claim conflict

### Phase B: low-latency Studio editing

Independent of Phase A; can happen in parallel:

- `POST /studio-source` Calypso server route
- Studio pane edit mode + save button
- File-divergence warning on save
- Acceptance test: add `bass5` to Studio in < 1s

### Phase C: section dispatcher vmod

Builds on Phase A substrate:

- Multi-output vmod ABI
- Form-aware vmod that drives the conductor's section state
- Parameter language: `clock-group { ... }` with sub-fields
- Section gates emit cleanly on transitions

### Phase D: polylfo as device-agnostic vmod

Builds on Phase A substrate + the existing FH-2 polysignal work:

- Refactor polylfo's algorithm to run vmod-side (vs FH-2-side)
- Two transport tails: fh2-config SysEx, cv-router OSC
- Verify the parameter language reads identically in both cases

### Phase E: visual port claims SVG

Builds on existing `get-studio` data:

- SVG templates for FH-2 and ES-9 (hand-curated)
- Frontend overlay engine: claim glyphs, conflict state
- Click-to-line interaction (requires walker to track line numbers)

### Phase F: Marbles clone

Algorithm-rich vmod proving the high-complexity end of axis 2.
Independent of E; can happen any time after A.

### Phase G: gate-flash verify on hardware

Adds the daemon-side gate-flash verb to both fh2-config and
cv-router; UI button per device in the SVG layer.

---

## Risks

- **Vmod gen_server count.**  One process per vmod instance is
  fine for a handful, but 100+ might stress.  Mitigation: not a
  concern for v1; revisit if usage grows.
- **Studio.purs file-ownership race.**  Same shape as the
  composition pane footgun.  Need a robust divergence-detection
  mechanism *before* shipping Phase B, or we'll silently revert
  edits again.
- **SVG drawing quality.**  Hand-curated is slow to start;
  procedural is ugly.  Phase E might be the longest single phase.
- **Section-dispatcher form ownership.**  "Owns the form" is the
  cleaner shape, but it requires reconciling with today's
  `Section :: Pattern AnyPart` conductor model.  Possibly a
  larger refactor than the rest of the phase.

## Open questions for the design session

1. Should the parameter language for vmods be PureScript syntax
   (Studio.purs declarations) or its own mini-language?  My
   instinct: PureScript syntax for the binding (Studio.purs),
   mini-language for parameter mutation (cell verbs).
2. Should the Studio editor pane fully replace the read-mostly
   pane, or be a separate edit-mode toggle?  Edit-mode toggle
   keeps the Audio/MIDI Setup analogue clean.
3. Is the section dispatcher the same construct as today's
   `Section :: Pattern AnyPart` (just with explicit output
   triggers), or a peer?  Possibly the same thing wearing two
   hats.
4. Cv-router gate-flash verb design.  Mirrors fh2-config's, but
   needs careful work to make sure the gate-flash audio reaches
   the right ES-9 panel jack(s).

---

## Definition of done for "Studio Pane Day"

A single concentrated session ships Phase A.  Plausibly the same
day or the next session covers Phase B in parallel.  Phases C–F
are subsequent dedicated work.

Minimum acceptance for the "day" verb:

- `cv-preset` vmod declarable in Studio.purs, claims an ES-9 bus,
  emits the right voltage on Calypso fire.
- PortClaim shows `OwnVmod` in conflict errors.
- (Stretch) Studio.purs edit + save from Calypso updates the
  dispatcher in < 1 second.

The plan above is more ambitious than one day; this section
sets the bar for what "day done" means.
