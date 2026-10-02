-- | Slab B's class cluster — the per-fabric typeclasses that let
-- | different note types target different Instrument variants.
-- |
-- | The class cluster is split deliberately into one marker class
-- | (`Emitable`) plus several per-fabric capability classes.  Each
-- | Instrument variant pairs with exactly one capability class:
-- |
-- |   * `MidiInstrument`      → `ToMidiNote`
-- |   * `VPerOctInstrument`   → `ToVPerOctVolts`
-- |   * `OscSampleInstrument` → `ToOscSample`   (future)
-- |   * `MpeInstrument`       → `ToMpeNote`     (future, microtonal MIDI)
-- |   * `MtsInstrument`       → `ToMtsNote`     (future, SysEx retune)
-- |
-- | A note type implements only the capability classes appropriate to
-- | its wire shape:
-- |
-- |   * `PitchedNote12` (today) implements `Emitable`, `ToMidiNote`,
-- |     `ToVPerOctVolts`, `ToOscSample`.
-- |   * A future `MaqamNote` would implement `Emitable`, `ToMpeNote`,
-- |     `ToMtsNote`, `ToVPerOctVolts`, `ToOscSample` — but NOT
-- |     `ToMidiNote` (12-TET MIDI can't represent maqam pitches).
-- |
-- | The dispatcher's per-PrimAction emit code consults the relevant
-- | capability class; a `Maybe`-returning `Nothing` means "this note
-- | type can't emit on this fabric" → debug log, no emit.
-- |
-- | ## Current scope (Slab B, 2026-05-18)
-- |
-- | The string-token dispatcher path (Voice renders `note → String`
-- | via `noteName` + scale-aware Degree resolution, dispatcher
-- | interprets via existing `resolveTokenMidi` / `interpretCV
-- | NoteNameVoct`) is sufficient for `PitchedNote12`.  The capability
-- | classes below are **forward-compat** — declared and
-- | instance-implemented for `PitchedNote12`, but not yet wired into
-- | the dispatcher hot path.  When a non-12-TET note type lands, the
-- | dispatcher's PrimAction arms grow class-based extraction in
-- | parallel to the existing string-token path.
-- |
-- | Instances live here (not in `Tidal.Pitch`) to avoid the
-- | non-orphan rule: instances must be in the class's module OR the
-- | type's module.  Putting them in `Tidal.Emit` (the class's module)
-- | needs only one upward import (`Tidal.Pitch`), without forcing
-- | `Tidal.Pitch` to depend on this module — which would create a
-- | cycle through `Tidal.Substrate.Scales`.
-- |
-- | Design memory: `project_emitable_three_axes`.
module Tidal.Emit
  ( class Emitable
  , noteName
  , class ToMidiNote
  , toMidiNote
  , class ToVPerOctVolts
  , toVPerOctVolts
  , class ToOscSample
  , toOscSample
  ) where

import Prelude

import Data.Int (toNumber)
import Data.Maybe (Maybe(..))
import Tidal.Pitch (PitchedNote12(..))

-- ---------------------------------------------------------------------------
-- The marker class — every note that can be emitted somewhere.
-- ---------------------------------------------------------------------------

-- | A note type that has a string-token rendering.
-- |
-- | `noteName` is the unconditional, scale-free rendering used for
-- | logging, debug, and dispatch when no contextual information
-- | (active scale, MPE channel state) is needed.  Note types with
-- | context-dependent rendering (like `PitchedNote12.Degree`) keep
-- | their context-aware logic outside the class — Voice's
-- | `renderToken` consults the active scale separately.
class Emitable note where
  noteName :: note -> String

-- ---------------------------------------------------------------------------
-- Per-fabric capability classes — forward-compat, currently
-- declared but not wired into the dispatcher hot path.
-- ---------------------------------------------------------------------------

-- | A note that can emit on a `MidiInstrument` (plain 12-TET MIDI).
-- | Returns `Nothing` for note types that can't be represented as a
-- | bare MIDI note number + velocity (e.g. microtonal types).
class ToMidiNote note where
  toMidiNote :: note -> Maybe { note :: Int, vel :: Int }

-- | A note that can emit on a `VPerOctInstrument` (1V/oct CV through
-- | es9-daemon).  Returns the digital ±1.0 value (es9-daemon's scale,
-- | which maps to ES-9's ±10V).
class ToVPerOctVolts note where
  toVPerOctVolts :: note -> Maybe Number

-- | A note that can emit on an `OscSampleInstrument` (sample-player
-- | OSC like SuperDirt).  `pitchSemitones` may be fractional for
-- | microtonal rate-stretch — sample players don't care about 12-TET.
-- |
-- | Future: integrate into the dispatcher when `OscSampleInstrument`
-- | lands.  Today this class is declared so the design admits OSC
-- | sample output as a near-term third emission strategy.
class ToOscSample note where
  toOscSample :: note -> Maybe { pitchSemitones :: Number }

-- ---------------------------------------------------------------------------
-- PitchedNote12 instances.  Live here (the class's module) rather
-- than in Tidal.Pitch (the type's module) so they're not orphans
-- while also not pulling Tidal.Pitch into Tidal.Substrate.Scales's dependency
-- cone (which would cycle).
-- ---------------------------------------------------------------------------

-- | Scale-free rendering of `PitchedNote12`.  `Degree` carries no
-- | meaningful pitch without scale context, so its `noteName` is the
-- | placeholder `?N`; the Voice's `renderToken` consults the active
-- | scale to resolve Degree properly (or silence if no scale).
instance emitablePitchedNote12 :: Emitable PitchedNote12 where
  noteName = case _ of
    Chromatic n -> show n
    Sample s    -> s
    Degree d    -> "?" <> show d

-- | `Chromatic n` → bare MIDI note with the system-default velocity.
-- | `Degree` / `Sample` aren't directly MIDI-emittable without
-- | further resolution (Degree needs a scale; Sample names need a
-- | drum-kit mapping) — returns `Nothing` so the dispatcher's
-- | class-aware path (future) silences instead of guessing.
instance toMidiNotePitchedNote12 :: ToMidiNote PitchedNote12 where
  toMidiNote = case _ of
    Chromatic n -> Just { note: n, vel: 100 }
    _           -> Nothing

-- | `Chromatic n` → 1V/oct on es9-daemon's ±10V→±1.0 scale (matching
-- | `Tidal.Dispatch.Helpers.voctValue`).  `Sample` / `Degree` return
-- | `Nothing` — sample names don't have a CV value; degrees need
-- | resolution.
instance toVPerOctVoltsPitchedNote12 :: ToVPerOctVolts PitchedNote12 where
  toVPerOctVolts = case _ of
    Chromatic n -> Just (toNumber n / 120.0)
    _           -> Nothing

-- | `Chromatic n` → fractional pitchSemitones (exact integer for
-- | 12-TET).  Sample players accept fractional semitones via
-- | rate-stretch, so this is naturally microtonal-compatible for
-- | future note types.  `Sample` / `Degree` return `Nothing`.
instance toOscSamplePitchedNote12 :: ToOscSample PitchedNote12 where
  toOscSample = case _ of
    Chromatic n -> Just { pitchSemitones: toNumber n }
    _           -> Nothing
