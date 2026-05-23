-- | Sessions.Phase4Odonus — René machine at 16 stepsPerCycle, advancing
-- | every tick (no euclidean gate).  Head-to-head with Phase 3 dense.
-- |
-- | Same emit rate as Phase 3 60 BPM (4 notes/s = 250 ms IOI) and
-- | Phase 3 120 BPM (8 notes/s = 125 ms IOI), same MIDI note (36 =
-- | c2), same channel (IAC ch1).  The only path difference from
-- | Phase 3 is the vmod gen_server's per-step processing — so any
-- | jitter delta is René-attributable.
-- |
-- | All 16 notes pinned to MIDI 36 so the recording reads like a
-- | flat dense pattern.  No skipping (skip=false), no glide, all
-- | gates on, NavForward.  Advance is `pure true` — engine steps on
-- | every clock tick.  Live-control bus reads disabled
-- | (`liveIntArrayOr`'s "Or" branch is the static array) so the
-- | engine path is purely deterministic.
-- |
-- | To activate: copy this file's content over
-- | `src/Calypso/Generated/Session.purs` (with module rewritten to
-- | `Calypso.Generated.Session`), update calypso-session.json to a
-- | single `studioOdonus`-firing cell, fire-typeful, then ▶ the cell.
module Sessions.Phase4Odonus where

import Calypso.Prelude
import Studio (iac)
import Data.Functor (map)

phase4Odonus :: Odonus "phase4Odonus"
phase4Odonus = odonusWith
  { device:  iac
  , channel: 5               -- ch5 to avoid bass1..bass4 IAC claims; Live MIDI track set to all-channels or ch5
  , vel:     100
  , durMs:   50              -- short like Phase 3's pitch "c2"
  , stepsPerCycle: 16
  , notes:   phase4Notes
  , skip:    replicate16 false
  , gate:    replicate16 true
  , glide:   replicate16 false
  , navMode: NavForward
  , config:
      { stepYNow: pure false
      , notes:    map pure phase4Notes
      , skip:     map pure (replicate16 false)
      , advance:  pure true  -- step every tick, no euclidean gating
      }
  }
  where
    -- All 16 steps = MIDI 36 (c2).  Matches the sample-trigger note
    -- used in Phases 1/3 so the recording fires the same Live
    -- instrument with the same transient profile.
    phase4Notes =
      [ 36, 36, 36, 36
      , 36, 36, 36, 36
      , 36, 36, 36, 36
      , 36, 36, 36, 36
      ]

session :: Session
session = Session
  { devices:     [iac]
  , instruments: []
  , drumKits:    []
  , parts:       []
  }
