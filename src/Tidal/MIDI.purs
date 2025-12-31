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
