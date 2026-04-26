-- | WebSocket handler for live pattern updates
-- |
-- | Receives pattern strings from clients and forwards to scheduler.
-- | Supports four message formats:
-- |   1. `gate <ch> <pattern>`  — set gate track on channel <ch>; replaces
-- |      only that channel, leaves other tracks untouched. Live-coding shape.
-- |   2. `cv <bus> <pattern>`   — set CV track on bus <bus>; tokens are numeric
-- |      and emitted as sustained `/cv` updates. Same per-track replacement.
-- |   3. Plain pattern string: "bd sn hh cp" — legacy single-pattern update;
-- |      replaces ALL tracks with one gate track.
-- |   4. JSON with per-track channels: {"tracks":[...],"combined":"bd sn, hh"}
-- |      — legacy, mostly unused now.
module Tidal.WebSocket.Handler
  ( Config
  , HandlerState
  , _behaviour
  , wsHandler
  ) where

import Prelude

import Attribute (Attribute(..), Behaviour)
import Data.Either (Either(..))
import Data.Int as Int
import Data.Maybe (Maybe(..))
import Data.String as String
import Data.String.Pattern (Pattern(..))
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

-- | Parse an incoming text message into a scheduler Msg.
-- | Returns Left with a human-readable error if anything fails to parse.
parseInputMessage :: String -> Either String Msg
parseInputMessage text =
  case String.stripPrefix (Pattern "gate ") text of
    Just rest -> parsePrefixed rest UpdateGateTrack "gate"
    Nothing -> case String.stripPrefix (Pattern "cv ") text of
      Just rest -> parsePrefixed rest UpdateCVTrack "cv"
      Nothing ->
        let pattern = extractPattern text
        in case parse pattern of
          Right _ -> Right (UpdatePattern pattern)
          Left err -> Left ("legacy parse: " <> show err)
  where
  parsePrefixed rest ctor name =
    case String.indexOf (Pattern " ") rest of
      Nothing -> Left (name <> " expects: " <> name <> " <num> <pattern>")
      Just idx ->
        let numStr = String.take idx rest
            pat = String.drop (idx + 1) rest
        in case Int.fromString numStr of
          Nothing -> Left (name <> " <num> not parsed: '" <> numStr <> "'")
          Just n -> case parse pat of
            Right _ -> Right (ctor n pat)
            Left err -> Left (name <> " pattern parse error: " <> show err)

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
      handleText state text

    WS.BinaryFrame bin -> do
      let text = binaryToString bin
      log $ "WebSocket: Received binary message: " <> text
      handleText state text

    WS.PingFrame _ -> do
      pure $ WS.okResult state

    WS.PongFrame _ -> do
      pure $ WS.okResult state
  where
  handleText st text =
    case parseInputMessage text of
      Right msg -> do
        send st.schedulerPid msg
        let response = WS.outFrame (WS.TextFrame ("OK: " <> text))
        pure $ WS.replyResult st (List.singleton response)
      Left err -> do
        log $ "WebSocket: " <> err
        let response = WS.outFrame (WS.TextFrame ("ERROR: " <> err))
        pure $ WS.replyResult st (List.singleton response)

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
