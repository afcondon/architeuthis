-- | WebSocket server for live Tidal patterns
-- |
-- | Starts a cowboy server on a specified port with a WebSocket endpoint
module Tidal.WebSocket.Server
  ( ServerConfig
  , defaultServerConfig
  , startServer
  , stopServer
  ) where

import Prelude

import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Effect (Effect)
import Effect.Console (log)
import Erl.Atom (atom)
import Erl.Cowboy as Cowboy
import Erl.Cowboy.Routes as Routes
import Erl.Data.List as List
import Erl.Data.Map as Map
import Erl.Kernel.Inet (Port(..))
import Erl.Kernel.Tcp (defaultListenOptions)
import Erl.Atom (atom) as Atom
import Erl.ModuleName (NativeModuleName(..))
import Erl.Process (Process)
import Foreign (unsafeToForeign)
import Tidal.Scheduler (Msg)
import Tidal.WebSocket.Handler as Handler

-- | Start required OTP applications (ranch, cowboy)
foreign import ensureStarted :: Effect Unit

-- | Server configuration
type ServerConfig =
  { port :: Int
  , name :: String
  }

-- | Default server config (port 8080)
defaultServerConfig :: ServerConfig
defaultServerConfig =
  { port: 8080
  , name: "tidal_ws"
  }

-- | Start the WebSocket server
startServer :: ServerConfig -> Process Msg -> Effect (Either String Unit)
startServer config schedulerPid = do
  -- Ensure cowboy and ranch are started
  ensureStarted

  log $ "Starting WebSocket server on port " <> show config.port
  log $ "Connect to ws://localhost:" <> show config.port <> "/ws"

  -- Create handler config
  let handlerConfig = Handler.wsHandler schedulerPid

  -- Set up routes - use the foreign handler module directly
  let handlerModule = NativeModuleName (Atom.atom "tidal_webSocket_handler@foreign")
  let routes = Routes.compile $ List.singleton $
        Routes.anyHost $ List.singleton $
          Routes.path "/ws"
            handlerModule
            (Routes.InitialState (unsafeToForeign handlerConfig))

  -- Create cowboy environment with dispatch
  let env = Cowboy.dispatch routes Map.empty

  -- Protocol options
  let protoOpts =
        { env: Just env
        , middlewares: Nothing
        , streamHandlers: Nothing
        }

  -- Transport options with port using TCP defaults
  let socketOpts = defaultListenOptions { port = Just (Port config.port) }
  let transportOpts = Cowboy.defaultOptions { socket_opts = Just socketOpts }

  -- Start the listener
  result <- Cowboy.startClear (atom config.name) transportOpts protoOpts

  case result of
    Right _ -> do
      log "WebSocket server started successfully"
      pure (Right unit)
    Left _err -> do
      log "Failed to start WebSocket server"
      pure (Left "Failed to start server")

-- | Stop the WebSocket server
stopServer :: ServerConfig -> Effect Unit
stopServer config = do
  log "Stopping WebSocket server..."
  Cowboy.stopListener (atom config.name)
