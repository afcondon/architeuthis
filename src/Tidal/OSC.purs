-- | OSC (Open Sound Control) output for SuperCollider
-- |
-- | Sends OSC messages via UDP to SuperCollider (default port 57110)
-- | or SuperDirt (default port 57120)
module Tidal.OSC
  ( OSCConfig
  , OSCClient
  , defaultConfig
  , superDirtConfig
  , startClient
  , stopClient
  , sendNote
  , sendSample
  ) where

import Prelude

import Data.Maybe (Maybe(..))
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
