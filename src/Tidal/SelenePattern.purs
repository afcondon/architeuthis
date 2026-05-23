-- | Tidal.SelenePattern — `Pattern (Selene s)` lifted into a Session
-- | binding that the walker can discover and the rig can rotate
-- | through on cycle boundaries.  Slab C step 2 (2026-05-23).
-- |
-- | A `SelenePattern` is a Tidal pattern whose events are full
-- | Selene values — a snapshot of a bank per cycle position.  The
-- | walker installs the snapshot at each cycle boundary; if the
-- | new value's JSON envelope differs from the previous cycle's,
-- | a fresh `apply-polysignal` lands on the daemon and the FH-2
-- | reconfigures the bank for the new cycle.
-- |
-- | The musical idiom is the "Oscilab stack-of-LFOs" payoff
-- | (memory: `project_polyfacetic_repl_vision`): a *changing* set of
-- | bank snapshots stepping forward on the beat, with each snapshot
-- | being a full multi-shape spec on every output of the bank.
-- |
-- | Example — Andrew's four-cycle "one LFO at a time" walk:
-- |
-- |     studioRotation :: SelenePattern "rotation"
-- |     studioRotation = selenePattern $ cat
-- |       [ octoLfo fh2Main [ sinLFO 0.5, fixed 0.4, silent, silent ] (Just Bipolar5V)
-- |       , octoLfo fh2Main [ silent,     sinLFO 1.0, silent, silent ] (Just Bipolar5V)
-- |       , octoLfo fh2Main [ silent,     silent,    triLFO 2.0, silent ] (Just Bipolar5V)
-- |       , octoLfo fh2Main [ silent,     fixed 0.2, silent, sinLFO 4.0 ] (Just Bipolar5V)
-- |       ]
-- |
-- | `cat` divides one Tidal cycle into N equal slices; the
-- | `selene_pattern_voice` gen_server installs the active slice's
-- | snapshot once per cycle (at the cycle boundary) and avoids re-
-- | sending unchanged envelopes (~10ms each via the fh2-daemon
-- | socket, so dedup matters when the pattern stays put).
-- |
-- | Open design points (deferred to scope-verification):
-- |
-- |   * **Cycle vs bar.**  Default is Tidal cycles, not musical
-- |     bars.  Users dial the rotation speed via `slow N` on the
-- |     pattern.  Bar-alignment is emergent from cps + slow choice.
-- |
-- |   * **First-event-of-cycle.**  For sub-cycle patterns
-- |     (e.g. `fastCat [bank1, bank2]` which fires both within one
-- |     cycle), the voice currently takes whatever Selene event is
-- |     active at the cycle boundary and installs that.  Sub-cycle
-- |     installs would require either ~10ms-cost mid-cycle SysEx
-- |     writes (audibly glitchy) or a queued-install path; not v1.
-- |
-- |   * **Phase reset on install.**  The FH-2 firmware section on
-- |     LFO reset semantics (Type / Set 1 / Set 2 columns from the
-- |     UI) is still unread; current behaviour is whatever the
-- |     daemon's `apply-polysignal` does (likely no explicit phase
-- |     reset, which means LFOs free-run across snapshot changes).
-- |     Sounds right for continuous modulation; will need
-- |     scope-verifying when used for percussive gates.
module Tidal.SelenePattern
  ( SelenePattern(..)
  , selenePattern
  , patternEnvelopeAt
  ) where

import Prelude

import Data.Array as Array
import Data.Int as Int
import Data.Maybe (Maybe(..))
import Data.Rational (fromInt)
import Foreign (Foreign)
import Unsafe.Coerce (unsafeCoerce)

import Tidal.Pattern.Core (queryArc)
import Tidal.Pattern.Types (Pattern, eventValue)
import Tidal.Selene (Selene, seleneAsJson)

-- | A Pattern of Selene values, wrapped at the Session layer so the
-- | walker can pick it up by constructor tag.  The Symbol parameter
-- | is decorative — the walker derives the alias from the binding
-- | name (the same convention as plain `Selene s`).
newtype SelenePattern (s :: Symbol) = SelenePattern (Pattern (Selene s))

-- | Smart constructor.  Reads cleaner than `SelenePattern (cat …)`
-- | at the binding site.
selenePattern :: forall s. Pattern (Selene s) -> SelenePattern s
selenePattern = SelenePattern

-- | FFI-facing helper called from `selene_pattern_voice`.  Given the
-- | binding alias, the opaque Pattern (Selene s) value, and a cycle
-- | position, query the pattern for the first event whose arc
-- | contains the cycle start, and project it to a JSON envelope.
-- |
-- | Returns `Nothing` if the pattern has no event active at the
-- | integer-floor of `cyclePos` (e.g. silent stretch of a `cat`
-- | with a rest).
-- |
-- | The Foreign coercion at the boundary is the price for an
-- | Erlang-side gen_server holding the opaque Pattern value across
-- | ticks without round-tripping the structural data through the
-- | walker every cycle.  The phantom Symbol `"anon"` is arbitrary —
-- | runtime values don't carry the symbol, so any literal works.
patternEnvelopeAt :: String -> Foreign -> Number -> Maybe String
patternEnvelopeAt alias patternForeign cyclePos =
  let
    p :: Pattern (Selene "anon")
    p = unsafeCoerce patternForeign

    cycleFloor = Int.floor cyclePos
    lo = fromInt cycleFloor
    hi = fromInt (cycleFloor + 1)
    events = queryArc p lo hi
  in
    case Array.head events of
      Nothing -> Nothing
      Just ev -> Just (seleneAsJson alias (eventValue ev))
