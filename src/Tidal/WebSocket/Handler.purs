-- | WebSocket handler for live pattern updates
-- |
-- | Receives pattern strings from clients and forwards to scheduler
-- | Supports two message formats:
-- |   1. Plain pattern string: "bd sn hh cp"
-- |   2. JSON with per-track channels: {"tracks":[...],"combined":"bd sn, hh"}
module Tidal.WebSocket.Handler
  ( Config
  , HandlerState
  , _behaviour
  , wsHandler
  ) where

import Prelude

import Attribute (Attribute(..), Behaviour)
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.String as String
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

-- | Extract pattern from message (handles both plain text and JSON formats)
-- | JSON format: {"tracks":[...],"combined":"pattern here"}
extractPattern :: String -> String
extractPattern msg =
  -- Check if it looks like JSON (starts with {)
  if String.take 1 msg == "{"
    then
      -- Extract "combined":"..." value
      -- Find "combined":" and extract until next unescaped "
      case String.indexOf (String.Pattern "\"combined\":\"") msg of
        Nothing -> msg  -- Not valid JSON format, try as plain pattern
        Just idx ->
          let afterKey = String.drop (idx + 12) msg  -- Skip past "combined":"
          in extractUntilQuote afterKey ""
    else msg  -- Plain pattern string

-- | Extract string content until closing quote (handling escapes)
extractUntilQuote :: String -> String -> String
extractUntilQuote remaining acc =
  let first = String.take 1 remaining
      rest = String.drop 1 remaining
  in
    if first == "" then acc  -- End of string
    else if first == "\\" then
      -- Escape sequence - include next char
      let escaped = String.take 1 rest
          afterEscape = String.drop 1 rest
      in extractUntilQuote afterEscape (acc <> escaped)
    else if first == "\"" then acc  -- Found closing quote
    else extractUntilQuote rest (acc <> first)

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
      log $ "WebSocket: Received message: " <> text
      -- Extract pattern from message (handles JSON or plain text)
      let pattern = extractPattern text
      log $ "WebSocket: Extracted pattern: " <> pattern
      -- Validate the pattern before sending
      case parse pattern of
        Right _ -> do
          -- Valid pattern - send to scheduler
          send state.schedulerPid (UpdatePattern pattern)
          let response = WS.outFrame (WS.TextFrame ("OK: " <> pattern))
          pure $ WS.replyResult state (List.singleton response)
        Left err -> do
          log $ "WebSocket: Parse error: " <> show err
          let response = WS.outFrame (WS.TextFrame ("ERROR: " <> show err))
          pure $ WS.replyResult state (List.singleton response)

    WS.BinaryFrame bin -> do
      -- Try to decode as UTF-8 text
      let text = binaryToString bin
      log $ "WebSocket: Received binary message: " <> text
      let pattern = extractPattern text
      case parse pattern of
        Right _ -> do
          send state.schedulerPid (UpdatePattern pattern)
          let response = WS.outFrame (WS.TextFrame ("OK: " <> pattern))
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
