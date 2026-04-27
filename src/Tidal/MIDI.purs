-- | MIDI output for Tidal patterns
-- |
-- | Uses the `sendmidi` command-line tool (brew install sendmidi)
-- | to send MIDI notes to any MIDI destination (e.g., Ableton Live)
module Tidal.MIDI
  ( MIDIConfig
  , MIDIClient
  , defaultConfig
  , abletonConfig
  , startClient
  , stopClient
  , noteOn
  , noteOff
  , sendDrum
  , scheduleDrum
  , scheduleDrumOnChannel
  , scheduleNoteOnDevice
  , scheduleCCOnDevice
  , listDevices
  ) where

import Prelude

import Effect (Effect)

-- | MIDI client configuration
type MIDIConfig =
  { device :: String      -- MIDI device name (or "IAC Driver Bus 1" for virtual)
  , channel :: Int        -- MIDI channel (1-16)
  , defaultVelocity :: Int  -- Default velocity (0-127)
  }

-- | Default config using IAC virtual MIDI bus on macOS
defaultConfig :: MIDIConfig
defaultConfig =
  { device: "IAC Driver Bus 1"
  , channel: 1
  , defaultVelocity: 100
  }

-- | Config for Ableton (same as default, using IAC)
abletonConfig :: MIDIConfig
abletonConfig = defaultConfig

-- | Opaque MIDI client handle
foreign import data MIDIClient :: Type

-- | List available MIDI devices
foreign import listDevices :: Effect Unit

-- | Start MIDI client (validates device exists)
foreign import startClient :: MIDIConfig -> Effect MIDIClient

-- | Stop MIDI client
foreign import stopClient :: MIDIClient -> Effect Unit

-- | Send note on
-- | noteOn client note velocity
foreign import noteOn :: MIDIClient -> Int -> Int -> Effect Unit

-- | Send note off
foreign import noteOff :: MIDIClient -> Int -> Effect Unit

-- | Send drum trigger - note on followed by note off after duration
-- | sendDrum client note velocity durationMs
foreign import sendDrum :: MIDIClient -> Int -> Int -> Int -> Effect Unit

-- | Schedule drum trigger after a delay
-- | scheduleDrum client note velocity durationMs delayMs
foreign import scheduleDrum :: MIDIClient -> Int -> Int -> Int -> Int -> Effect Unit

-- | Schedule drum trigger on a specific channel (overrides client default)
-- | scheduleDrumOnChannel client channel note velocity durationMs delayMs
foreign import scheduleDrumOnChannel :: MIDIClient -> Int -> Int -> Int -> Int -> Int -> Effect Unit

-- | Schedule a MIDI note on an arbitrary device by name. Bypasses
-- | MIDIClient — opens a one-shot sendmidi process for note-on +
-- | scheduled note-off. Used by binding-dispatch's MidiNote PrimAction
-- | so the same scheduler can target FH-2, AUDIO4c USB2 (iPad), Yarns,
-- | etc. without holding open a port per device.
-- |
-- | scheduleNoteOnDevice device channel note velocity durationMs delayMs
foreign import scheduleNoteOnDevice
  :: String -> Int -> Int -> Int -> Int -> Int -> Effect Unit

-- | Schedule a MIDI CC on an arbitrary device by name.
-- | scheduleCCOnDevice device channel cc value7bit delayMs
foreign import scheduleCCOnDevice
  :: String -> Int -> Int -> Int -> Int -> Effect Unit
