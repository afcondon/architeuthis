-- | MIDI configuration types + diagnostic helpers.
-- |
-- | The actual MIDI dispatch (note/CC emission to a destination) lives
-- | in `Tidal.MIDIBridge`, which sends OSC to the link-spike daemon for
-- | kernel-timestamped CoreMIDI delivery. This module retains:
-- |
-- |   - the `MIDIConfig` record (default device + channel + velocity)
-- |   - `listDevices`, an at-startup diagnostic that prints the
-- |     destinations CoreMIDI / sendmidi sees
-- |
-- | The previous os:cmd-sendmidi-per-event path was removed entirely
-- | because it added 5–30 ms of subprocess-spawn jitter — untenable for
-- | dense patterns and CC streams.
module Tidal.MIDI
  ( MIDIConfig
  , defaultConfig
  , abletonConfig
  , listDevices
  ) where

import Prelude

import Effect (Effect)

-- | MIDI client configuration. Used by the scheduler as the fallback
-- | port-name + channel for legacy single-pattern dispatch (where no
-- | binding has been registered).
type MIDIConfig =
  { device :: String
  , channel :: Int
  , defaultVelocity :: Int
  }

-- | Default config using IAC virtual MIDI bus on macOS.
defaultConfig :: MIDIConfig
defaultConfig =
  { device: "IAC Driver Bus 1"
  , channel: 1
  , defaultVelocity: 100
  }

-- | Config for Ableton (same as default, using IAC).
abletonConfig :: MIDIConfig
abletonConfig = defaultConfig

-- | List available MIDI destinations. Diagnostic only — printed at
-- | startup so the user can confirm CoreMIDI sees the apps they expect.
foreign import listDevices :: Effect Unit
