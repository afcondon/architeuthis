-- | MIDI dispatch through the link-spike CoreMIDI bridge.
-- |
-- | Replaces the old `os:cmd sendmidi` path which spawned a subprocess
-- | per event (5–30 ms jitter, untenable for dense patterns). This
-- | module emits OSC over UDP 127.0.0.1:57122 to link-spike, which
-- | resolves the destination by name and schedules CoreMIDI delivery
-- | with kernel-accurate mach-time timestamps.
-- |
-- | Wire format (consumed by link-spike's MIDI dispatcher):
-- |
-- |   /midi/note/at  ,siiiih
-- |     port_name(s)        e.g. "Patterning 3", "IAC Driver Tidal"
-- |     channel(i)          1-16
-- |     note(i)             0-127
-- |     velocity(i)         0-127
-- |     duration_ms(i)      Note Off fires at unix_micros_at + duration_ms*1000
-- |     unix_micros_at(h)   Unix microseconds at which Note On should sound
-- |
-- |   /midi/cc/at    ,siiih
-- |     port_name(s)        as above
-- |     channel(i)          1-16
-- |     cc(i)               0-127
-- |     value(i)            0-127
-- |     unix_micros_at(h)   Unix microseconds at which the CC should fire
-- |
-- | The `unix_micros_at` value is computed by the caller (typically the
-- | scheduler tick handler), which adds a delay-in-ms to
-- | `system_time(microsecond)` to yield an absolute fire time. Going
-- | over Unix microseconds rather than relative delays means link-spike
-- | doesn't need the scheduler's clock domain — they share Unix time.
module Tidal.MIDIBridge
  ( BridgeClient
  , startClient
  , scheduleNoteAt
  , scheduleCCAt
  , setLinkTempo
  ) where

import Prelude

import Effect (Effect)

-- | Opaque handle: a UDP socket to link-spike's MIDI dispatcher
-- | (host + port are constants — 127.0.0.1:57122).
foreign import data BridgeClient :: Type

-- | Open the UDP socket. Idempotent in practice — link-spike's listener
-- | doesn't care if multiple senders exist; sockets are cheap.
foreign import startClient :: Effect BridgeClient

-- | Schedule a Note On / Note Off pair at an absolute Unix-microsecond
-- | time. link-spike fires Note On at the timestamp and Note Off at
-- | `unix_micros_at + duration_ms * 1000`.
foreign import scheduleNoteAt
  :: BridgeClient
  -> String        -- destination MIDI port name
  -> Int           -- channel 1-16
  -> Int           -- note 0-127
  -> Int           -- velocity 0-127
  -> Int           -- duration_ms (note length)
  -> Number        -- unix_micros_at (use Number — i64 won't fit Int)
  -> Effect Unit

-- | Schedule a single CC value at an absolute Unix-microsecond time.
foreign import scheduleCCAt
  :: BridgeClient
  -> String        -- destination MIDI port name
  -> Int           -- channel 1-16
  -> Int           -- cc 0-127
  -> Int           -- value 0-127
  -> Number        -- unix_micros_at
  -> Effect Unit

-- | Send `/link/set-tempo <bpm>` to link-spike. link-spike captures
-- | its AblLink session, calls `set_tempo`, and Link's protocol
-- | propagates to all peers (Ableton, modular clocks, etc.). Non-
-- | scheduling — fires immediately, ignores any per-track latency.
foreign import setLinkTempo
  :: BridgeClient
  -> Number        -- bpm (e.g. 120.0)
  -> Effect Unit
