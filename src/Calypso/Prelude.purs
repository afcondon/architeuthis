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
-- |   Pattern PitchedNote12 dispatcher via Sample-coerce at the conductor
-- |   boundary.  Per-hit MIDI bindings + per-event vel/dur are PR 2b.
-- | - 2026-05-23: Smart constructor `midi` → `midiChannel` (and
-- |   `midiWith` → `midiChannelWith`) so `bass1 = midiChannel iac 1`
-- |   reads as "a MIDI channel on this device", and the name `midi`
-- |   is freed for potential future use.
-- |
-- | Plan: docs/dsl-naming-refactor-plan.md.
module Calypso.Prelude
  ( module Tidal.Cell.Prelude
  -- Numeric negation — required so `transpose = -5` (and any other
  -- unary-minus literal) desugars to a real `negate` call rather
  -- than failing with an Unknown-value error.
  , negate
  -- Applicative `pure` — for `pure 128 :: Pattern Int` etc. in
  -- parameter-as-Pattern slots (Balistes and future vmods).
  , module Control.Applicative
  -- Application
  , applyFn, ($)
  -- Array concat for joining `eraseAll […]` arrays across part-kinds
  -- in the Session bag.  Re-exported because Cell.Prelude
  -- deliberately skips `import Prelude` (`append` collision).
  , appendParts, (<+>)
  -- Devices
  , module Tidal.MidiDevice
  -- CV/Gate routers (es9-daemon OSC endpoints — named for forward-
  -- compat with multi-router setups; today routed through the
  -- singleton OSC client)
  , CvRouter(..)
  -- Instruments — pitched routing destinations
  , Instrument(..)
  , midiChannel
  , midiChannelWith
  , vPerOct
  -- Drum kits — sample-keyed destinations with per-hit defaults
  , DrumKit(..)
  , DrumHit
  , GateHit
  , DrumHitRef
  , midiDrumKit
  , gateDrumKit
  , hit
  , gateHit
  -- Parts
  , PitchedPart(..)
  , DrumPart(..)
  , class On
  , on
  -- Voice names — Symbol-kinded, declared once in `Tidal.Voices`.
  -- The `on` function takes these (not String) so typos become
  -- compile errors.
  , module Tidal.Voices
  -- The `>>` operator — notation routed to a destination.  Sugar
  -- over `on`: `(pitch "..." >> bass1Inst) "bass"` is equivalent
  -- to `on vBass bass1Inst (pitch "...")`.  Reads naturally
  -- left-to-right; see `docs/north-star.md` §3.
  , module Tidal.Routed
  -- The `Notation` typeclass — any source-side value that yields a
  -- Pattern.  Lets cells write `vetula { ... } >> piano1` once
  -- Vetula lands, with the same operator that works for Pattern
  -- and MiniNotation today.
  , module Tidal.Notation
  -- MiniNotation as a first-class type — `miniTyped` preserves the
  -- parsed tree (round-trip to source via `miniSource`, compose via
  -- `<>`) where `Pitch.Parse.pitch` resolves immediately to Pattern.
  , module Tidal.MiniNotation
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
  -- Polysignals (Slab C step 1) — autonomous FH-2 bank configurations
  -- declared as typed Session-level bindings, classified by the
  -- walker and shipped to fh2-daemon at baseline load.
  , module Tidal.Selene
  -- Slab C step 2: SelenePattern bindings — Tidal patterns over Selene
  -- snapshots that rotate on cycle boundaries.
  , module Tidal.SelenePattern
  -- Balistes vmod (BEAM-native MI Balistes clone, parameter-as-Pattern).
  , module Tidal.Balistes
  -- Repetitor vmod (ZR-inspired, BEAM-native rhythm corpus + per-row offsets).
  , module Tidal.Repetitor
  -- René machine (Make-Noise-René-inspired Cartesian sequencer; user-content + autonomous traversal).
  , module Tidal.Odonus
  -- Maybe — re-exported for optional fields like Selene range.
  , module Data.Maybe
  ) where

