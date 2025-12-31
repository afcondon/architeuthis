module Main where

import Prelude
import Effect (Effect)
import Effect.Console (log)
import Erl.Kernel.Erlang (sleep)
import Data.Time.Duration (Milliseconds(..))
import Tidal.MIDI as MIDI
import Tidal.MIDIScheduler (startMIDIScheduler, MIDISchedulerConfig, defaultDrumMap)
import Tidal.WebSocket.Server as WS

main :: Effect Unit
main = do
  log "Tidal on the BEAM!"
  log "==================="
  log ""

  log "=== MIDI Devices ==="
  MIDI.listDevices

  -- MIDI config
  let midiConfig :: MIDISchedulerConfig
      midiConfig =
        { bpm: 120.0
        , lookAhead: 100.0
        , scheduleInterval: 50
        , midi: { device: "IAC Driver Tidal", channel: 10, defaultVelocity: 100 }
        , noteMap: defaultDrumMap
        , noteDuration: 50
        }

  log ""
  log "=== WebSocket → MIDI Server ==="
  -- Start MIDI scheduler for WebSocket control (starts silent)
  midiSchedulerPid <- startMIDIScheduler midiConfig "~"

  -- Start WebSocket server connected to MIDI scheduler
  _ <- WS.startServer WS.defaultServerConfig midiSchedulerPid

  log ""
  log "Live coding ready! Send patterns via WebSocket:"
  log "  ws://localhost:8080/ws"
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
