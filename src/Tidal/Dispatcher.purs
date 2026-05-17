-- | Dispatcher state — owns OSC + MIDI bridge sockets and routes voice
-- | events to the right destination(s).
-- |
-- | The dispatcher is a gen_server (`tidal_dispatcher.erl`) holding:
-- |
-- |   * `bridgeClient` — the link-spike MIDI socket (UDP 127.0.0.1:57122).
-- |   * `oscClient` — the cv-router OSC socket (Maybe; only opened when
-- |     gate output is configured).
-- |   * `bindings` — per-voice-name PrimAction lists, set by the WS
-- |     handler when a `bind` verb is processed.
-- |   * `midiDevices` — alias → device-name + latency; populated by
-- |     `midi-device` verb registrations.
-- |   * `config` — gateDuration / cvLeadMs (taken from MIDIScheduler's
-- |     defaults during the migration).
-- |
-- | Voices push `dispatchEvent` calls here on each query window with
-- | { name, token, wallTimeUs }; the dispatcher looks up `name` in
-- | `bindings`, walks the PrimAction list, and formats + sends the
-- | OSC / MIDI for each.
-- |
-- | The actual format/send logic mirrors MIDIScheduler's BoundTrack
-- | dispatch (see MIDIScheduler.purs ~line 548). This module is the
-- | extract point — once PR1.4d wires the WS handler to set bindings
-- | on the dispatcher and voices push events through it, the BoundTrack
-- | path can be deleted from MIDIScheduler.
-- |
-- | NOT YET HANDLED at PR1.4c (deferred):
-- |   * Per-event param patterns (`# vel`, `# note`, etc.) — voices
-- |     don't track these yet.
-- |   * Compositional `#` joins (cross-binding fanout) — same reason.
-- |   * Continuous voices (LFO sample-and-emit). Different code path
-- |     in MIDIScheduler; will get its own migration step.
module Tidal.Dispatcher
  ( State
  , Config
  , MidiDevice
  , initialState
  , setBinding
  , setBindingFromSpec
  , removeBinding
  , lookupBinding
  , setContinuousBinding
  , lookupContinuousBinding
  , registerMidiDevice
  , setFh2VoiceChannel
  , dispatchEvent
  , dispatchContEvent
  , dispatchFh2Shape
  , setLinkTempo
  , Snapshot
  , snapshot
  , PublisherSnapshot
  , publisherSnapshot
  ) where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Data.Foldable (for_)
import Data.Tuple (Tuple(..))
import Data.Int as Int
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Number as Number
import Effect (Effect)
import Tidal.Binding (Binding, ContDest(..), PrimAction(..))
import Tidal.Binding as Binding
import Tidal.Chords as Chords
import Tidal.YarnsState (AllocResult(..), allocateVoice)
import Tidal.Log as Log
import Tidal.MIDIBridge (BridgeClient, scheduleCCAt, scheduleNoteAt)
import Tidal.MIDIBridge as MIDIBridge
import Tidal.Dispatch.Helpers (clamp7bit, interpretCV, param7bit, resolveTokenMidi)
import Tidal.OSC (OSCClient, sendCVAfter, sendCVTrigAfter, sendES5GateTrigAfter, sendESXAfter, sendGateTrigAfter)
import Tidal.Transform (applyTransforms)

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------

type Config =
  { gateDuration :: Number  -- ms; how long /tidal/gate stays high
  , cvLeadMs :: Number      -- ms; CV pre-set head start before gate
  }

type MidiDevice =
  { name :: String          -- physical port name (e.g. "IAC Driver Tidal")
  , latencyMs :: Number     -- compensate by emitting this much earlier
  }

newtype State = State
  { bridgeClient :: BridgeClient
  , oscClient :: Maybe OSCClient
  , bindings :: Map String Binding
  , continuousBindings :: Map String ContDest
  , midiDevices :: Map String MidiDevice
  , fh2VoiceChannels :: Map Int Int
  , config :: Config
  , eventCount :: Int
  }