import Control.Applicative (pure)
import Data.Functor (map)
import Data.Semigroup (append, (<>)) as DataSemigroup
import Data.Semiring (zero) as PSemiring
import Data.Ring (class Ring, sub) as PRing
import Tidal.Cell.Prelude
import Data.Maybe (Maybe(..))
import Tidal.Emit (class Emitable)
import Tidal.MiniNotation
import Tidal.Notation
import Tidal.Routed
import Tidal.MidiDevice (MidiDevice(..))
import Tidal.Pitch (PitchedNote12)
import Tidal.Sound (Sound, toSound)
import Tidal.Voices (VoiceName(..), voiceNameString, vBass, vDrums, vFugue, vHeld1, vUpper)
import Data.Symbol (class IsSymbol)
import Tidal.Selene
  ( Selene(..)
  , OutputRange(..)
  , Bank(..)
  , Fh2Bank(..)
  , Es9Bank(..)
  , fh2Main
  , fh28Cv
  , fh28Gt
  , es9Main
  , es98Cv
  , es98Gt
  , ClockBase(..)
  , RandDirection(..)
  , RandScale(..)
  , RandKey(..)
  , ModSlot
  , ClockSlot
  , EnvSlot
  , EuclidSlot
  , RandSlot
  , PresetNoteSlot
  , silent
  , __
  , fixed
  , sinLFO
  , sqrLFO
  , triLFO
  , sawLFO
  , rndLFO
  , nseLFO
  , sinLFOAmp
  , sqrLFOAmp
  , triLFOAmp
  , sawLFOAmp
  , rndLFOAmp
  , nseLFOAmp
  , octoLfo
  , octoClock
  , octoEnv
  , octoEuclid
  , octoRand
  , octoPresetNote
  )
import Tidal.SelenePattern
  ( SelenePattern(..)
  , selenePattern
  )
import Tidal.Balistes
  ( Balistes(..)
  , BalistesConfig
  , BalistesSnapshot
  , balistes
  , balistesWith
  , balistesConfig
  )
import Tidal.Repetitor
  ( Repetitor(..)
  , RepetitorConfig
  , RepetitorSnapshot
  , repetitor
  , repetitorWith
  , repetitorConfig
  )
