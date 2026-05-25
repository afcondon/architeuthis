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
  ( class LiveReadable
  , live
  , liveOr
  , liveInt
  , liveIntOr
  , liveBool
  , liveBoolOr
  , liveIntArrayOr
  , liveBoolArrayOr
  , liveNumberArrayOr
  , gateFromBus
  ) where

import Prelude
import Data.Array as Array
import Data.Int as Int
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Tidal.Pattern.Types
  (Pattern, pattern, State(..), Event(..), Value(..), emptyContext)

-- | Typeclass for typed reads off the live-control bus.  Replaces the
-- | pre-existing monomorphic `live :: String -> Pattern Number` with
-- | a polymorphic surface — `live "knob"` resolves to whichever
-- | `Pattern a` the use-site context demands.
-- |
-- | The bus today carries Number, Int, and Boolean values (via the
-- | `Value` ADT in `Tidal.Pattern.Types`); instances below cover all
-- | three.  Richer types (e.g. `Voicing` for Vetula's
-- | `chord1.currentVoicing` reads) need an extension of the `Value`
-- | ADT plus matching Erlang-side serialisation — design pending,
-- | tracked under task #150 step 4.
-- |
-- | Each instance's default behaviour when the named slot is absent
-- | or holds a wrong-type value: the type's "zero" (`0.0` for Number,
-- | `0` for Int, `false` for Boolean).  Callers who want a different
-- | fallback reach for `liveOr` / `liveIntOr` / `liveBoolOr`.
class LiveReadable a where
  live :: String -> Pattern a

-- | Read a numeric control by name; default 0.0 when missing.
-- |
-- | Returns a single Analog event spanning the query arc whose
-- | value is the current control reading.  Analog (not Digital)
-- | because the value is a continuous parameter, not a discrete
-- | musical event — this matters for how it combines with
-- | downstream pattern queries via `applyPatternBoth`.
instance liveReadableNumber :: LiveReadable Number where
  live = liveOr 0.0

instance liveReadableInt :: LiveReadable Int where
  live = liveIntOr 0

instance liveReadableBoolean :: LiveReadable Boolean where
  live = liveBoolOr false

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

-- | Read an integer control by name; default 0 when missing.
-- | Companion to `live` for slots that want a Pattern Int — Balistes and
-- | other vmod parameter slots, midi note numbers, etc.  Truncates
-- | Numbers to Int via floor (the same rule the wire path uses).
liveInt :: String -> Pattern Int
liveInt = liveIntOr 0

-- | Like `liveInt` but with a caller-supplied default.
liveIntOr :: Int -> String -> Pattern Int
liveIntOr def name = pattern \(State st) ->
  let
    value = case Map.lookup name st.controls of
      Just (VInt i)    -> i
      Just (VNumber n) -> Int.floor n
      _                -> def
  in
    [ Analog { context: emptyContext, part: st.arc, value } ]

-- | Read a Boolean control by name; default `false` when missing.
-- | Used by René's stepYNow slot and any future on/off live knob.
-- | Accepts either VBool, or numeric (non-zero → true).
liveBool :: String -> Pattern Boolean
liveBool = liveBoolOr false

liveBoolOr :: Boolean -> String -> Pattern Boolean
liveBoolOr def name = pattern \(State st) ->
  let
    value = case Map.lookup name st.controls of
      Just (VInt 0)    -> false
      Just (VInt _)    -> true
      Just (VNumber n) -> n /= 0.0
      _                -> def
  in
    [ Analog { context: emptyContext, part: st.arc, value } ]

-- | Read a bus-emitted gate signal as a `Pattern Boolean`.  Intended
-- | use: an autonomous emitter (virtual polysignal, future vmod
-- | output, MIDI-controller pad, …) writes 0 / non-zero values to
-- | a bus key, and a downstream consumer reads those as gate-shaped
-- | triggers — `advance = gateFromBus "octoEuclid.0"` makes a
-- | virtual octoEuclid bank clock a René voice.
-- |
-- | Semantically equivalent to `liveBool` (any non-zero value reads
-- | true; absent / zero reads false).  The distinct name marks
-- | the intent at the surface — this is the signal-from-another-
-- | machine path, not the live-knob path.
gateFromBus :: String -> Pattern Boolean
gateFromBus = liveBool

-- | Read N Pattern Ints from the bus, named `<prefix>0`..`<prefix>{N-1}`.
-- | Returns one Pattern per default value, in the same order — the
-- | array length is the caller's array length.
-- |
-- | Used by machines whose internal state is an indexed array of cells
-- | (René's 16 notes, future Marbles/Tides ports), where each cell is
-- | one named scalar on the control bus.  A controller pump writes
-- | `<prefix>5 = 67`, the engine samples `liveIntArrayOr defaults
-- | "<prefix>"` at index 5 per step and picks up the new value.
liveIntArrayOr :: Array Int -> String -> Array (Pattern Int)
liveIntArrayOr defaults prefix =
  Array.mapWithIndex (\i d -> liveIntOr d (prefix <> show i)) defaults

-- | Boolean-array companion to `liveIntArrayOr`.  Used for René's
-- | skip/gate/glide modal arrays where each cell is one named boolean.
liveBoolArrayOr :: Array Boolean -> String -> Array (Pattern Boolean)
liveBoolArrayOr defaults prefix =
  Array.mapWithIndex (\i d -> liveBoolOr d (prefix <> show i)) defaults

-- | Number-array companion to `liveIntArrayOr`.  Used for per-cell
-- | continuous values that aren't naturally integer — Odonus's
-- | probability array (`0.0..1.0`), future per-cell pan / gain / etc.
liveNumberArrayOr :: Array Number -> String -> Array (Pattern Number)
liveNumberArrayOr defaults prefix =
  Array.mapWithIndex (\i d -> liveOr d (prefix <> show i)) defaults