initialState
  :: { bridgeClient :: BridgeClient
     , oscClient :: Maybe OSCClient
     , gateDuration :: Number
     , cvLeadMs :: Number
     }
  -> State
initialState init = State
  { bridgeClient: init.bridgeClient
  , oscClient: init.oscClient
  , bindings: Map.empty
  , continuousBindings: Map.empty
  , midiDevices: Map.empty
  , fh2VoiceChannels: Map.empty
  , config: { gateDuration: init.gateDuration, cvLeadMs: init.cvLeadMs }
  , eventCount: 0
  }

-- ---------------------------------------------------------------------------
-- Mutations
-- ---------------------------------------------------------------------------

setBinding :: String -> Binding -> State -> State
setBinding name binding (State s) =
  State (s { bindings = Map.insert name binding s.bindings })

-- | Install a continuous-voice binding. Used by `setBindingFromSpec`
-- | when the spec parses as `midi-cc-cont` / `cv-cont`, and by the
-- | Erlang shell when it wants to register a destination directly.
setContinuousBinding :: String -> ContDest -> State -> State
setContinuousBinding name dest (State s) =
  State (s { continuousBindings = Map.insert name dest s.continuousBindings })

-- | Parse a `bind <name> <action-spec>` body and install the resulting
-- | Binding (discrete) or ContDest (continuous).
-- |
-- | Tries `parseContBinding` first — if the spec is a continuous-voice
-- | declaration, install in `continuousBindings`. Otherwise fall
-- | through to the discrete `parseCompoundAction`.
-- |
-- | Returns Left with the parser's error if neither shape matches.
setBindingFromSpec :: String -> String -> State -> Either String State
setBindingFromSpec name spec st = case Binding.parseContBinding spec of
  Just dest -> Right (setContinuousBinding name dest st)
  Nothing -> case Binding.parseCompoundAction spec of
    Left err -> Left err
    Right binding -> Right (setBinding name binding st)

-- | Remove a binding by name. Clears both the discrete and the
-- | continuous registry — `unbind` is one verb at the WS layer and
-- | the user shouldn't have to know which kind it was.
removeBinding :: String -> State -> State
removeBinding name (State s) =
  State (s { bindings = Map.delete name s.bindings
           , continuousBindings = Map.delete name s.continuousBindings
           })

-- | Look up a discrete binding by name. Used by the WS handler at
-- | PR1.4d-ii-b to decide whether to install a voice in the new tree
-- | (binding exists) or fall back to MIDIScheduler's legacy
-- | whole-message pattern path (unbound name).
lookupBinding :: String -> State -> Maybe Binding
lookupBinding name (State s) = Map.lookup name s.bindings

-- | Look up a continuous binding by name. The PR1.5-b WS handler
-- | falls back to this when `lookupBinding` returns Nothing — if a
-- | continuous binding exists, the play-by-name-expr verb installs a
-- | Continuous voice through `tidal_voice_sup:set_voice_cont_pat`.
lookupContinuousBinding :: String -> State -> Maybe ContDest
lookupContinuousBinding name (State s) = Map.lookup name s.continuousBindings

registerMidiDevice :: String -> MidiDevice -> State -> State
registerMidiDevice alias device (State s) =
  State (s { midiDevices = Map.insert alias device s.midiDevices })

-- | Map an FH-2 voice index to a MIDI channel. Populated by the
-- | `fh2-envelope` verb; consulted at Fh2Trigger / Fh2Shape dispatch
-- | time.
-- |
-- | Auto-registers the `fh2` MIDI device alias when absent so
-- | Fh2Trigger / Fh2Shape can resolve a destination on the very
-- | first `fh2-envelope` even if the user hasn't typed
-- | `midi-device fh2 …` yet. Preserves the user's alias when one
-- | already exists (so a custom `lat` survives re-envelope).
-- |
-- | Distinct map (not riding on `bindings`) because FH-2 voices
-- | aren't bind-spec voices — the user-facing verb is
-- | `fh2-envelope <voice> <output> <channel>` and the channel
-- | mapping outlives any individual `fh2-trigger` voice in
-- | tidal_voice_sup.
setFh2VoiceChannel :: Int -> Int -> State -> State
setFh2VoiceChannel voice channel (State s) =
  let
    newDevices = case Map.lookup "fh2" s.midiDevices of
      Just _ -> s.midiDevices
      Nothing -> Map.insert "fh2" { name: "FH-2", latencyMs: 0.0 } s.midiDevices
  in
    State (s { fh2VoiceChannels = Map.insert voice channel s.fh2VoiceChannels
             , midiDevices = newDevices
             })

