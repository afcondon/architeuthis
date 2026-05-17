-- | Calypso.Prelude — the DSL surface for Calypso session source files.
-- |
-- | A Calypso session is a PureScript module that imports this prelude.
-- | The user authors devices, instruments, drum kits, parts, sections,
-- | etc. as ordinary PureScript declarations; the runtime walks the
-- | resulting `Session` value at baseline-load time to register them.
-- |
-- | History notes:
-- | - PR 1 (2026-05-17): `Cue` → `PitchedPart`, `Channel` → `Instrument`,
-- |   dropped the phantom Symbol-typed mvoice.
-- | - PR 2a (2026-05-17): Added `DrumKit` + `DrumPart` as the
-- |   destination/part for sample-keyed drum sequences.  Smart
-- |   constructor `midi` hides the per-binding note/vel/dur defaults
-- |   behind system constants — Studio reads `midi iac 1` rather than
-- |   the inscrutable old `Channel iac 1 36 100 50`.  Runtime hot
-- |   path unchanged: drum events flow through the existing
-- |   Pattern Pitch dispatcher via Sample-coerce at the conductor
-- |   boundary.  Per-hit MIDI bindings + per-event vel/dur are PR 2b.
-- |
-- | Plan: docs/dsl-naming-refactor-plan.md.
module Calypso.Prelude
  ( module Tidal.Cell.Prelude
  -- Numeric negation — required so `transpose = -5` (and any other
  -- unary-minus literal) desugars to a real `negate` call rather
  -- than failing with an Unknown-value error.
  , negate
  -- Application
  , applyFn, ($)
  -- Array concat for joining `eraseAll […]` arrays across part-kinds
  -- in the Session bag.  Re-exported because Cell.Prelude
  -- deliberately skips `import Prelude` (`append` collision).
  , appendParts, (<+>)
  -- Devices
  , MidiDevice(..)
  -- Instruments — pitched routing destinations
  , Instrument(..)
  , midi
  , midiWith
  -- Drum kits — sample-keyed destinations with per-hit defaults
  , DrumKit(..)
  , DrumHit
  , DrumHitRef
  , midiDrumKit
  , hit
  -- Parts
  , PitchedPart(..)
  , DrumPart(..)
  , class On
  , on
  -- Session bag
  , Session(..)
  , AnyPart(..)
  , class Erase
  , erase
  , eraseAll
  , emptySession
  , addDevice
  , addInstrument
  , addDrumKit
  , addPart
  -- Sections (Pattern of parts, fired by the conductor)
  , Section
  , armPart
  ) where

import Control.Applicative (pure)
import Data.Functor (map)
import Data.Semigroup (append, (<>)) as DataSemigroup
import Data.Semiring (zero) as PSemiring
import Data.Ring (class Ring, sub) as PRing
import Tidal.Cell.Prelude
import Tidal.Pitch (Pitch)

-- | Right-associative function application — Haskell/Tidal idiom for
-- | avoiding nested parens: `f $ g $ x` reads as `f (g x)`.
infixr 0 applyFn as $

applyFn :: forall a b. (a -> b) -> a -> b
applyFn f x = f x

-- | Numeric negation — required so a literal `-5` desugars to a real
-- | `negate` call.  Reimplemented locally rather than re-exporting
-- | `Data.Ring.negate` because we don't `import Prelude` at this
-- | module (collision with `append` in `Tidal.Pattern.Core`).
negate :: forall a. PRing.Ring a => a -> a
negate x = PRing.sub PSemiring.zero x

-- ---------------------------------------------------------------------------
-- Devices
-- ---------------------------------------------------------------------------

-- | A physical MIDI destination — a CoreMIDI port name and a latency
-- | compensation in milliseconds.
-- |
-- | ```
-- | fh2  = MidiDevice "FH-2" 0
-- | iac  = MidiDevice "IAC Driver Tidal" 30
-- | ```
data MidiDevice = MidiDevice String Int

-- ---------------------------------------------------------------------------
-- Instruments
-- ---------------------------------------------------------------------------

