-- | Calypso.Prelude — the DSL surface for Calypso session source files.
-- |
-- | A Calypso session is a PureScript module that imports this prelude.
-- | The user authors devices, instruments, parts, sections, etc. as
-- | ordinary PureScript declarations; the runtime walks the resulting
-- | `Session` value at baseline-load time to register them.
-- |
-- | History note (PR 1, 2026-05-17): the original surface used `Cue`
-- | (with a phantom `mvoice :: Symbol`) and `Channel` (with a 5-field
-- | tuple `device-ch-note-vel-dur`).  The rename to `PitchedPart` /
-- | `Instrument`, plus dropping the phantom in favour of a runtime
-- | String mvoice, is PR 1 of the DSL naming refactor.  The full slab
-- | plan including PR 1.5 (walker hoist into PureScript) and PR 2
-- | (destination split + dispatcher protocol) lives at
-- | `docs/dsl-naming-refactor-plan.md`.
module Calypso.Prelude
  ( module Tidal.Cell.Prelude
  -- Numeric negation — required so `transpose = -5` (and any other
  -- unary-minus literal) desugars to a real `negate` call rather
  -- than failing with an Unknown-value error.  Cells get this via
  -- their own Prelude; sessions import from us directly.
  , negate
  -- Application
  , applyFn, ($)
  -- Bulk-erase a typed Part array into AnyParts for the Session bag.
  , eraseAll
  -- Devices
  , MidiDevice(..)
  -- Instruments — pitched-routing destinations (was `Channel`)
  , Instrument(..)
  -- Parts — Pattern-bound-to-Instrument (was `Cue`)
  , PitchedPart(..)
  , on
  , partOf
  -- Session bag
  , Session(..)
  , AnyPart(..)
  , class Erase
  , erase
  , emptySession
  , addDevice
  , addInstrument
  , addPart
  -- Sections (Pattern of parts, fired by the conductor)
  , Section
  , armPart
  ) where

import Control.Applicative (pure)
import Data.Functor (map)
import Data.Semigroup ((<>))
import Data.Semiring (zero) as PSemiring
import Data.Ring (class Ring, sub) as PRing
import Tidal.Cell.Prelude
import Tidal.Pitch (Pitch)

-- | Right-associative function application — Haskell/Tidal idiom for
-- | avoiding nested parens: `f $ g $ x` reads as `f (g x)`.  Defined
-- | locally because re-exporting the prelude's `($)` collides with
-- | `class Apply`'s `apply` method that comes in via Tidal.Pattern.
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

-- | A pitched-routing destination.  Today (PR 1) `Instrument` is a
-- | single MIDI variant; PR 2 splits it into a sum
-- | (`MidiInstrument` + `VPerOctInstrument`) and drops the trailing
-- | note/vel/dur defaults in favour of per-event articulation.
-- |
-- | The 5-tuple is preserved as-is for PR 1 to keep the dispatcher
-- | spec parser (`midi-note <alias> <ch> <note> <vel> <dur>`)
-- | working without protocol changes.
-- |
-- | ```
-- | qd1   = Instrument fh2qd 14 60 100 50
-- | bass1 = Instrument iac    1 36 100 50
-- | ```
data Instrument
  = Instrument MidiDevice Int Int Int Int

-- ---------------------------------------------------------------------------
-- Parts
-- ---------------------------------------------------------------------------

-- | A `PitchedPart` is a `Pattern Pitch` bound to an `Instrument`,
-- | tagged with a runtime mvoice name (`"bass"`, `"fugue"`, …) that
-- | the conductor uses to dispatch to the right voice supervisor.
-- |
-- | The mvoice is a String (not a phantom Symbol) so that arrays of
-- | parts targeting different voices are homogeneous and can be
-- | uniformly erased into the Session's `parts` bag via
-- | `erase <$> [...]`.
-- |
-- | PR 2 will introduce `DrumPart` as a sibling kind; the `Erase`
-- | class produces the same `AnyPart` regardless of source kind.
newtype PitchedPart = PitchedPart
  { mvoice      :: String
  , destination :: Instrument
  , body        :: Pattern Pitch
  }