-- ---------------------------------------------------------------------------
-- Dispatch
-- ---------------------------------------------------------------------------

-- | Route one event. Looks up the binding, walks each PrimAction, and
-- | fires the appropriate OSC / MIDI. Increments the event counter.
-- |
-- | Unknown binding name = silent no-op (count still increments). The
-- | WS handler is the source of truth for which names exist; events
-- | for unbound names mean a voice exists for a name the dispatcher
-- | hasn't been told about yet (race during reconfig). Logging would
-- | be too noisy.
dispatchEvent
  :: { name :: String
     , token :: String
     , wallTimeUs :: Number
     , params :: Map String String
     }
  -> State
  -> Effect State
dispatchEvent { name, token, wallTimeUs, params } (State s) = do
  nowUs <- nowUnixMicros
  let
    delayMsRaw = (wallTimeUs - nowUs) / 1000.0
    delayClamped = max 0.0 delayMsRaw
    delayInt = Int.floor delayClamped
  case Map.lookup name s.bindings of
    Nothing -> pure unit
    Just binding -> do
      -- 1. Per-PrimAction dispatch: each action fires once per event,
      --    consulting `params` for slot overrides where applicable.
      for_ binding
        (dispatchPrimAction (State s) name token wallTimeUs delayClamped
                            delayInt params)
      -- 2. Compositional `#` fanout: any param NAME that matches another
      --    registered binding fires that binding's MidiCC actions with
      --    the joined value as the token. Slot-override params (consumed
      --    by step 1) are skipped here to avoid double-fire.
      for_ (Map.toUnfoldable params :: Array (Tuple String String))
        \(Tuple paramName paramValue) ->
          when (not (isSlotOverride paramName binding)) do
            dispatchComposedFanout (State s) name paramName paramValue
                                   wallTimeUs delayClamped
  pure (State (s { eventCount = s.eventCount + 1 }))

dispatchPrimAction
  :: State
  -> String              -- voice name (for logging)
  -> String              -- pattern token
  -> Number              -- absolute Unix microsecond fire time
  -> Number              -- ms delay from now (clamped)
  -> Int                 -- floor of delayClamped, for human-readable logs
  -> Map String String   -- pre-sampled per-event params for slot overrides
  -> PrimAction
  -> Effect Unit
