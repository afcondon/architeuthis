module Main where

import Prelude
import Effect (Effect)
import Effect.Console (log)
import Erl.Kernel.Erlang (sleep)
import Data.Time.Duration (Milliseconds(..))
import Tidal.Application (startApplication)
import Tidal.MIDI as MIDI
import Tidal.LinkAnchor as LinkAnchor
import Tidal.WebSocket.Server as WS

main :: Effect Unit
main = do
  log "Tidal on the BEAM!"
  log "==================="
  log ""

  log "=== OTP supervision tree ==="
  -- Brings up purerl_tidal_sup with its children: tidal_voice_sup,
  -- tidal_dispatcher, tidal_clock, tidal_state_pub. The clock starts
  -- ticking immediately; voice_sup is empty until `bind` adds voices.
  -- See docs/per-voice-refactor-plan.md.
  startApplication

  log ""
  log "=== Link anchor listener ==="
  -- Always start; if no link-spike is running, queries return Nothing
  -- and any consumer falls back to its free-running clock.
  LinkAnchor.start

  log ""
  log "=== MIDI Devices ==="
  MIDI.listDevices

  log ""
  log "=== WebSocket server ==="
  -- All dispatch reaches the supervision tree via registered names.
  _ <- WS.startServer WS.defaultServerConfig

  log ""
  log "Live coding ready! Send patterns via WebSocket:"
  log "  ws://localhost:3012/ws"
  log ""
  log "Example patterns:"
  log "  ws.send('bd sn hh cp')     // basic 4/4"
  log "  ws.send('bd*4')            // kick on every beat"
  log "  ws.send('bd(3,8)')         // euclidean"
  log "  ws.send('[bd sn] hh*2')    // stacked"
  log "  ws.send('~')               // silence"
  log ""
  log "Press Ctrl+C to stop..."

  -- Keep running indefinitely (10 minutes)
  sleep (Milliseconds 600000.0)

  log ""
  log "=== Done ==="
