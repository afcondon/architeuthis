-- | Calypso.Prelude — the DSL surface for `.tiderl` (Calypso session)
-- | source files.
-- |
-- | A `.tiderl` file IS a PureScript module that imports this prelude.
-- | The user authors devices, bindings, cues, controls, etc. as
-- | ordinary PureScript declarations; the type system enforces
-- | "cue body targets a real binding", "control name matches a
-- | declared control", etc.
-- |
-- | This is the typeful-cues (Level 3) substrate. See
-- | calypso/docs/typeful-cues-plan-2026-05-15.md for the full plan.
-- |
-- | MVP scope (this commit): MidiDevice + MidiNote + Cue, enough to
-- | compile a one-cue hand-written session and validate the
-- | compile pipeline.
module Calypso.Prelude
  ( module Tidal.Cell.Prelude
  -- Devices
  , MidiDevice
  , midiDevice
  , class HasLatency
  , withLat
  -- Bindings
  , MidiNote
  , midiNote
  , Binding(..)
  , class IsBinding
  , toBinding
  -- Cues
  , Cue(..)
  , on
  , cueOf
  -- Session bag
  , Session(..)
  , AnyCue
  , anyCue
  , emptySession
  , addDevice
  , addBinding
  , addCue
  ) where

import Data.Semigroup ((<>))
import Data.Symbol (class IsSymbol, reflectSymbol)
import Type.Proxy (Proxy(..))
import Tidal.Cell.Prelude

-- ---------------------------------------------------------------------------
-- Devices
-- ---------------------------------------------------------------------------

-- | A physical MIDI destination. Constructed via `midiDevice`; latency
-- | is added via `withLat`. The string is the CoreMIDI port name
-- | (e.g. "FH-2", "IAC Driver Tidal"); aliases happen at the runtime
-- | layer, not here.
newtype MidiDevice = MidiDevice
  { name :: String
  , latency :: Int
  }

midiDevice :: String -> MidiDevice
midiDevice name = MidiDevice { name, latency: 0 }

-- | Anything with a settable latency. Today: MidiDevice only.
-- | Future: Es9Device, Fh2Device.
class HasLatency a where
  withLat :: a -> Int -> a

instance hasLatencyMidiDevice :: HasLatency MidiDevice where
  withLat (MidiDevice m) latency = MidiDevice m { latency = latency }

-- ---------------------------------------------------------------------------
-- Bindings
-- ---------------------------------------------------------------------------

-- | A specific MIDI-note destination: a channel + default note + velocity
-- | + duration on a given device.
newtype MidiNote = MidiNote
  { device   :: MidiDevice
  , channel  :: Int
  , note     :: Int
  , velocity :: Int
  , duration :: Int
  }

midiNote
  :: MidiDevice
  -> { ch :: Int, note :: Int, vel :: Int, dur :: Int }
  -> MidiNote
midiNote device { ch, note, vel, dur } =
  MidiNote { device, channel: ch, note, velocity: vel, duration: dur }

-- | Existential over all binding kinds. The Cue's destination is a
-- | Binding so any IsBinding can be passed to `on`.
-- |
-- | MVP only has BMidiNote; future constructors: BCv, BGate, BMidiCc.
data Binding
  = BMidiNote MidiNote

class IsBinding b where
  toBinding :: b -> Binding

instance isBindingMidiNote :: IsBinding MidiNote where
  toBinding = BMidiNote

-- ---------------------------------------------------------------------------
-- Cues
-- ---------------------------------------------------------------------------

-- | A Cue is a Pattern bound to a destination, grouped by mvoice.
-- | The mvoice Symbol is type-level for cross-checking + UI grouping.
-- | The destination is value-level (no tvoice Symbol needed because
-- | PS module scope already enforces tvoice uniqueness).
newtype Cue (mvoice :: Symbol) = Cue
  { destination :: Binding
  , body        :: Pattern String
  }

-- | The standard cue constructor. The mvoice type variable is
-- | usually inferred from the declared type ascription.
on
  :: forall b mv
   . IsBinding b
  => b
  -> Pattern String
  -> Cue mv
on b body = Cue { destination: toBinding b, body }

-- | Alternate name when the mvoice is being specified explicitly
-- | rather than inferred.
cueOf
  :: forall b mv
   . IsBinding b
  => b
  -> Pattern String
  -> Cue mv
cueOf = on

-- ---------------------------------------------------------------------------
-- Session bag
-- ---------------------------------------------------------------------------

-- | An mvoice-erased cue, suitable for packing into the Session's
-- | cue array. The runtime walks this list at baseline-load time.
data AnyCue = AnyCue
  { mvoice      :: String   -- reflected from the Cue's Symbol param
  , destination :: Binding
  , body        :: Pattern String
  }

-- | Erase the mvoice Symbol into a runtime String.
anyCue :: forall mv. IsSymbol mv => Cue mv -> AnyCue
anyCue (Cue r) = AnyCue
  { mvoice: reflectSymbol (Proxy :: Proxy mv)
  , destination: r.destination
  , body: r.body
  }

-- | The Session value: the bag of declarations that the runtime
-- | walks at baseline load to register devices, spawn voices,
-- | seed controls, etc.
-- |
-- | Constructed by `emptySession` + `addDevice` / `addBinding` /
-- | `addCue`. A typical .tiderl file ends with:
-- |
-- | ```purescript
-- | session :: Session
-- | session = emptySession
-- |   # addDevice fh2qd
-- |   # addBinding (toBinding qd1)
-- |   # addCue (anyCue qd1A)
-- |   # addCue (anyCue qd1B)
-- | ```
newtype Session = Session
  { devices  :: Array MidiDevice
  , bindings :: Array Binding
  , cues     :: Array AnyCue
  }

emptySession :: Session
emptySession = Session { devices: [], bindings: [], cues: [] }

addDevice :: MidiDevice -> Session -> Session
addDevice d (Session s) = Session s { devices = s.devices <> [d] }

addBinding :: Binding -> Session -> Session
addBinding b (Session s) = Session s { bindings = s.bindings <> [b] }

addCue :: AnyCue -> Session -> Session
addCue c (Session s) = Session s { cues = s.cues <> [c] }
