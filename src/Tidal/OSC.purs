-- | OSC (Open Sound Control) output for SuperCollider
-- |
-- | Sends OSC messages via UDP to SuperCollider (default port 57110)
-- | or SuperDirt (default port 57120)
module Tidal.OSC
  ( OSCConfig
  , OSCClient
  , defaultConfig
  , superDirtConfig
  , tidalCVConfig
  , startClient
  , stopClient
  , sendNote
  , sendSample
  -- CV/Gate for Expert Sleepers ES-9
  , sendCV
  , sendCVSlew
  , sendGate
  , sendGateTrig
  , sendGateTrigAt
  , sendGateTrigAfter
  , sendCVAfter
  , sendESXAfter
  , sendES5GateTrigAfter
  ) where

import Prelude

import Effect (Effect)

-- | OSC client configuration
type OSCConfig =
  { host :: String
  , port :: Int
  }

-- | Default config for SuperCollider scsynth
defaultConfig :: OSCConfig
defaultConfig =
  { host: "127.0.0.1"
  , port: 57110
  }

-- | Config for SuperDirt (Tidal's SuperCollider quark)
superDirtConfig :: OSCConfig
superDirtConfig =
  { host: "127.0.0.1"
  , port: 57120
  }

-- | Config for Tidal CV Engine (our custom CV output)
-- | Uses sclang default port (57120) where our OSC responders live
tidalCVConfig :: OSCConfig
tidalCVConfig =
  { host: "127.0.0.1"
  , port: 57120
  }

-- | Opaque handle to OSC client (UDP socket)
foreign import data OSCClient :: Type

-- | Start an OSC client
foreign import startClient :: OSCConfig -> Effect OSCClient

-- | Stop an OSC client
foreign import stopClient :: OSCClient -> Effect Unit

-- | Send a simple note trigger to SuperCollider
-- | /s_new synth_name node_id add_action target ...params
foreign import sendNote :: OSCClient -> String -> Int -> Effect Unit

-- | Send a sample trigger to SuperDirt
-- | /dirt/play with sample name, cycle position, etc.
foreign import sendSample :: OSCClient -> String -> Number -> Number -> Effect Unit

-- | ============================================
-- | CV/Gate for Expert Sleepers ES-9
-- | ============================================

-- | Send CV value to a channel (0-15)
-- | Value should be 0.0 to 1.0 (scaled to voltage in SuperCollider)
-- | /tidal/cv <channel> <value>
foreign import sendCV :: OSCClient -> Int -> Number -> Effect Unit

-- | Send CV with custom slew/lag time
-- | /tidal/cv/slew <channel> <value> <lag_seconds>
foreign import sendCVSlew :: OSCClient -> Int -> Number -> Number -> Effect Unit

-- | Send gate state (0 or 1) to a channel (0-7)
-- | /tidal/gate <channel> <state>
foreign import sendGate :: OSCClient -> Int -> Int -> Effect Unit

-- | Trigger gate high for a duration, then low (fires immediately on receipt)
-- | /tidal/gate/trig <channel> <duration_ms>
foreign import sendGateTrig :: OSCClient -> Int -> Number -> Effect Unit

-- | Sample-accurate gate trigger. The fire-time is `now + delay_ms` evaluated
-- | inside cv-router's audio callback. NOTE: cv-router currently keeps a
-- | single `pending_start` slot per channel, so back-to-back schedules on
-- | the same channel within one MIDIScheduler sweep clobber earlier ones —
-- | only the last write per channel actually fires. Use `sendGateTrigAfter`
-- | for typical pattern playback; reserve `sendGateTrigAt` for callers that
-- | guarantee at most one in-flight trigger per channel (e.g. link-spike).
-- | /cv/trig/at <bus> <value> <duration_ms> <delay_ms>
foreign import sendGateTrigAt :: OSCClient -> Int -> Number -> Number -> Effect Unit

-- | BEAM-side delayed gate trigger: spawns a tiny Erlang process that
-- | sleeps `delay_ms` then sends a regular `/tidal/gate/trig`. Each event
-- | arrives at cv-router separately, so `set_target+set_deadline` works
-- | correctly even when many events for the same channel are queued in
-- | one MIDIScheduler sweep. Trades sample-accuracy (~one audio buffer of
-- | jitter, ~10ms at 48kHz/512fr) for correctness with overlapping events.
foreign import sendGateTrigAfter :: OSCClient -> Int -> Number -> Number -> Effect Unit

-- | BEAM-side delayed CV update: spawns a process that sleeps `delay_ms`
-- | then sends `/cv <bus> <value>` to set a bus to a sustained value
-- | (no auto-decay deadline, no SAFETY_SCALE clamp). Used to pre-set
-- | V/oct or other continuous-CV destinations slightly before the
-- | corresponding gate trigger fires, so the receiving module sees the
-- | new pitch settled by the time it samples the trigger.
foreign import sendCVAfter :: OSCClient -> Int -> Number -> Number -> Effect Unit

-- | BEAM-side delayed ESX-8CV update. Same shape as `sendCVAfter` but
-- | targets `/esx <slot 0..7> <value>` for cv-router's Silent Way encoder
-- | (drives one of 8 CV outputs on an ESX-8CV plugged into ES-5 expansion
-- | port 2). Value range: -1.0..1.0 (mapped to ±2048 i12 in cv-router).
-- | Auto-enables Silent Way mode on cv-router on first send.
foreign import sendESXAfter :: OSCClient -> Int -> Number -> Number -> Effect Unit

-- | BEAM-side delayed ES-5 gate trig. After `delay_ms` sets bit `bit` (0..7)
-- | high via `/esx5gate`; after `delay_ms + duration_ms` sets it low. The
-- | byte map: cv-router packs the 8 gate bits into the high byte of the ES-5
-- | L lane (24-bit PCM ADAT); ES-5 decodes the high byte to its 8 built-in
-- | gate jacks. Pre-conditions: cv-router running with default device "ES-9",
-- | ES-9 loaded with `cv-router-with-es5.es9` (USB 5 → ES-5 L).
-- | /esx5gate <bit> <state>
foreign import sendES5GateTrigAfter :: OSCClient -> Int -> Number -> Number -> Effect Unit