import Tidal.Odonus
  ( Odonus(..)
  , OdonusConfig
  , OdonusSnapshot
  , NavMode(..)
  , odonus
  , odonusWith
  , odonusConfig
  , replicate16
  , playing
  )

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
-- |
-- | (Extracted to `Tidal.MidiDevice` 2026-05-18 to break a cycle
-- | between Tidal.Balistes and this module.)
-- | ```
-- MidiDevice is re-exported below from Tidal.MidiDevice.

-- ---------------------------------------------------------------------------
-- CV/Gate routers
-- ---------------------------------------------------------------------------

-- | A named OSC endpoint — `CvRouter <host> <port>`.  The Studio module
-- | declares one per endpoint the rig talks to.  Since PR 2c.2
-- | (workstream C) the dispatcher routes per-alias against a Map String
-- | OSCClient: the `es9` alias (CV/gate via es9-daemon, default
-- | 127.0.0.1:57130) and the `superdirt` alias (audio via SuperDirt,
-- | default 127.0.0.1:57120) are opened at boot, and any extra endpoint
-- | a session declares is opened via the `registerCvRouter` verb.
data CvRouter = CvRouter String Int

-- ---------------------------------------------------------------------------
-- Instruments
-- ---------------------------------------------------------------------------

-- | A pitched-routing destination, parameterised by the note type
-- | it accepts.  Today every Instrument carries `PitchedNote12`; the
-- | parameter is in place so future note types (microtonal, MPE,
-- | maqam) can declare their own destinations without disturbing
-- | the existing combinators.
-- |
-- |   * `MidiInstrument` — note/vel/dur defaults preserved from PR 1
-- |     for the dispatcher's spec parser.  Per-event vel/dur (PR 2b's
-- |     deferred residual) will retire the trailing defaults.
-- |   * `VPerOctInstrument` — V/oct CV + gate-trigger via es9-daemon.
-- |     Walks to a compound `gate G + cv V voct` binding at register
-- |     time, reusing the existing Gate + CV NoteNameVoct PrimActions.
-- | (The former `note` type parameter was dropped in the typed-`Sound`
-- | realignment: pitch now lives in the `Sound` payload, so an
-- | Instrument is purely a routing destination.  Pitched authoring
-- | stays `PitchedNote12`-typed and is lifted to `Sound` at the `on`
-- | boundary via `toSound`.)
data Instrument
  = MidiInstrument MidiDevice Int Int Int Int
  | VPerOctInstrument CvRouter { gateChannel :: Int, voctBus :: Int }

-- | The plain-MIDI instrument smart constructor.  Fills in system
-- | defaults (note 60, vel 100, dur 50ms) so the user-facing
-- | declaration reads as pure routing — "a MIDI channel on this
-- | device":
-- |
-- | ```
-- | bass1 = midiChannel iac 1
-- | ```
-- |
-- | Use `midiChannelWith` when you need a specific default note (e.g.
-- | a mono synth that wants a particular triggered pitch when the
-- | pattern doesn't override).
midiChannel :: MidiDevice -> Int -> Instrument
midiChannel device channel = MidiInstrument device channel 60 100 50

-- | The full-control MIDI instrument constructor for cases where
-- | the system defaults aren't right.  Per-event vel/dur arrives in
-- | PR 2b — at that point the `defNote`/`defVel`/`defDurMs` fields
-- | will be retired.
-- |
-- | ```
-- | sub1 = midiChannelWith iac 5 { defNote: 24, defVel: 110, defDurMs: 200 }
-- | ```
midiChannelWith
  :: MidiDevice
  -> Int
  -> { defNote :: Int, defVel :: Int, defDurMs :: Int }
  -> Instrument
midiChannelWith device channel { defNote, defVel, defDurMs } =
  MidiInstrument device channel defNote defVel defDurMs

-- | V/oct instrument — a pitched destination expressed as one gate
-- | channel (the trigger) + one CV bus (the V/oct CV).  Both are
-- | es9-daemon-side numbers: gate channel 0..7 (es9-daemon gate
-- | semantics — physical jack 1..8 via the GATE_BASE offset), voct
-- | bus 0..15 (direct bus index in es9-daemon's 16-bus space).
-- |
-- | ```
-- | plaits :: Instrument PitchedNote12
-- | plaits = vPerOct cvRouter { gateChannel: 6, voctBus: 15 }
-- | ```
-- |
-- | Walks to a compound `gate <gateChannel> + cv <voctBus> voct`
-- | binding at session-load time; per-event dispatch fires both
-- | the gate trigger and the V/oct CV pre-set (with cvLeadMs head
-- | start so the CV settles before the gate arrives).
vPerOct
  :: CvRouter
  -> { gateChannel :: Int, voctBus :: Int }
  -> Instrument
vPerOct = VPerOctInstrument

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
-- | only routing, and (b) each hit dispatches through its own
-- | per-event payload (MIDI note for `MidiDrumKit`, gate channel for
-- | `GateDrumKit`).
-- |
-- |   * `MidiDrumKit fh2qd 14 [hit "bd" 36 100 50, …]` — MIDI drum
-- |     kit on device + channel; each hit declares MIDI note + vel +
-- |     duration.  Dispatch goes via the MIDI bridge.
-- |   * `GateDrumKit cvRouter [gateHit "bd" 0 30, …]` — CV gate drum
-- |     kit through es9-daemon; each hit declares a gate channel
-- |     (0..7) + duration in ms.  Dispatch fires `sendGateTrigAfter`
-- |     for each event.  Useful for modular drum-trigger setups
-- |     (Maths-as-drum, Plonk, ESX-8GT panel).
data DrumKit
  = MidiDrumKit MidiDevice Int (Array DrumHit)
  | GateDrumKit CvRouter (Array GateHit)

-- | A single gate-drum hit: a named token bound to a es9-daemon gate
-- | channel + duration.  At dispatch, each event's token resolves to
-- | one of these via the kit's hits map.
-- |
-- | ```
-- | gateHit "bd" 0 30   -- "bd" → gate channel 0, 30ms pulse
-- | ```
type GateHit =
  { name :: String
  , gateChannel :: Int
  , durMs :: Int
  }

-- | Smart constructor — direct mirror of `MidiDrumKit` for symmetry
-- | with the `midi` / `midiWith` instrument constructors.
midiDrumKit :: MidiDevice -> Int -> Array DrumHit -> DrumKit
midiDrumKit = MidiDrumKit

-- | Smart constructor for a `GateDrumKit`.
-- |
-- | ```
-- | gateKit = gateDrumKit cvRouter
-- |   [ gateHit "bd" 0 30
-- |   , gateHit "sn" 1 20
-- |   ]
-- | ```
gateDrumKit :: CvRouter -> Array GateHit -> DrumKit
gateDrumKit = GateDrumKit

-- | Construct a gate-drum hit.  Reads as:
-- |
-- | ```
-- | gateHit "bd" 0 30   -- "bd" → gate channel 0, 30ms pulse
-- | ```
gateHit :: String -> Int -> Int -> GateHit
gateHit name gateChannel durMs = { name, gateChannel, durMs }

-- ---------------------------------------------------------------------------
-- Parts
-- ---------------------------------------------------------------------------

-- | A `PitchedPart note` is a `Pattern note` bound to an
-- | `Instrument note`, tagged with a runtime mvoice name (`"bass"`,
-- | `"fugue"`, …) that the conductor uses to dispatch to the right
-- | voice supervisor.  Parameterised by `note` to support future
-- | non-12-TET pitch types; today every PitchedPart has
-- | `note ~ PitchedNote12`.
newtype PitchedPart = PitchedPart
  { mvoice      :: String
  , destination :: Instrument
  , body        :: Pattern Sound
  }

-- | A `DrumPart` is a `Pattern DrumHitRef` (sequence of named drum
-- | hits — `"bd"`, `"sn"`, `"~"` for rest) bound to a `DrumKit`.
-- | Authored as:
-- |
-- | ```
-- | qd1A :: DrumPart
-- | qd1A = on vDrums qd1 (drum "bd bd ~ ~ bd ~ sn ~")
-- | ```
newtype DrumPart = DrumPart
  { mvoice      :: String
  , destination :: DrumKit
  , body        :: Pattern Sound
  }

-- | The polymorphic `on` constructor — typeclass-dispatched on the
-- | destination type so `on vBass bass1 (mini "...")` builds a
-- | `PitchedPart` and `on vDrums qd1 (drum "...")` builds a
-- | `DrumPart`.  Functional dependency on dest → body, part keeps
-- | inference clean.
-- |
-- | Voice names are `VoiceName s` (Symbol-kinded) rather than `String`
-- | — a typo like `on vBas bass1 ...` is a name-resolution error at
-- | compile time.  Declare new voices in `Tidal.Voices`.
class On dest body part | dest -> body part where
  on :: forall s n. IsSymbol s => Notation n body
     => VoiceName s -> dest -> n -> part

-- | Pitched authoring stays `PitchedNote12`-typed (so `inKey`/`degree`/
-- | transpose are untouched); the body is lifted to the unified `Sound`
-- | carrier here via `toSound`.
instance onInstrument :: On Instrument PitchedNote12 PitchedPart where
  on vn destination body =
    PitchedPart { mvoice: voiceNameString vn, destination, body: toSound (toPattern body) }

-- | Drum / control authoring is already `Sound`-typed (`drum "…"`,
-- | `# gain "…"`), so the body passes straight through.
instance onDrumKit :: On DrumKit Sound DrumPart where
  on vn destination body =
    DrumPart { mvoice: voiceNameString vn, destination, body: toPattern body }