dispatchPrimAction (State s) name token wallUs delayMs _delayInt params = case _ of
  CV bus mapping ->
    case s.oscClient, interpretCV mapping token of
      Just osc, Just value -> do
        -- CV pre-sets fire `cvLeadMs` earlier than the gate, so V/oct
        -- has time to settle before the gate trigger arrives.
        let cvDelay = max 0.0 (delayMs - s.config.cvLeadMs)
        Log.debug $ "〰 [" <> name <> "] cv bus " <> show bus <> " = " <> show value
        sendCVAfter osc bus value cvDelay
      _, _ -> pure unit

  ESX e ->
    case s.oscClient, Number.fromString token of
      Just osc, Just value -> do
        let adjusted = max 0.0 (delayMs - Int.toNumber e.latencyMs)
        Log.debug $ "⌇ [" <> name <> "] esx slot " <> show e.slot <> " = " <> show value
        sendESXAfter osc e.slot value adjusted
      _, _ -> pure unit

  Gate g ->
    when (token /= "~") do
      case s.oscClient of
        Just osc -> do
          let adjusted = max 0.0 (delayMs - Int.toNumber g.latencyMs)
          Log.debug $ "⚡ [" <> name <> "] gate " <> show g.channel <> " in " <> show (Int.floor adjusted) <> "ms"
          sendGateTrigAfter osc g.channel s.config.gateDuration adjusted
        Nothing -> pure unit

  CVTrig g ->
    when (token /= "~") do
      case s.oscClient of
        Just osc -> do
          let adjusted = max 0.0 (delayMs - Int.toNumber g.latencyMs)
          Log.debug $ "⚡ [" <> name <> "] cv-trig bus " <> show g.bus <> " in " <> show (Int.floor adjusted) <> "ms"
          sendCVTrigAfter osc g.bus s.config.gateDuration adjusted
        Nothing -> pure unit

  ES5Gate g ->
    when (token /= "~") do
      case s.oscClient of
        Just osc -> do
          let adjusted = max 0.0 (delayMs - Int.toNumber g.latencyMs)
          Log.debug $ "✦ [" <> name <> "] es5gate " <> show g.bit
          sendES5GateTrigAfter osc g.bit s.config.gateDuration adjusted
        Nothing -> pure unit

  MidiNote m ->
    when (token /= "~") do
      case Map.lookup m.device s.midiDevices of
        Nothing ->
          Log.debug $ "✗ [" <> name <> "] midi-note: unknown device alias '" <> m.device <> "'"
        Just dev -> do
          -- Token can override the default note; falls back to default
          -- for trigger-style names like "bd", "sn".  Numeric tokens
          -- (e.g. `"36"` from a typed-cue Chromatic) resolve directly.
          let note = resolveTokenMidi token m.defaultNote
          -- `# vel "..."` slot override: param value (already sampled
          -- at the event's cycle by the voice) overrides the binding's
          -- default velocity. Out-of-range / non-numeric tokens fall
          -- back to the binding default.
          let velocity = case Map.lookup "vel" params of
                Nothing -> m.velocity
                Just velTok -> case param7bit velTok of
                  Just v -> v
                  Nothing -> m.velocity
          let adjustedUnixUs = wallUs - dev.latencyMs * 1000.0
          Log.debug $ "♪ [" <> name <> "] midi " <> dev.name <> " ch" <> show m.channel <> " note " <> show note <> " vel " <> show velocity
          scheduleNoteAt s.bridgeClient dev.name m.channel note velocity m.durationMs adjustedUnixUs

  MidiCC m ->
    case Number.fromString token of
      Nothing -> pure unit  -- ~ rest or non-numeric → skip
      Just raw ->
        case Map.lookup m.device s.midiDevices of
          Nothing ->
            Log.debug $ "✗ [" <> name <> "] midi-cc: unknown device alias '" <> m.device <> "'"
          Just dev -> do
            let value7bit = clamp7bit (raw * 127.0)
            let adjustedUnixUs = wallUs - dev.latencyMs * 1000.0
            Log.debug $ "◇ [" <> name <> "] midi " <> dev.name <> " ch" <> show m.channel <> " cc" <> show m.cc <> " = " <> show value7bit
            scheduleCCAt s.bridgeClient dev.name m.channel m.cc value7bit adjustedUnixUs

  MidiDrumKit m ->
    -- Token = hit name (`bd`, `sn`, …).  Look up the hit's declared
    -- (note, velocity, durationMs) in the binding's hits map.  Unknown
    -- tokens silently skip (consistent with KitDispatch / unknown-bind
    -- behaviour); rests skip via the outer `when`.  `# vel` overrides
    -- the hit's velocity per event.
    when (token /= "~") do
      case Map.lookup token m.hits of
        Nothing ->
          Log.debug $ "  · [" <> name <> "] midi-drum-kit: unknown hit '"
            <> token <> "'"
        Just hit ->
          case Map.lookup m.device s.midiDevices of
            Nothing ->
              Log.debug $ "✗ [" <> name <> "] midi-drum-kit: unknown device alias '"
                <> m.device <> "'"
            Just dev -> do
              let velocity = case Map.lookup "vel" params of
                    Nothing -> hit.velocity
                    Just velTok -> case param7bit velTok of
                      Just v -> v
                      Nothing -> hit.velocity
              let adjustedUnixUs = wallUs - dev.latencyMs * 1000.0
              Log.debug $ "♪ [" <> name <> "] drum " <> dev.name
                <> " ch" <> show m.channel <> " hit " <> token
                <> " → note " <> show hit.note <> " vel " <> show velocity
              scheduleNoteAt s.bridgeClient dev.name m.channel hit.note
                velocity hit.durationMs adjustedUnixUs

  Fh2Trigger f ->
    -- FH-2 trigger: resolve the voice's MIDI channel via
    -- `fh2VoiceChannels` (populated by the `fh2-envelope` verb).
    -- Token note names override defaultNote; bare tokens use it.
    -- Always uses the `fh2` device alias; if the user hasn't
    -- registered it, fall back to a sensible default
    -- (`midi-device fh2 FH-2 lat <ms>` overrides this).
    when (token /= "~") do
      case Map.lookup f.voice s.fh2VoiceChannels of
        Nothing ->
          Log.debug $ "  x [" <> name <> "] fh2-trigger v" <> show f.voice
            <> ": no fh2-envelope registration; skipping"
        Just channel -> do
          let note = resolveTokenMidi token f.defaultNote
          let dev = case Map.lookup "fh2" s.midiDevices of
                Just d -> d
                Nothing -> { name: "FH-2", latencyMs: 0.0 }
          let adjustedUnixUs = wallUs - dev.latencyMs * 1000.0
          -- 200ms note duration: short enough for any envelope shape;
          -- the FH-2 restarts envelopes on note-on so duration only
          -- matters as a release-cancel boundary.
          Log.debug $ "♪ [" <> name <> "] fh2-trigger v" <> show f.voice
            <> " → " <> dev.name <> " ch" <> show channel <> " note " <> show note
          scheduleNoteAt s.bridgeClient dev.name channel note 100 200 adjustedUnixUs

  KitDispatch ->
    -- Token-as-binding-lookup-key. Used by the `kit` cell verb to
    -- fire a multi-voice pattern through a single voice gen_server.
    -- Each event's token names a binding in the registry; we walk
    -- THAT binding's PrimActions, passing the same token through so
    -- inner actions (MidiNote / Gate / …) see the voice name as
    -- their token and apply their usual defaultNote / rest logic.
    --
    -- Rests pass through. Unknown tokens are silent no-ops (same
    -- convention as the outer name lookup). Nested KitDispatch is
    -- skipped — KitDispatch isn't user-constructable via `bind`, but
    -- the guard keeps a misbehaving registry from looping forever.
    when (token /= "~") do
      case Map.lookup token s.bindings of
        Nothing -> pure unit
        Just innerBinding -> do
          Log.debug $ "→ [" <> name <> "] kit dispatch token=" <> token
          for_ innerBinding \pa -> case pa of
            KitDispatch -> pure unit
            _ -> dispatchPrimAction (State s) (name <> "/" <> token)
                                    token wallUs delayMs _delayInt params pa

  YarnsDispatch y ->
    -- Polyphonic voice allocation: token becomes one note assigned
    -- to a voice picked by the ETS-backed allocator. Voice index
    -- maps to MIDI channel `baseChannel + idx`.
    --
    -- For unison mode the allocator returns AllocBroadcast — fire
    -- the same note on all voices (analogous to chord with all-zero
    -- intervals). For poly/mono it returns AllocSingle.
    --
    -- Token resolution mirrors MidiNote: note-name tokens override
    -- defaultNote via noteNameMidi; other tokens fall back. Rests
    -- (~) skip the whole allocation.
    --
    -- `glideMs` is recorded in the binding but not yet acted on at
    -- dispatch — future work will configure FH-2 hardware glide
    -- via the per-MCV-voice config at apply time.
    when (token /= "~") do
      case Map.lookup y.device s.midiDevices of
        Nothing ->
          Log.debug $ "✗ [" <> name <> "] yarns: unknown device alias '"
                    <> y.device <> "'"
        Just dev -> do
          let note = resolveTokenMidi token y.defaultNote
              adjustedUnixUs = wallUs - dev.latencyMs * 1000.0
          alloc <- allocateVoice name wallUs
          case alloc of
            AllocFailed ->
              Log.debug $ "✗ [" <> name <> "] yarns: allocator not installed"
            AllocSingle idx -> do
              let channel = y.baseChannel + idx
              Log.debug $ "♪ [" <> name <> "] yarns ch" <> show channel
                        <> " v" <> show idx <> " note " <> show note
              scheduleNoteAt s.bridgeClient dev.name channel note
                             y.velocity y.durationMs adjustedUnixUs
            AllocBroadcast idxs -> do
              Log.debug $ "♪♪ [" <> name <> "] yarns unison × "
                        <> show (Array.length idxs)
                        <> " note " <> show note
              for_ idxs \idx ->
                let channel = y.baseChannel + idx
                in scheduleNoteAt s.bridgeClient dev.name channel note
                                  y.velocity y.durationMs adjustedUnixUs

  ChordDispatch c ->
    -- Chord broadcast: token becomes the root note, fire `voiceCount`
    -- parallel MIDI notes — one per voice channel, with intervals
    -- from the chord-shape lookup applied to the root.
    --
    -- Token resolution mirrors MidiNote: note-name tokens (`c4`,
    -- `fs3`) override defaultNote via noteNameMidi; other tokens
    -- fall back to defaultNote.
    --
    -- Shape lookup happens per event so a hot-edit of the chord
    -- table is a no-cell-restart change. Unknown shapes silently
    -- no-op at dispatch (parse-time validation rejects unknowns
    -- before the binding is installed).
    when (token /= "~") do
      case Chords.lookupChord c.shape of
        Nothing ->
          Log.debug $ "✗ [" <> name <> "] chord: unknown shape '"
                    <> c.shape <> "'"
        Just intervals -> case Map.lookup c.device s.midiDevices of
          Nothing ->
            Log.debug $ "✗ [" <> name <> "] chord: unknown device alias '"
                      <> c.device <> "'"
          Just dev -> do
            let rootNote = resolveTokenMidi token c.defaultNote
                adjustedUnixUs = wallUs - dev.latencyMs * 1000.0
                intervalCount = Array.length intervals
            Log.debug $ "♪♪ [" <> name <> "] chord " <> c.shape
                      <> " root=" <> show rootNote
                      <> " × " <> show c.voiceCount <> " voices"
            for_ (Array.range 0 (c.voiceCount - 1)) \i ->
              let interval = case Array.index intervals (i `mod` intervalCount) of
                    Just iv -> iv
                    Nothing -> 0  -- intervalCount=0 should never happen
                                  -- (parse-time validation rejects empty shapes)
                  note = rootNote + interval
                  channel = c.baseChannel + i
              in scheduleNoteAt s.bridgeClient dev.name channel note
                                c.velocity c.durationMs adjustedUnixUs

-- | Route one continuous-voice event. Looks up the voice's name in
-- | `continuousBindings`, applies the recorded `ContDest`, and emits
-- | one MIDI CC or CV update.
-- |
-- | No latency adjustment, no event-time book-keeping — continuous
-- | voices fire at "now" each tick, and whoever they reach
-- | interpolates / smooths. For MIDI CC the raw value is scaled
-- | 0..1 → 0..127. For CV the raw value passes through the
-- | destination's `transforms` pipeline unchanged.
-- |
-- | Mirror of MIDIScheduler.dispatchContValue.
dispatchContEvent
  :: { name :: String, value :: Number, wallTimeUs :: Number }
  -> State
  -> Effect State
dispatchContEvent { name, value, wallTimeUs } (State s) = do
  case Map.lookup name s.continuousBindings of
    Nothing -> pure unit
    Just (ContMidiCC m) ->
      case Map.lookup m.device s.midiDevices of
        Nothing -> pure unit
        Just dev -> do
          let v7 = clamp7bit (value * 127.0)
          let adjustedUs = wallTimeUs - dev.latencyMs * 1000.0
          Log.debug $ "≈ [" <> name <> "] cc " <> show m.cc <> " = " <> show v7
          scheduleCCAt s.bridgeClient dev.name m.channel m.cc v7 adjustedUs
    Just (ContCV c) ->
      case s.oscClient of
        Nothing -> pure unit
        Just osc -> do
          let outValue = applyTransforms c.transforms value
          Log.debug $ "≈ [" <> name <> "] cv bus " <> show c.bus <> " = " <> show outValue
          sendCVAfter osc c.bus outValue 0.0
  pure (State (s { eventCount = s.eventCount + 1 }))

-- | Live ADSR push for an FH-2 voice. Sends 4 MIDI CCs (per-MCV
-- | offset 70..73 / 74..77 / …) on the voice's MIDI channel. Not
-- | pattern-driven — fires "at now" when the user sends the verb,
-- | so the user can reshape envelopes live without touching the
-- | FH-2 Configurator. Mirror of MIDIScheduler.Fh2Shape (no latency
-- | compensation: this is a one-shot config push, not a sample-
-- | accurate pattern emission).
-- |
-- | Looks up the voice's MIDI channel in `fh2VoiceChannels`
-- | (populated by `fh2-envelope`). Skips with a debug log if the
-- | voice isn't registered. Falls back to a default `fh2` device
-- | record if the alias is absent (auto-registered by
-- | `setFh2VoiceChannel` since PR1.7b, so this is just defense
-- | against weird state).
dispatchFh2Shape
  :: { voice :: Int, a :: Int, d :: Int, sustain :: Int, r :: Int }
  -> State
  -> Effect State
dispatchFh2Shape { voice, a, d, sustain, r } (State s) = do
  case Map.lookup voice s.fh2VoiceChannels of
    Nothing ->
      Log.debug $ "fh2-shape v" <> show voice
        <> ": no fh2-envelope registration; skipping"
    Just channel -> do
      let dev = case Map.lookup "fh2" s.midiDevices of
            Just d_ -> d_
            Nothing -> { name: "FH-2", latencyMs: 0.0 }
          ccA = 70 + 4 * voice
          ccD = ccA + 1
          ccS = ccA + 2
          ccR = ccA + 3
      nowUs <- nowUnixMicros
      Log.debug $ "fh2-shape v" <> show voice <> " ch" <> show channel
        <> " CCs " <> show ccA <> "-" <> show ccR
        <> ": A=" <> show a <> " D=" <> show d
        <> " S=" <> show sustain <> " R=" <> show r
      scheduleCCAt s.bridgeClient dev.name channel ccA (clamp7bit (Int.toNumber a)) nowUs
      scheduleCCAt s.bridgeClient dev.name channel ccD (clamp7bit (Int.toNumber d)) nowUs
      scheduleCCAt s.bridgeClient dev.name channel ccS (clamp7bit (Int.toNumber sustain)) nowUs
      scheduleCCAt s.bridgeClient dev.name channel ccR (clamp7bit (Int.toNumber r)) nowUs
  pure (State s)

-- | Send `/link/set-tempo` to link-spike, which propagates the new
-- | BPM to all Link peers (Ableton, other modular clocks, this
-- | rig's own clock when it next reads the anchor). Side-effecting
-- | only — no state mutation.
-- |
-- | Migrated from MIDIScheduler.SetBpm in PR1.7d. The dispatcher's
-- | bridgeClient is the only socket left after MIDIScheduler's
-- | deletion; the clock owns the BPM value (`tidal_clock:set_bpm/1`),
-- | this just broadcasts the change.
setLinkTempo :: Number -> State -> Effect Unit
setLinkTempo bpm (State s) =
  MIDIBridge.setLinkTempo s.bridgeClient bpm

-- | Is this `#` parameter name consumed by a slot override on any of
-- | the binding's actions? If yes, the per-PrimAction dispatch already
-- | used it; the compositional fallback skips it to avoid double-fire.
-- |
-- | Currently only `vel` is a recognised slot, applying to MidiNote
-- | actions. Extend as more slots become pattern-driven.
isSlotOverride :: String -> Binding -> Boolean
isSlotOverride paramName binding = case paramName of
  "vel" -> Array.any consumesVel binding
    where
    consumesVel = case _ of
      MidiNote _ -> true
      MidiDrumKit _ -> true
      _ -> false
  _ -> false

-- | Compositional `#` fanout: when a param name matches another
-- | registered binding, fire that binding's MidiCC actions with the
-- | joined value as the token. Currently MidiCC composition only —
-- | other action types ignored. This is how `lap "x*4" #
-- | laplace-resonator-strength "0.2 0.7"` both plays the note AND
-- | sweeps the resonator CC.
dispatchComposedFanout
  :: State
  -> String   -- structure-binding name (for logging)
  -> String   -- param name
  -> String   -- pre-sampled param value
  -> Number   -- absolute Unix microsecond fire time
  -> Number   -- ms delay from now (clamped)
  -> Effect Unit
dispatchComposedFanout (State s) structName paramName paramValue wallUs delayMs =
  case Map.lookup paramName s.bindings of
    Nothing -> pure unit
    Just composedBinding -> for_ composedBinding case _ of
      MidiCC m -> case Number.fromString paramValue of
        Nothing -> pure unit
        Just raw ->
          case Map.lookup m.device s.midiDevices of
            Nothing -> pure unit
            Just dev -> do
              let v7 = clamp7bit (raw * 127.0)
              let dms = max 0.0 (delayMs - dev.latencyMs)
              let uus = wallUs - dev.latencyMs * 1000.0
              Log.debug $ "  ◇ [" <> structName <> " # " <> paramName <> "] cc " <> show m.cc <> " = " <> show v7 <> " in " <> show (Int.floor dms) <> "ms"
              scheduleCCAt s.bridgeClient dev.name m.channel m.cc v7 uus
      _ -> pure unit  -- only MidiCC composition for now

-- ---------------------------------------------------------------------------
-- Snapshot
-- ---------------------------------------------------------------------------

type Snapshot =
  { eventsReceived :: Int
  , bindingCount :: Int
  , midiDeviceCount :: Int
  , oscEnabled :: Boolean
  }

snapshot :: State -> Snapshot
snapshot (State s) =
  { eventsReceived: s.eventCount
  , bindingCount: Map.size s.bindings
  , midiDeviceCount: Map.size s.midiDevices
  , oscEnabled: case s.oscClient of
      Just _ -> true
      Nothing -> false
  }

-- | Publisher's view: everything tidal_state_pub needs to render the
-- | full JSON snapshot Calypso reads via the `state` verb.
-- |
-- | Contains opaque-to-Erlang Map values (bindings / continuousBindings /
-- | midiDevices / fh2VoiceChannels) — the Erlang publisher shuttles
-- | them through to `Tidal.StatePublisher.serializeSnapshot` which is
-- | the only consumer that reads them.
type PublisherSnapshot =
  { bindings :: Map String Binding
  , continuousBindings :: Map String ContDest
  , midiDevices :: Map String MidiDevice
  , fh2VoiceChannels :: Map Int Int
  , gateEnabled :: Boolean
  , gateDurationMs :: Number
  , cvLeadMs :: Number
  }

publisherSnapshot :: State -> PublisherSnapshot
publisherSnapshot (State s) =
  { bindings: s.bindings
  , continuousBindings: s.continuousBindings
  , midiDevices: s.midiDevices
  , fh2VoiceChannels: s.fh2VoiceChannels
  , gateEnabled: case s.oscClient of
      Just _ -> true
      Nothing -> false
  , gateDurationMs: s.config.gateDuration
  , cvLeadMs: s.config.cvLeadMs
  }

-- ---------------------------------------------------------------------------
-- Foreign — system_time(microsecond) for delay computation.
-- ---------------------------------------------------------------------------

foreign import nowUnixMicros :: Effect Number
