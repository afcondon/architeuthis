# fh2-config → purerl-tidal fold-in plan

**Status:** **ABANDONED 2026-05-14, same day the doc was written.** Kept for historical context and for future reference if conditions change.

**Why abandoned:** Phase 1 discovery (the module classification + package-set survey in this doc's predecessor sections, plus a follow-up cross-reference) revealed that the fold-in is structurally a *trapdoor* decision, not the incremental phased migration the doc proposes. Concretely:

- purerl-tidal uses the legacy purerl 2022-06-29 package set; fh2-config is built against registry 76.1.1. Package *names* overlap, but version skew is large (e.g. `parsing` v6 vs v10, `prelude` v5 vs v6).
- The 5 impure fh2-config modules (`Main`, `Daemon`, `Live`, `ClaimPersist`, `JsonParse`) are all built on `Aff`, which is not in purerl's package set in any compatible form. Aff-based Node async I/O has no natural Erlang counterpart that doesn't require rewriting.
- Once we cross-compile the pure subset and write Erlang FFI for the rest, the Node app effectively becomes a fork in maintenance terms — every change to fh2-config has to land in both worlds. That cost dominates the latency win.

Andrew's framing: *"we'd realistically be forking and abandoning the node app."* The fold-in benefits (sub-ms verb latency, one less external daemon, multi-FH-2 from same process) do not outweigh the cost of dual-backend maintenance or full-fork.

**Reopen this plan if:** (a) purerl-tidal migrates to registry-based package sets, AND (b) Aff lands in that set in an Erlang-compatible form, AND (c) someone wants to absorb the Node-app fork cost or rewrite fh2-config's I/O layer in Erlang from scratch.

**What stays useful in this doc:** the module classification (26 pure vs 5 impure), the package-set survey, the gen_server architectural sketch, and the multi-device direction. If a future session revisits, start from "What's actually here today" rather than from scratch.

---

(Original doc below — preserved verbatim. Treat as historical, not as a plan.)

---



## Goal

Collapse the standalone `fh2-config` daemon into purerl-tidal as a **pluggable, live-loadable in-BEAM Erlang process**. Support multiple FH-2 instances. Leave room for other device drivers (es9-config, future ES-5 control) to plug in the same way without re-shaping the architecture.

## Why now

1. **One fewer external daemon.** DeepStar tier-1 shrinks to `cv-router + link-spike`. The fh2-config daemon's PID, socket file, and restart story all disappear from the rig's process surface.
2. **Sub-ms verb latency.** Today's `~10ms` per write (socket roundtrip) becomes a `gen_server:call`. Adds up in dense polysignal mutations.
3. **Multi-FH-2 becomes natural.** One process per device, addressed by name.
4. **Generalisable.** The same pattern (PureScript code as library + thin gen_server wrapper) applies to es9-config and future device drivers.

## What stays unchanged

- The `port-claims-design.md` model: `BankMask`, `ClaimMask`, `OwnerId`, `applyClaim`, capability validation, eviction records.
- The wire shape of `apply-polysignal <json>`, `apply-drumkit <json>`, `apply-tvoice <json>`. Today purerl-tidal forwards these to the socket; tomorrow it calls a gen_server. The payload doesn't change.
- The `fh2-config` PureScript repo at `music/expert-sleepers/fh2-config`. It stays exactly where it is. The CLI still works for offline operations (`--list-modes`, `--apply-mode-offline`, `--selftest`, `--text-roundtrip`, …) without any change.
- Persistence at `~/.fh2/claims.json`. Same file, same atomic-write semantics. The gen_server reads/writes it.
- The PureScript validation, capability check, and silencer-pipeline modules. They get reused verbatim, just called from Erlang instead of from a daemon process.

## What goes

- The standalone `fh2-config --daemon` process. After Phase 6, DeepStar no longer starts it.
- The `~/.fh2/control.sock` socket file. No longer needed.
- The `viaDaemonOr` routing in `fh2-config/src/Main.purs`. CLI verbs that target a live device either get retired or rewired to talk to purerl-tidal over WS. **Decided 2026-05-14: no need to preserve daemon-aware CLI verbs — Phase 4 (socket listener) is cut entirely.**

## Architecture

```
                Calypso / wscat / future clients
                              │
                              ▼  WebSocket :3012/ws
                ┌─────────────────────────────────┐
                │     purerl-tidal (BEAM)         │
                │                                 │
                │     tidal_dispatcher            │
                │           │                     │
                │           │ gen_server:call     │
                │           ▼                     │
                │     tidal_fh2_devices (sup)    │
                │           │                     │
                │   ┌───────┼───────┐             │
                │   ▼       ▼       ▼             │
                │  fh2_a   fh2_b   fh2_c          │
                │  gen_   gen_    gen_             │
                │  server server  server          │
                │   │       │       │             │
                │   ▼       ▼       ▼             │
                │  applies FH2.PortClaim,        │
                │  FH2.Encode, FH2.Silencer …    │
                │  (purerl-compiled PureScript)  │
                └───────┼───────┼───────┼─────────┘
                        │       │       │
                        ▼       ▼       ▼     MIDI SysEx (CoreMIDI)
                       FH-2    FH-2    FH-2
```

Each `tidal_fh2_device_<name>` gen_server is the in-BEAM equivalent of one fh2-config daemon instance: it owns the device's `Config`, `ClaimRig`, `McvAlloc`, and persistence handle, validates cell-text verbs, runs the silencer pipeline, encodes Config + Preset, sends SysEx.

The PureScript code (`FH2.PortClaim`, `FH2.Encode`, `FH2.Silencer`, `FH2.PolyBank`, …) is shared as a library dependency — purerl-tidal's spago.yaml adds a path dep on `../../expert-sleepers/fh2-config`. Both projects compile the same modules; purs-backend-erl produces the same .erl artefacts; the BEAM ends up with `fH2_portClaim@ps:applyClaim/2` and friends callable from any Erlang module.

## Phase plan

In order. Each phase is independently shippable and reversible — if a phase reveals a problem, we can stop or roll back without breaking the daemon path that came before.

### Phase 1 — Library-ify fh2-config (foundation)

Make fh2-config a PureScript path dependency of purerl-tidal. No behavioural change; just verify the build pipeline.

- Add to `music/live-coding/purerl-tidal/spago.yaml`:
  ```yaml
  workspace:
    extraPackages:
      fh2-config:
        path: ../../expert-sleepers/fh2-config
  ```
- Add `fh2-config` to purerl-tidal's `dependencies:`.
- Verify `make build` ends up with `fH2_portClaim@ps.beam`, `fH2_encode@ps.beam`, etc. in `ebin/`.
- Smoke test from Erlang shell: `('fH2_portClaim@ps':emptyTable())()` returns the expected record.
- Update purerl-tidal Makefile's explicit erl list if needed (per memory `reference_purerl_tidal_makefile_explicit_erlang_list`).

**Exit criteria:** purerl-tidal still passes its existing tests; fh2-config modules are reachable from Erlang shell.

### Phase 2 — Single-device gen_server, no wire-protocol exposure

Implement `tidal_fh2_device` as a gen_server. Singleton for now — multi-FH-2 comes in Phase 5.

- New file `src/tidal_fh2_device.erl`. State record: `#{name, config, claim_rig, mcv_alloc, midi_out_port, claims_path}`.
- Init: read `~/.fh2/claims.json` if present (call the existing PureScript persistence module), open CoreMIDI output port, request a config dump from the device.
- Handle calls:
  - `{apply_polysignal, Json}` → call `FH2.PolyBank.parseAndApplyPolyBank` (or its claim-rig-aware sibling once Phase 4b of port-claims lands), build new state, persist, send SysEx, reply `{ok, Reply} | {error, Err}`.
  - `{apply_drumkit, Json}` → same shape via the drumkit path.
  - `{apply_tvoice, Json}` → same via tvoice.
  - `{apply_envelope, …}` etc. — one arm per existing daemon verb.
- Add child spec to `purerl_tidal_sup` (or a sub-supervisor — decided in Phase 5).
- Do **not** open a Unix socket yet. The gen_server is reachable only from inside the BEAM.

**Exit criteria:** unit tests for the gen_server (using EUnit or proper) covering the same scenarios the daemon's integration tests do today. No external clients yet.

### Phase 3 — Rewire purerl-tidal's WS verb forwarders

Replace today's "open socket, send line, parse reply" code in `tidal_dispatcher` (and wherever else the WS handler forwards) with `gen_server:call(tidal_fh2_device, …)`. The wire shape between Calypso and purerl-tidal doesn't change; only the in-purerl-tidal hop changes.

Keep a **feature flag** so both paths can coexist during transition:
- `application:get_env(purerl_tidal, fh2_path, daemon)` defaults to `daemon` (today's behaviour) or `in_beam` (new path).
- Once `in_beam` is verified across a few rig sessions, flip the default and remove the flag.

**Exit criteria:** flipping the env var routes verbs to the gen_server; cell-fire latency drops visibly; rig audibly behaves the same as before.

### Phase 4 — CUT (2026-05-14)

Originally: Unix socket listener inside the gen_server for backward CLI compatibility.

**Decided 2026-05-14**: no backward CLI compatibility needed. Phase 4 is removed from scope. CLI verbs that target a live device get retired or rewired to talk to purerl-tidal over WS as part of Phase 6.

### Phase 5 — Multi-FH-2 supervisor + named devices

Switch from singleton gen_server to a `simple_one_for_one` supervisor `tidal_fh2_devices_sup`. Each child is a `tidal_fh2_device` registered under a name (`fh2_a`, `fh2_b`, …).

Cell-text grammar extension:
- Bare `polylfo myLfo main` → routes to the device aliased as `fh2` (today's implicit single device).
- Explicit `polylfo myLfo fh2b:main` → routes to the named device.
- A new boot-time verb `register-device fh2b "FH-2 #2"` (CoreMIDI port substring match) attaches a second FH-2.

The port-claims-design's `Bank` type extension already supports this — `BankFh2 Fh2Bank` becomes `BankFh2 DeviceId Fh2Bank`, where `DeviceId` is the device alias. ClaimMask continues to be device-aware because `Bank` ordering distinguishes per-device banks.

**Exit criteria:** two FH-2s on the same rig, each addressable by name, claims don't cross-pollute.

### Phase 6 — Retire the standalone daemon

- Remove `fh2-daemon` from `music/live-coding/deepstar/services.py`.
- Update the marginalia FH-2 config entry: description notes the daemon is no longer separate; the fh2-config repo is library-only + CLI for offline work.
- Update memories: `reference_fh2_config_daemon` rewritten or retired.
- Remove fh2-config's `--daemon` entry point and the `viaDaemonOr` routing for live-device verbs in `fh2-config/src/Main.purs`. The CLI keeps offline verbs (`--list-modes`, `--apply-mode-offline`, `--selftest`, `--text-roundtrip`, …) — these don't need a device.

**Exit criteria:** rig comes up via `deepstar up` with only cv-router + link-spike + purerl-tidal; FH-2 operations work as before.

## Open questions

Three things to decide before Phase 2 lands:

1. **Where does `tidal_fh2_devices_sup` sit in the supervisor tree?** Direct child of `purerl_tidal_sup`, or a sibling at the application level? Today's `purerl_tidal_sup` is `one_for_all` — a device crash should NOT kill `tidal_voice_sup`, `tidal_dispatcher`, etc. So `tidal_fh2_devices_sup` should probably be a `one_for_one` peer at the app level, started by `purerl_tidal_app:start/2` alongside `purerl_tidal_sup`. Worth confirming during Phase 2.

2. **Generic device-driver pattern?** Should we extract a `tidal_device` behaviour (or just a naming convention) from day one so es9-config can follow the same shape, or wait until we actually do es9-config and abstract retrospectively? I lean **wait** — premature abstraction risks fitting es9-config to a shape that doesn't actually serve it. Concrete first, abstract on demand.

3. **Hot-load story.** The user wants "live-load-able". The natural recipe is: edit fh2-config PureScript → `spago build` → purs-backend-erl → erlc → `code:load_file/1` from a `reload-fh2` verb in purerl-tidal. The gen_server keeps running, picks up the new code via Erlang's hot-code-swap conventions (which work cleanly for stateless function dispatches; trickier if state shape changes). Probably worth a small additional doc on the hot-load mechanics once Phase 2 is solid.

## Risks

- **Build pipeline crosstalk.** fh2-config has its own tests, its own Makefile, its own `output/` dir. Adding it as a purerl-tidal dep means purerl-tidal's build also walks fh2-config's source tree. Need to check that `make build` doesn't redundantly run fh2-config's tests or otherwise misbehave.
- **State shape changes** in fh2-config (e.g. a new field added to `ClaimRig`) would invalidate `~/.fh2/claims.json` from older versions. The daemon today handles this via "missing file → empty state; parse error → warn + empty state". The gen_server keeps this behaviour, so the worst case is "claims reset on next boot after schema change" — annoying but not destructive.
- **CoreMIDI port ownership.** Two processes (the old daemon and the new gen_server) cannot both open the same FH-2 MIDI port. Phase 3's feature flag must ensure only one of them holds the port at a time. The flip is "stop the daemon, start the gen_server"; coexistence is the failure mode.

## Memory pins to update post-completion

- `reference_fh2_config_daemon` — daemon no longer external; replace with "fh2 driver is a gen_server inside purerl-tidal at `tidal_fh2_device`".
- `project_fh2_config_single_binary_future` — was "not now", now done. Replace with a retrospective summarising what worked.
- `reference_feedback_daemonize_when_boot_tax_is_in_hot_path` — keep, but add a footnote: "for libraries that already share a runtime with their caller (e.g. PureScript driver + purerl-tidal both compile to BEAM), folding into the same OS process is cleaner than running a separate daemon."

---

**Recommended starting point:** Phase 1 + Phase 2, in one or two sessions. That gets the foundation in place and the gen_server reachable from `gen_server:call`, but doesn't touch the WS verb path yet — so today's daemon keeps serving production. Phase 3 (rewire) is the next session after Phase 2 ships and is verified.
