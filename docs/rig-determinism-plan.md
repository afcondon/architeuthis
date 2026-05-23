# Rig determinism plan

A focused session to make the live-coding rig deterministic, observable,
and self-healing.  Scope is the *internal* developer experience — getting
to a state where editing PureScript, restarting services, and reloading
sessions all "just work" without manual archaeology across logs and port
state.

A separate later session will polish the rig for new-user UX; this one is
groundwork.

## Background — pain points from 2026-05-22..23

The following symptoms surfaced during the Vetula expressivity work and
together motivate the slabs below.  Each is a real incident, not a
theoretical concern.

- **`spago build` reports success but BEAMs stay stale.**  `spago build`
  generates `output-erl/*.erl` files; the `erlc → ebin/*.beam` step is a
  separate `make erl` target.  Forgetting it surfaces as `undef` at
  runtime when the new function is called from a session cell.
- **`make erl-quick` itself sometimes doesn't recompile** an updated
  `.erl` file.  Confirmed instance: 2026-05-23 morning, `output-erl/.../tidal_vetula_pattern@ps.erl`
  had mtime 07:25, `ebin/tidal_vetula_pattern@ps.beam` had mtime 22:16
  from the previous evening, yet `make erl-quick` reported success
  without rebuilding.  Manual `erlc` on the file fixed it.  Root cause
  unknown — likely a mtime-tracking subtlety in the `find ... -exec`
  pattern.
- **Zombie BEAM holds port 3012 across config changes.**  When the
  `services.py` `cmd` field was changed from direct `erl` to a
  `bash -c '… && exec erl …'` wrapper, the old direct-erl BEAM became
  untracked.  DeepStar's `down` SIGTERMed something else; the BEAM
  survived and bound 3012; next `up` got `eaddrinuse`.
- **DeepStar's 5-second port-bind deadline is too tight** for any
  startup command that includes a cold `spago build`.  Manifested as
  `make: *** [erl] Terminated: 15` when the wrapper approach was tried.
- **Port claims persist across session reloads.**  Loading a session
  that doesn't declare `bass1` still produced a "duplicate claim on iac
  ch 1 — already claimed by instrument `bass1`" error, because a
  previous session's claim was never released by `reload-baseline`.
- **`tidal_clock` `function_clause`** on an `info` message containing
  a `{tidal_link_anchor, …}` tuple.  Task #97 added a defensive `info`
  clause; presumably regressed or the BEAM is stale (see first two
  bullets).
- **Diagnosis required four sources** every time: DeepStar logs at
  `/tmp/deepstar/`, `lsof` on the relevant port, `ps` on suspect
  PIDs, and reading source vs. compiled module exports via `beam_lib`.
  No single command answers "is the rig healthy?".

## Goal

After this session, the answer to *each* of the following questions is
"yes, with no extra ceremony":

- If I edit a `.purs` file and run one command, will the running BEAM
  see my change?
- If I reload a session, can I trust that no orphaned claims from prior
  sessions affect it?
- If a service is in a bad state, can I see the full picture in one
  command's output?
- If a process is wedged, can I cleanly kill and restart it without
  manual `lsof`/`kill` archaeology?

## Slabs

In priority order.  Each is sized for what's gettable in a focused
session; the whole list is ~half a day if everything lands.

### Slab A — Build determinism  *(60–90 min, highest priority)*

Symptoms addressed: stale BEAMs causing `undef` / `function_clause`,
`make erl-quick` silently skipping.

- Investigate the 2026-05-23 incident where `make erl-quick` ran but
  didn't recompile `tidal_vetula_pattern@ps.erl` despite a clear mtime
  difference.  Likely the `find output-erl -name '*.erl' -exec erlc -o
  ebin {} \;` form doesn't compare against the target `.beam`'s mtime —
  erlc only refuses based on its *own* output staleness check, which may
  not work as expected.
- Replace the loop with explicit per-file mtime comparison, *or* use
  `make`'s own rule-based tracking (one target per `.beam`, depending on
  its `.erl`).  The latter is the right Make-shape.
- Add `make doctor`: walk `output-erl/` and report any `.erl` newer than
  its corresponding `.beam`.  Exit non-zero if anything's stale.
- Wire `make doctor` into a DeepStar pre-flight check (a new field on
  the service definition, run before `cmd`).  If `doctor` fails,
  surface the report and refuse to start.

