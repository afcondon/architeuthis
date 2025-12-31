-- | WebSocket handler for live pattern updates
-- |
-- | Receives pattern strings from clients and forwards to scheduler
module Tidal.WebSocket.Handler
  ( Config
  , HandlerState
  , _behaviour
  , wsHandler
  ) where

import Prelude

import Attribute (Attribute(..), Behaviour)
import Data.Either (Either(..))
import Effect (Effect)
import Effect.Class (liftEffect)
import Effect.Console (log)
import Effect.Uncurried (EffectFn1, EffectFn2, mkEffectFn1, mkEffectFn2)
import Erl.Cowboy.Handlers.WebSocket as WS
import Erl.Cowboy.Req (Req)
import Erl.Data.List as List
import Erl.Process (Process, send)
import Tidal.Parse.Parser (parse)
import Tidal.Scheduler (Msg(..))

-- | Convert binary to string (UTF-8)
foreign import binaryToString :: forall a. a -> String

-- | Configuration passed to init
type Config =
  { schedulerPid :: Process Msg
  }

-- | Handler state
type HandlerState =
  { schedulerPid :: Process Msg
  , connected :: Boolean
  }

-- | Behaviour declaration for cowboy_websocket
_behaviour :: WS.CowboyWebsocketBehaviour
_behaviour = WS.cowboyWebsocketBehaviour
  { init
  , websocket_handle
  , websocket_info
  }

-- | Initialize WebSocket connection
init :: WS.InitHandler Config HandlerState
init = mkEffectFn2 \req config -> do
  log "WebSocket: New connection"
  pure $ WS.initResult
    { schedulerPid: config.schedulerPid
    , connected: true
    }
    req

-- | Handle incoming WebSocket frames
websocket_handle :: WS.FrameHandler HandlerState
websocket_handle = mkEffectFn2 \inFrame state -> do
  case WS.decodeInFrame inFrame of
    WS.TextFrame text -> do
      log $ "WebSocket: Received pattern: " <> text
      -- Validate the pattern before sending
      case parse text of
        Right _ -> do
          -- Valid pattern - send to scheduler
          send state.schedulerPid (UpdatePattern text)
          let response = WS.outFrame (WS.TextFrame ("OK: " <> text))
          pure $ WS.replyResult state (List.singleton response)
        Left err -> do
          log $ "WebSocket: Parse error: " <> show err
          let response = WS.outFrame (WS.TextFrame ("ERROR: " <> show err))
          pure $ WS.replyResult state (List.singleton response)

    WS.BinaryFrame bin -> do
      -- Try to decode as UTF-8 text
      let text = binaryToString bin
      log $ "WebSocket: Received binary pattern: " <> text
      case parse text of
        Right _ -> do
          send state.schedulerPid (UpdatePattern text)
          let response = WS.outFrame (WS.TextFrame ("OK: " <> text))
          pure $ WS.replyResult state (List.singleton response)
        Left err -> do
          let response = WS.outFrame (WS.TextFrame ("ERROR: " <> show err))
          pure $ WS.replyResult state (List.singleton response)

    WS.PingFrame _ -> do
      pure $ WS.okResult state

    WS.PongFrame _ -> do
      pure $ WS.okResult state

-- | Handle Erlang messages sent to WebSocket process
websocket_info :: WS.InfoHandler String HandlerState
websocket_info = mkEffectFn2 \info state -> do
  -- Forward info messages to client
  log $ "WebSocket: Sending info: " <> info
  let response = WS.outFrame (WS.TextFrame info)
  pure $ WS.replyResult state (List.singleton response)

-- | Create a WebSocket handler configuration
wsHandler :: Process Msg -> Config
wsHandler schedulerPid = { schedulerPid }
