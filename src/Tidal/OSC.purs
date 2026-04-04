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

-- | Trigger gate high for a duration, then low
-- | /tidal/gate/trig <channel> <duration_ms>
foreign import sendGateTrig :: OSCClient -> Int -> Number -> Effect Unit