-- ---------------------------------------------------------------------------
-- The `>>` operator's instances — instances live here (where the
-- destination types are declared) per the orphan-instance rule.
-- The class itself lives in `Tidal.Routed` (declared without
-- destination-type imports to avoid a circular dependency).
-- ---------------------------------------------------------------------------

-- | `notation >> instrument` → `String -> PitchedPart note`.
-- | The mvoice argument is supplied at use-site (or by a cell
-- | template wrapper applying the cell name).
instance routedInstrument
  :: Notation n PitchedNote12
  => RoutedTo n Instrument (String -> PitchedPart) where
  routedTo n dest = \mvoice ->
    PitchedPart { mvoice, destination: dest, body: toSound (toPattern n) }

-- | `notation >> drumkit` → `String -> DrumPart`.
instance routedDrumKit
  :: Notation n Sound
  => RoutedTo n DrumKit (String -> DrumPart) where
  routedTo n dest = \mvoice ->
    DrumPart { mvoice, destination: dest, body: toPattern n }

-- ---------------------------------------------------------------------------
-- Session bag — erased Parts the runtime walks at baseline load
-- ---------------------------------------------------------------------------

-- | A part with its specific kind (pitched / drum) erased.  Today
-- | the pitched variant is concrete to `PitchedNote12`; when a
-- | second note type lands we have two options — add a new
-- | constructor (`AnyMaqamPart` etc.) or refactor to an existential
-- | over `Emitable note`.  The existential is the cleaner long-term
-- | shape but adds complexity (PureScript existential encoding via
-- | `Data.Exists` + class-dictionary capture) for no current
-- | benefit, so we defer until the second note type forces the
-- | issue.
data AnyPart
  = AnyPitchedPart
      { mvoice      :: String
      , destination :: Instrument
      , body        :: Pattern Sound
      }
  | AnyDrumPart
      { mvoice      :: String
      , destination :: DrumKit
      , body        :: Pattern Sound
      }

-- | Erase a typed Part into an `AnyPart`.  Typeclass-resolved so a
-- | uniform `erase <$> [parts]` works across mixed kinds.
class Erase a where
  erase :: a -> AnyPart

-- | Both part kinds now carry a `Pattern Sound` body, so erasure is a
-- | straight unwrap into the matching `AnyPart` constructor.
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
-- |
-- | `instruments` are now plain `Instrument` values (the `note` type
-- | parameter was dropped — pitch lives in the `Sound` payload).
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
