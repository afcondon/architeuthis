-- | `Tidal.Vetula.Pattern` — V-D slab.
-- |
-- | Makes Vetula a first-class `Notation` in the substrate.  A
-- | `VetulaPart` carries a Key + Progression + VoicingStrategy +
-- | centre octave; the `Notation` instance produces a
-- | `Pattern PitchedNote12` whose each chord is a `stack` of N
-- | parallel `Chromatic` events, sequenced via `cat` across the
-- | progression.
-- |
-- | Vetula sidesteps the per-vmod Erlang gen_server path used by
-- | Balistes / Odonus / Selene.  Those vocabularies are algorithmic
-- | (Markov, Cartesian-walk, config snapshots) and need their own
-- | tick logic.  Vetula is **fully determined at registration**:
-- | given Key + Progression + Strategy, every voicing is fixed.
-- | So it slots into the existing Pattern substrate directly and
-- | gets the MIDI scheduler / SuperDirt emit / timing stack for free.
-- |
-- | `vetula key progression voicing >> piano1` produces a
-- | `String -> PitchedPart PitchedNote12` (via the
-- | `routedInstrument` instance from `Calypso.Prelude`) — drop the
-- | resulting PitchedPart into a `Session`'s `parts` field and the
-- | substrate plays it.
-- |
-- | See `atlantis-site-planning/vetula-design.md` §"Integration
-- | shapes" for the routing patterns this enables.
module Tidal.Vetula.Pattern
  ( VetulaPart(..)
  , vetula
  , vetulaWith
  , vetulaPattern
  , voicingAsStack
  ) where

import Prelude

import Data.Array (cons)
import Data.Array as Array
import Data.Maybe (Maybe(..))

import Tidal.Notation (class Notation)
import Tidal.Pattern.Core (cat, silence, stack)
import Tidal.Pattern.Types (Pattern)
import Tidal.Pitch (PitchedNote12(..))
import Tidal.Vetula (Key, realize)
import Tidal.Vetula.Voicing
  ( Progression
  , Voicing(..)
  , VoicingStrategy
  , closeVoicing
  , voiceLead
  )

-- ---------------------------------------------------------------------------
-- VetulaPart — the user-facing declaration
-- ---------------------------------------------------------------------------

-- | A Vetula declaration.  Holds the key, the progression (an array
-- | of chord recipes), the voicing strategy applied to the first
-- | chord, and the centre octave for the initial close-position
-- | voicing.  Subsequent voicings drift via voice-leading from the
-- | previous one.
-- |
-- | The design doc's `in:` field is rendered as `key:` here — `in`
-- | is a PureScript keyword and not safe as a record field name.
newtype VetulaPart = VetulaPart
  { key         :: Key
  , progression :: Progression
  , voicing     :: VoicingStrategy
  , octave      :: Int
  }

-- ---------------------------------------------------------------------------
-- Smart constructors
-- ---------------------------------------------------------------------------

-- | Positional constructor with octave defaulted to 4 (the middle-C
-- | octave).  Best for inline cell-text use.
vetula :: Key -> Progression -> VoicingStrategy -> VetulaPart
vetula k prog strat = VetulaPart
  { key:         k
  , progression: prog
  , voicing:     strat
  , octave:      4
  }

-- | Record-literal constructor — full control of all fields.  Match
-- | the design doc's "canonical record-literal form" shape:
-- | `vetulaWith { key, progression, voicing, octave }`.
vetulaWith
  :: { key :: Key
     , progression :: Progression
     , voicing :: VoicingStrategy
     , octave :: Int
     }
  -> VetulaPart
vetulaWith = VetulaPart

-- ---------------------------------------------------------------------------
-- Pattern realisation
-- ---------------------------------------------------------------------------

-- | The headline derivation.  Builds the chord sequence with
-- | voice-leading from a centred initial voicing, then turns each
-- | voicing into a parallel stack of `Chromatic` events.  Empty
-- | progression yields silence.
-- |
-- | **One chord per cycle** — uses `Tidal.Pattern.Core.cat` which is
-- | slow-cat: a 4-chord progression plays over 4 cycles (= 4 bars
-- | at the default cps).  Wrap with `fast` at the call site to
-- | compress (`fast 4 (vetulaPattern v)` plays the whole progression
-- | per cycle).
vetulaPattern :: VetulaPart -> Pattern PitchedNote12
vetulaPattern (VetulaPart r) =
  case Array.uncons r.progression of
    Nothing -> silence
    Just { head: firstDc, tail: rest } ->
      let
        firstV = r.voicing (closeVoicing { centre: r.octave } (realize r.key firstDc))
        voicings = cons firstV
          (Array.scanl (\prev dc -> voiceLead prev (realize r.key dc))
                       firstV rest)
      in
        cat (map voicingAsStack voicings)

-- | One voicing → a Pattern that emits all its notes simultaneously.
-- | The chord's N MIDI numbers become N parallel `pure (Chromatic n)`
-- | sub-patterns, stacked.
voicingAsStack :: Voicing -> Pattern PitchedNote12
voicingAsStack (Voicing midis) = case midis of
  [] -> silence
  _  -> stack (map (pure <<< Chromatic) midis)

-- ---------------------------------------------------------------------------
-- Notation instance — the substrate hook
-- ---------------------------------------------------------------------------

-- | Vetula is a `Notation` over `PitchedNote12`.  This is the
-- | substrate handshake — anywhere the system accepts a Notation
-- | (cell text, `>>` routing, Pattern combinators), Vetula slots in.
-- |
-- | Combined with `routedInstrument` from `Calypso.Prelude`:
-- |
-- |   vetula key prog strat >> piano1
-- |     :: String -> PitchedPart PitchedNote12
instance notationVetulaPart :: Notation VetulaPart PitchedNote12 where
  toPattern = vetulaPattern