-- | A pitched-routing destination.  The internal 5-tuple shape is
-- | preserved from PR 1 so the BEAM dispatcher's spec parser keeps
-- | working without protocol changes; the user-facing surface hides
-- | the trailing note/vel/dur via the `midi` smart constructor.
-- |
-- | PR 2c will split this into a sum (`MidiInstrument` +
-- | `VPerOctInstrument`); PR 2b will drop the trailing defaults
-- | entirely once the pattern emit path carries vel/dur per event.
data Instrument
  = Instrument MidiDevice Int Int Int Int

-- | The plain-MIDI instrument smart constructor.  Fills in system
-- | defaults (note 60, vel 100, dur 50ms) so the user-facing
-- | declaration reads as pure routing:
-- |
-- | ```
-- | bass1 = midi iac 1
-- | ```
-- |
-- | Use `midiWith` when you need a specific default note (e.g. a
-- | mono synth that wants a particular triggered pitch when the
-- | pattern doesn't override).
midi :: MidiDevice -> Int -> Instrument
midi device channel = Instrument device channel 60 100 50

-- | The full-control MIDI instrument constructor for cases where
-- | the system defaults aren't right.  Per-event vel/dur arrives in
-- | PR 2b — at that point the `defNote`/`defVel`/`defDurMs` fields
-- | will be retired.
-- |
-- | ```
-- | sub1 = midiWith iac 5 { defNote: 24, defVel: 110, defDurMs: 200 }
-- | ```
midiWith
  :: MidiDevice
  -> Int
  -> { defNote :: Int, defVel :: Int, defDurMs :: Int }
  -> Instrument
midiWith device channel { defNote, defVel, defDurMs } =
  Instrument device channel defNote defVel defDurMs

-- ---------------------------------------------------------------------------
-- Drum kits
-- ---------------------------------------------------------------------------

-- | A single drum-hit declaration: a named token bound to its MIDI
-- | note / velocity / duration.  Lives in the kit's hit table; at
-- | runtime (PR 2b) each hit will register as its own MIDI binding
-- | under `<kitAlias>.<hitName>`.  For PR 2a the kit registers as
-- | one binding (using the first hit's defaults) and per-hit
-- | dispatch is deferred.
type DrumHit =
  { name :: String
  , note :: Int
  , vel :: Int
  , durMs :: Int
  }

-- | Construct a drum hit.  Reads as:
-- |
-- | ```
-- | hit "bd" 36 100 50   -- "bd" → MIDI note 36, vel 100, 50ms
-- | ```
hit :: String -> Int -> Int -> Int -> DrumHit
hit name note vel durMs = { name, note, vel, durMs }

-- | A reference to a drum hit by name; the body type of `DrumPart`.
type DrumHitRef = String

-- | A drum / sample destination, distinct from `Instrument` because
-- | (a) it carries a per-hit table where pitched instruments have
-- | only routing, and (b) PR 2b will dispatch each hit through its
-- | own MIDI binding.  PR 2c will add `GateDrumKit` for CV/Gate
-- | output through cv-router.
-- |
-- | ```
-- | qd1 = midiDrumKit fh2qd 14
-- |   [ hit "bd" 36 100 50
-- |   , hit "sn" 38 100 50
-- |   , hit "hh" 42  80 30
-- |   ]
-- | ```
data DrumKit
  = MidiDrumKit MidiDevice Int (Array DrumHit)

-- | Smart constructor — direct mirror of `MidiDrumKit` for symmetry
-- | with the `midi` / `midiWith` instrument constructors.
midiDrumKit :: MidiDevice -> Int -> Array DrumHit -> DrumKit
midiDrumKit = MidiDrumKit

-- ---------------------------------------------------------------------------
-- Parts
-- ---------------------------------------------------------------------------

-- | A `PitchedPart` is a `Pattern Pitch` bound to an `Instrument`,
-- | tagged with a runtime mvoice name (`"bass"`, `"fugue"`, …) that
-- | the conductor uses to dispatch to the right voice supervisor.
newtype PitchedPart = PitchedPart
  { mvoice      :: String
  , destination :: Instrument
  , body        :: Pattern Pitch
  }

-- | A `DrumPart` is a `Pattern DrumHitRef` (sequence of named drum
-- | hits — `"bd"`, `"sn"`, `"~"` for rest) bound to a `DrumKit`.
-- | Authored as:
-- |
-- | ```
-- | qd1A :: DrumPart
-- | qd1A = on "drums" qd1 (drum "bd bd ~ ~ bd ~ sn ~")
-- | ```
newtype DrumPart = DrumPart
  { mvoice      :: String
  , destination :: DrumKit
  , body        :: Pattern DrumHitRef
  }

-- | The polymorphic `on` constructor — typeclass-dispatched on the
-- | destination type so `on "bass" bass1 (mini "...")` builds a
-- | `PitchedPart` and `on "drums" qd1 (drum "...")` builds a
-- | `DrumPart`.  Functional dependency on dest → body, part keeps
-- | inference clean.
class On dest body part | dest -> body part where
  on :: String -> dest -> Pattern body -> part

instance onInstrument :: On Instrument Pitch PitchedPart where
  on mvoice destination body =
    PitchedPart { mvoice, destination, body }

instance onDrumKit :: On DrumKit DrumHitRef DrumPart where
  on mvoice destination body =
    DrumPart { mvoice, destination, body }

-- ---------------------------------------------------------------------------
-- Session bag — erased Parts the runtime walks at baseline load
-- ---------------------------------------------------------------------------

-- | A part with its specific kind erased.  PR 2a makes this a sum
-- | (PitchedPart's record + DrumPart's record); the conductor
-- | dispatches on the variant at arm time.
data AnyPart
  = AnyPitchedPart
      { mvoice      :: String
      , destination :: Instrument
      , body        :: Pattern Pitch
      }
  | AnyDrumPart
      { mvoice      :: String
      , destination :: DrumKit
      , body        :: Pattern DrumHitRef
      }

-- | Erase a typed Part into an `AnyPart`.  Typeclass-resolved so a
-- | uniform `erase <$> [parts]` works across mixed kinds.
class Erase a where
  erase :: a -> AnyPart

instance erasePitched :: Erase PitchedPart where
  erase (PitchedPart r) = AnyPitchedPart r

instance eraseDrum :: Erase DrumPart where
  erase (DrumPart r) = AnyDrumPart r

-- | Bulk-erase a homogeneous Array of typed Parts to the Session's
-- | `parts` bag.  Use one `eraseAll [...]` per Part-kind, joined
-- | with `<>`:
-- |
-- |     parts: eraseAll [fugue1, melodyM] <> eraseAll [qd1A, qd2A]
eraseAll :: forall a. Erase a => Array a -> Array AnyPart
eraseAll = map erase

-- | Join two `Array AnyPart` groups (typically one per Part-kind).
-- |
-- |     parts: eraseAll [pitchedParts ...] `appendParts` eraseAll [drumParts ...]
appendParts :: Array AnyPart -> Array AnyPart -> Array AnyPart
appendParts = DataSemigroup.append

infixr 5 appendParts as <+>

-- | The Session value: devices, instruments, drum kits, and the bag
-- | of erased parts.  Walked at baseline load.
newtype Session = Session
  { devices     :: Array MidiDevice
  , instruments :: Array Instrument
  , drumKits    :: Array DrumKit
  , parts       :: Array AnyPart
  }

-- ---------------------------------------------------------------------------
-- Sections — patterns whose events arm parts
-- ---------------------------------------------------------------------------

type Section = Pattern AnyPart

armPart :: forall a. Erase a => a -> Section
armPart x = pure (erase x)

emptySession :: Session
emptySession = Session
  { devices: []
  , instruments: []
  , drumKits: []
  , parts: []
  }

addDevice :: MidiDevice -> Session -> Session
addDevice d (Session s) = Session s { devices = s.devices `DataSemigroup.append` [d] }

addInstrument :: Instrument -> Session -> Session
addInstrument i (Session s) = Session s { instruments = s.instruments `DataSemigroup.append` [i] }

addDrumKit :: DrumKit -> Session -> Session
addDrumKit k (Session s) = Session s { drumKits = s.drumKits `DataSemigroup.append` [k] }

addPart :: AnyPart -> Session -> Session
addPart p (Session s) = Session s { parts = s.parts `DataSemigroup.append` [p] }
