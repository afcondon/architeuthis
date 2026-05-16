-- | Calypso.Prelude — the DSL surface for `.tiderl` (Calypso session)
-- | source files.
-- |
-- | A `.tiderl` file IS a PureScript module that imports this prelude.
-- | The user authors devices, channels, cues, controls, etc. as
-- | ordinary PureScript declarations; the type system enforces
-- | "cue body targets a real channel", "control name matches a
-- | declared control", etc.
-- |
-- | This is the typeful-cues (Level 3) substrate. See
-- | calypso/docs/typeful-cues-plan-2026-05-15.md for the full plan.
module Calypso.Prelude
  ( module Tidal.Cell.Prelude
  -- Application
  , applyFn, ($)
  -- Devices
  , MidiDevice(..)
  -- Channels
  , Channel(..)
  -- Cues
  , Cue(..)
  , on
  , cueOf
  -- Session bag
  , Session(..)
  , AnyCue(..)
  , anyCue
  , emptySession
  , addDevice
  , addChannel
  , addCue
  ) where

import Data.Semigroup ((<>))
import Data.Symbol (class IsSymbol, reflectSymbol)
import Type.Proxy (Proxy(..))
import Tidal.Cell.Prelude
import Tidal.Pitch (Pitch)

-- | Right-associative function application — Haskell/Tidal idiom for
-- | avoiding nested parens: `f $ g $ x` reads as `f (g x)`.  Defined
-- | locally because re-exporting the prelude's `($)` collides with
-- | `class Apply`'s `apply` method that comes in via Tidal.Pattern.
infixr 0 applyFn as $

applyFn :: forall a b. (a -> b) -> a -> b
applyFn f x = f x

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
-- Channels — destinations for cue patterns
-- ---------------------------------------------------------------------------

-- | A binding from a tvoice to a destination on a device.  Today only
-- | `Channel` (MIDI note channel with default articulation) is supported;
-- | future constructors will add `Cv`, `Gate`, `Cc`, etc.
-- |
-- | ```
-- | qd1   = Channel fh2qd 14 60 100 50   -- channel 14, default note 60, vel 100, dur 50ms
-- | bass1 = Channel iac 1 36 100 50
-- | ```
data Channel
  = Channel MidiDevice Int Int Int Int

-- ---------------------------------------------------------------------------
-- Cues
-- ---------------------------------------------------------------------------

-- | A Cue is a Pattern bound to a Channel, grouped by mvoice.
-- | The mvoice Symbol is type-level for cross-checking + UI grouping.
-- |
-- | The body is `Pattern Pitch` — the typed substrate carries pitches
-- | (and samples) all the way to the voice, which renders them to
-- | dispatcher tokens at emit time using the active scale.  See
-- | `Tidal.Pitch` for the variant and `Tidal.Scales` for the
-- | rendering / `inKey` operators.
newtype Cue (mvoice :: Symbol) = Cue
  { destination :: Channel
  , body        :: Pattern Pitch
  }

-- | The standard cue constructor.  The mvoice type variable is usually
-- | inferred from the declared type ascription.
on :: forall mv. Channel -> Pattern Pitch -> Cue mv
on c body = Cue { destination: c, body }

-- | Alternate name when the mvoice is being specified explicitly
-- | rather than inferred.
cueOf :: forall mv. Channel -> Pattern Pitch -> Cue mv
cueOf = on

-- ---------------------------------------------------------------------------
-- Session bag
-- ---------------------------------------------------------------------------

-- | An mvoice-erased cue, suitable for packing into the Session's cue
-- | array.  The runtime walks this list at baseline-load time.
newtype AnyCue = AnyCue
  { mvoice      :: String
  , destination :: Channel
  , body        :: Pattern Pitch
  }

-- | Erase the mvoice Symbol into a runtime String.
anyCue :: forall mv. IsSymbol mv => Cue mv -> AnyCue
anyCue (Cue r) = AnyCue
  { mvoice: reflectSymbol (Proxy :: Proxy mv)
  , destination: r.destination
  , body: r.body
  }

-- | The Session value: the bag of declarations that the runtime walks
-- | at baseline load to register devices, register channels, and seed
-- | cues.
newtype Session = Session
  { devices  :: Array MidiDevice
  , channels :: Array Channel
  , cues     :: Array AnyCue
  }

emptySession :: Session
emptySession = Session { devices: [], channels: [], cues: [] }

addDevice :: MidiDevice -> Session -> Session
addDevice d (Session s) = Session s { devices = s.devices <> [d] }

addChannel :: Channel -> Session -> Session
addChannel c (Session s) = Session s { channels = s.channels <> [c] }

addCue :: AnyCue -> Session -> Session
addCue c (Session s) = Session s { cues = s.cues <> [c] }