### Slab B — Session walker claim hygiene  *(30 min)*

Symptoms addressed: "duplicate claim" errors from stale prior sessions.

- On `reload-baseline`, clear all existing port claims before re-walking
  the new `Session` value.  Claims become a strict function of the
  *current* session, not the union of all sessions ever loaded.
- Localised fix in `tidal_session_walker.erl` (or wherever the claim
  registry lives).  Confirm the registry is per-session-scoped, not
  global-accumulating.
- Acceptance: fire session A claiming `iac ch 1`, then fire session B
  claiming `iac ch 5` with no `iac ch 1` instrument.  No "duplicate
  claim" warning when B is fired.

### Slab C — DeepStar lifecycle robustness  *(45 min)*

Symptoms addressed: zombie BEAMs, untracked PIDs, hard-coded 5s timeout.

- `deepstar down <svc>` should verify the service's port is actually
  freed after SIGTERM.  If not, escalate to SIGKILL after a grace
  period.
- `deepstar up <svc>` should detect "port already bound by an untracked
  process" and refuse-with-context (show which PID, suggest `down -f`)
  rather than failing on bind inside the spawned process.
- Make port-bind deadline configurable per service: a new
  `startup_timeout_s` field on the service definition, default 5,
  override to 15 for purerl-tidal if we ever want to wrap with a build
  step again.
- Acceptance: `kill -9` purerl-tidal mid-session, then
  `deepstar up purerl-tidal` recovers cleanly with no manual `lsof` /
  `kill` dance.

### Slab D — Single `rig doctor` command  *(30–45 min)*

Symptoms addressed: multi-source diagnosis archaeology.

- One CLI subcommand (likely `deepstar doctor` or a new top-level
  `rig-doctor`) outputting a one-page report:
  - Tier-1 service status (port bound?  PID alive?  recent error from
    log tail?).
  - All listening ports in the rig's range + their owners — flag any
    that's *not* a tracked DeepStar child.
  - Stale BEAMs (delegated to `make doctor`).
  - Claim registry contents (what's claimed by what).
  - Calypso disk-vs-buffer divergence (if detectable from the API).
- Mostly stitches together state that already exists; the value is in
  the *one* command, not the individual probes.

### Slab E — Calypso buffer ↔ disk discipline  *(deferred to a separate session)*

Symptoms addressed: fire-typeful blasting a stale buffer over disk
fixes; no way to refresh the buffer from disk.

Out of scope for this rig-determinism pass.  Track as its own follow-up.
Likely solutions: "refresh from disk" button on the composition pane;
detect external disk changes before fire-typeful and warn; or designate
one side as authoritative and surface the discrepancy in the UI.

## Out of scope

- The new-user UX pass Andrew flagged earlier (separate, deliberate
  follow-up).
- Cross-machine canonical / sync concerns (MBP vs MacMini topology).
- Tidal_clock crash fix (already implemented as task #97; Slab A will
  ensure the fix is actually loaded in the running BEAM).
- The Slab E Calypso buffer/disk reconciliation (deferred).

## Definition of done

This acceptance sequence should run end-to-end with no surprises and no
manual intervention beyond the listed commands:

1. **Build determinism.**  Edit a function body in
   `src/Tidal/Vetula/Pattern.purs`.  Run `deepstar restart purerl-tidal`.
   Fire-typeful a cell that calls the changed function.  Hear the change.
2. **Claim hygiene.**  Load session A claiming `iac ch 1`.  Then load
   session B claiming `iac ch 5` with no `iac ch 1` declaration.  No
   warnings, no orphaned bass1 voice in the dispatcher.
3. **Lifecycle robustness.**  `kill -9` purerl-tidal during normal
   operation.  Run `deepstar up purerl-tidal`.  Service recovers cleanly;
   no manual `lsof`/`kill` sequence.
4. **Observability.**  Run `deepstar doctor` (or equivalent).  Output
   tells the truth: nothing flagged when the rig is healthy; clear
   diagnosis when something's wrong (stale BEAM, zombie port owner,
   stuck claim).

## Estimated time

- Just Slabs A + B (closes the most painful traps): **2–3 hours**
- A + B + C + D (the full plan): **half a day**

Slab A alone is the highest-leverage hour — if we run out of time, A is
the one to land.