-- | The standard part constructor.  Reads as "play this on bass1 in
-- | the bass voice":
-- |
-- |     bass1A :: PitchedPart
-- |     bass1A = on "bass" bass1 (mini "c2 e2 g2 ~")
-- |
-- | The mvoice string ("bass" here) is the runtime label the voice
-- | supervisor matches against.
on :: String -> Instrument -> Pattern Pitch -> PitchedPart
on mv i body = PitchedPart { mvoice: mv, destination: i, body }

-- | Alternate name when you want the call-site to read declaratively:
-- |     melodyT = partOf "bass" bass2 (tintinnabuli aMinT above1 mPart)
partOf :: String -> Instrument -> Pattern Pitch -> PitchedPart
partOf = on

-- ---------------------------------------------------------------------------
-- Session bag — erased Parts the runtime walks at baseline load
-- ---------------------------------------------------------------------------

-- | An `AnyPart` is a Part with its specific kind erased.  PR 1 has
-- | only one Part kind (PitchedPart), so the erasure is structurally
-- | trivial; PR 2 makes `AnyPart` a sum (`AnyPitchedPart` |
-- | `AnyDrumPart`) and the conductor pattern-matches on the variant
-- | at arm time.
-- |
-- | Why a `data` type with a named constructor rather than a
-- | newtype: PR 2's transition is then a single-line constructor
-- | addition, and the Erlang walker (until PR 1.5 hoists it) gets a
-- | stable `anyPart` tuple-tag to match on.
data AnyPart = AnyPart
  { mvoice      :: String
  , destination :: Instrument
  , body        :: Pattern Pitch
  }

-- | Erase a typed Part into an `AnyPart`.  Typeclass-resolved so PR 2
-- | can add a `DrumPart` instance without touching call sites
-- | (`erase <$> [bass1A, fugue1, qd1A]` will keep working as the
-- | typeclass dispatches per element).
class Erase a where
  erase :: a -> AnyPart

instance erasePitched :: Erase PitchedPart where
  erase (PitchedPart r) = AnyPart r

-- | Bulk-erase a homogeneous Array of typed Parts to the Session's
-- | `parts` bag.  PR 1 has only PitchedPart, so the call site reads
-- |
-- |     parts: eraseAll [bass1A, melodyM, fugue1, fugue2]
-- |
-- | When PR 2 adds DrumPart, each Part-kind gets its own `eraseAll
-- | […]` group, joined with `<>`:
-- |
-- |     parts: eraseAll [bass1A, fugue1, fugue2] <> eraseAll [qd1A, qd2A]
eraseAll :: forall a. Erase a => Array a -> Array AnyPart
eraseAll = map erase

-- | The Session value: the bag of declarations that the runtime
-- | walks at baseline load to register devices, register
-- | instruments, and seed parts.
-- |
-- | PR 1 keeps the three-field shape that the Erlang walker expects;
-- | PR 1.5 will replace the walker's ad-hoc field-keys classification
-- | with a flat `RegistrationEvent` boundary, after which Session
-- | can grow more fields (drumKits, cvRouters, polysignals) without
-- | touching Erlang.
newtype Session = Session
  { devices     :: Array MidiDevice
  , instruments :: Array Instrument
  , parts       :: Array AnyPart
  }

-- ---------------------------------------------------------------------------
-- Sections — patterns whose events arm parts
-- ---------------------------------------------------------------------------

-- | A `Section` is `Pattern AnyPart` — a pattern whose events carry
-- | erased parts that the BEAM-side conductor arms on their target
-- | mvoice when each event's cycle arrives.  Composable with every
-- | Pattern combinator (`cat`, `stack`, `every`, `rev`, `fast`,
-- | `slow`, …).
type Section = Pattern AnyPart

-- | Lift a typed Part into a one-event-per-cycle `Section`:
-- |
-- |     intro :: Section
-- |     intro = cat [armPart bass1A, armPart bass1B]
-- |
-- | The Erase constraint lets this accept any Part-kind that PR 2
-- | adds.
armPart :: forall a. Erase a => a -> Section
armPart x = pure (erase x)

emptySession :: Session
emptySession = Session { devices: [], instruments: [], parts: [] }

addDevice :: MidiDevice -> Session -> Session
addDevice d (Session s) = Session s { devices = s.devices <> [d] }

addInstrument :: Instrument -> Session -> Session
addInstrument i (Session s) = Session s { instruments = s.instruments <> [i] }

addPart :: AnyPart -> Session -> Session
addPart p (Session s) = Session s { parts = s.parts <> [p] }
