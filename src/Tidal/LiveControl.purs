-- | Live-control primitive: read a Number from `State.controls`.
-- |
-- | The `State` type already carries a `ControlMap` field; the
-- | scheduler can populate it from a runtime ETS-backed bus, and a
-- | cell that wants a live-tweakable parameter just calls `live`
-- | with a name.
-- |
-- | Naming: distinct from `Tidal.Controls` (which is the synth-
-- | parameter merging machinery — `gain`, `pan`, `note`, etc.).
-- | These are *runtime-mutable named scalars* — the same shape as
-- | a single Midifighter Twister knob, a Calypso UI slider, or any
-- | other "knob driving a parameter" surface.
-- |
-- | A cell uses this like:
-- |
-- | ```purescript
-- | melody = pickFromPool [c4, e4, g4, a4]
-- |        $ dejaVu { lockProb: live "dejavu.lock", … } (irand 100)
-- | ```
-- |
-- | Default behaviour when the named control is absent or non-numeric:
-- | `live` returns 0.0; `liveOr d` returns the supplied default `d`.
-- | This lets cells be well-behaved before any external surface has
-- | written a value.
module Tidal.LiveControl
  ( live
  , liveOr
  ) where

import Data.Int as Int
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Tidal.Pattern.Types
  (Pattern, pattern, State(..), Event(..), Value(..), emptyContext)

-- | Read a numeric control by name; default 0.0 when missing.
-- |
-- | Returns a single Analog event spanning the query arc whose
-- | value is the current control reading.  Analog (not Digital)
-- | because the value is a continuous parameter, not a discrete
-- | musical event — this matters for how it combines with
-- | downstream pattern queries via `applyPatternBoth`.
live :: String -> Pattern Number
live = liveOr 0.0

-- | Like `live` but with a caller-supplied default when the named
-- | control isn't set or holds a non-Number value.
liveOr :: Number -> String -> Pattern Number
liveOr def name = pattern \(State st) ->
  let
    value = case Map.lookup name st.controls of
      Just (VNumber n) -> n
      Just (VInt i)    -> Int.toNumber i  -- accept ints transparently
      _                -> def
  in
    [ Analog { context: emptyContext, part: st.arc, value } ]
