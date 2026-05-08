-- | Named bindings: a map from user-given names (`kick`, `plaits`, `filter`)
-- | to lists of `PrimAction` that fire on each pattern event.
-- |
-- | This is the dispatch-layer primitive that lets pattern source code stay
-- | musical (`kick "bd*4"`, `plaits "c4 e4 g4"`) while the cv-router
-- | geometry (gate channels, CV buses, ESX slots, future MIDI) lives in a
-- | separately-managed registry.
-- |
-- | ## Parallel implementation note
-- |
-- | This is the SERVER-SIDE copy of the binding types. The client-side copy
-- | lives at `tidal-protocol/src/TidalProtocol/Binding.purs` (a separate,
-- | MIT-licensed package consumed by tidal-cli, the browser editor, and any
-- | VS Code extension).
-- |
-- | The two MUST stay in sync. They can't be unified into one package today
-- | because purerl-tidal compiles via purs-backend-erl on an older package
-- | set (erl-0.15.3-20220629), while tidal-protocol uses the modern registry
-- | (76.1.1) for browser/Node targets. Bridging the two package sets is a
-- | future job.
-- |
-- | When you change something here, change it there too:
-- |   - PrimAction / CVMapping constructors
-- |   - parseAction / parseCompoundAction
-- |   - The wire format for `bind <name> <action-spec>`
-- |
-- | Adding a new modulation kind = adding a `PrimAction` constructor.
-- | Backward-compat is preserved because the dispatcher pattern-matches on
-- | constructors; old bindings keep working as new ones are added.
module Tidal.Binding
  ( PrimAction(..)
  , CVMapping(..)
  , Binding
  , BindingRegistry
  , defaultRegistry
  , parseAction
  , parseCompoundAction
  , ContDest(..)
  , parseContBinding
  ) where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Data.Int as Int
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.String (Pattern(..), trim)
import Data.String as String
import Data.Tuple (Tuple(..))
import Tidal.Transform (Transform)

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------

-- | How to interpret a pattern token's text content as a CV value.
-- |
-- |   * `LiteralValue`   — token is a numeric string (e.g. "0.5", "-0.3");
-- |                        non-numeric tokens (incl. "~") skip the emit and
-- |                        the bus stays at its last value (sample-and-hold).
-- |   * `NoteNameVoct`   — token is a note name like "c4", "ds5", "fs3";
-- |                        emits 1V/oct CV on the ES-9 ±10V → digital ±1.0
-- |                        scale (`midi/120`). Non-recognized note names
-- |                        skip the emit.
-- |   * `SampleNameMap`  — explicit lookup table for arbitrary tokens
-- |                        (rarely useful — `NoteNameVoct` covers the
-- |                        common pitched-voice case).
data CVMapping
  = LiteralValue
  | NoteNameVoct
  | SampleNameMap (Map String Number)

derive instance eqCVMapping :: Eq CVMapping

-- | One primitive emission per pattern event.
-- |
-- | A `Binding` is a list of these; on each pattern event the dispatcher
-- | runs through the list in order. Compound bindings like `plaits =
-- | gate 6 + cv 15 voct` are encoded as `[Gate 6, CV 15 NoteNameVoct]`.
-- |
-- | Adding a new modulation kind (MIDI note, pitch bend, envelope) means
-- | adding a constructor here and a dispatcher branch — no change to the
-- | binding registry shape, no churn for existing actions.
data PrimAction
  = Gate     { channel :: Int, latencyMs :: Int }     -- → cv-router /tidal/gate
  | CV       Int CVMapping                            -- bus 0..15 → cv-router /cv
  | ESX      { slot :: Int,    latencyMs :: Int }     -- ESX-8CV slot 0..7 → /esx
  | ES5Gate  { bit :: Int,     latencyMs :: Int }     -- ES-5 panel gate 0..7 → /esx5gate
  -- MIDI primitives — device-aware. The `device` field is an alias
  -- registered via `midi-device <alias> <real-name>`; lets the same
  -- binding shape target FH-2, iPad-AUM, Yarns, IAC bus, etc. by
  -- swapping aliases.
  | MidiNote { device :: String, channel :: Int, defaultNote :: Int, velocity :: Int, durationMs :: Int }
  -- ^ Fires a MIDI note. Token name "c4"/"e4"/etc overrides defaultNote;
  --   "~" rests; otherwise uses defaultNote (so `bd*4` triggers the
  --   default-note repeatedly, useful for drum-machine patterns).
  --   `durationMs` controls the note-on/note-off gap; defaults to 50
  --   (Tidal-typical drum trigger). Some FH-2 / Yarns presets need
  --   longer gates to register; per-binding override lets each voice
  --   use what works for its destination.
  | MidiCC { device :: String, channel :: Int, cc :: Int }
  -- ^ Sends a MIDI CC. Numeric tokens 0..1 scale to 0..127.
  | Fh2Trigger { voice :: Int, defaultNote :: Int }
  -- ^ Fires an FH-2 envelope trigger. The MIDI channel is resolved at
  --   dispatch time from the dispatcher's `fh2VoiceChannels` map
  --   (populated by the `fh2-envelope` verb), so the same FH-2
  --   destination can be reconfigured live without rebinding voices.
  --   Note name in the token (e.g. `c4`) overrides defaultNote;
  --   bare tokens (`bd`, `1`, `x`) fall back to defaultNote.
  --   Always uses the `fh2` device alias.
  --
  --   *Server-only*: not constructable via `bind` (the user-facing
  --   verb is `fh2-trigger <voice> <pattern>`). Wire-format clients
  --   like tidal-protocol's Binding.purs don't need to mirror it.

derive instance eqPrimAction :: Eq PrimAction

-- | A binding: the list of primitive actions to fire on each event of the
-- | pattern dispatched to this binding's name.
type Binding = Array PrimAction

-- | The full registry mapping names to bindings.
type BindingRegistry = Map String Binding

-- ---------------------------------------------------------------------------
-- Default registry — preserves the current `defaultSampleGateMap` /
-- `defaultSampleCVMap` behaviour as user-visible bindings.
-- ---------------------------------------------------------------------------

-- | Drum aliases mapped to gate channels 0..7 (matching cv-router's bus
-- | layout where panel jacks 1..8 = gate ch 0..7). Mirrors the GM-drum
-- | aliases in `MIDIScheduler.defaultSampleGateMap`.
drumBindings :: Array (Tuple String Binding)
drumBindings =
  [ Tuple "bd"    [gate0 0]
  , Tuple "kick"  [gate0 0]
  , Tuple "sn"    [gate0 1]
  , Tuple "snare" [gate0 1]
  , Tuple "hh"    [gate0 2]
  , Tuple "hihat" [gate0 2]
  , Tuple "ho"    [gate0 3]
  , Tuple "oh"    [gate0 3]
  , Tuple "cp"    [gate0 3]
  , Tuple "clap"  [gate0 3]
  , Tuple "rim"   [gate0 4]
  , Tuple "lt"    [gate0 5]
  , Tuple "tom"   [gate0 5]
  , Tuple "mt"    [gate0 5]
  , Tuple "ht"    [gate0 6]
  , Tuple "cy"    [gate0 7]
  , Tuple "crash" [gate0 7]
  , Tuple "rd"    [gate0 7]
  , Tuple "ride"  [gate0 7]
  ]

-- | Helper: Gate with latencyMs = 0. Default registry uses this so that
-- | the drum aliases work uncompensated; users can rebind with explicit
-- | `lat N` in the action spec if they want compensation.
gate0 :: Int -> PrimAction
gate0 ch = Gate { channel: ch, latencyMs: 0 }

-- | The Plaits voice: gate ch 6 + V/oct on bus 15. Replaces the implicit
-- | note-name-→-Plaits behaviour previously hardcoded in
-- | `defaultSampleGateMap` / `defaultSampleCVMap`.
plaitsBinding :: Tuple String Binding
plaitsBinding = Tuple "plaits" [gate0 6, CV 15 NoteNameVoct]

-- | Default registry. Drum aliases + Plaits. Loaded into the scheduler
-- | state at startup. Users can add/replace via the `bind` WS verb.
defaultRegistry :: BindingRegistry
defaultRegistry = Map.fromFoldable (drumBindings <> [plaitsBinding])

-- ---------------------------------------------------------------------------
-- Parsing — turn a `bind <name> <action-spec>` text body into a Binding.
-- ---------------------------------------------------------------------------

-- | Parse an action-spec body (text after `bind <name> `) into a Binding.
-- | Compound forms join with ` + ` (single-space delimited). Each part
-- | parses via `parseAction`.
-- |
-- | Examples (just the right-hand side):
-- |   `gate 0`                          → Right [Gate 0]
-- |   `cv 15 voct`                      → Right [CV 15 NoteNameVoct]
-- |   `esx 2`                           → Right [ESX 2]
-- |   `gate 6 + cv 15 voct`             → Right [Gate 6, CV 15 NoteNameVoct]
parseCompoundAction :: String -> Either String Binding
parseCompoundAction body =
  let
    parts = map trim (String.split (Pattern "+") body)
    step acc part = case acc of
      Left e -> Left e
      Right xs -> case parseAction part of
        Left e -> Left e
        Right a -> Right (Array.snoc xs a)
  in
    Array.foldl step (Right []) parts

-- | Parse a single primitive-action spec.
-- |
-- |   `gate <int> [lat <int>]`             → Gate
-- |   `cv <int> [literal|voct]`            → CV (default: literal)
-- |   `esx <int> [lat <int>]`              → ESX
-- |   `es5gate <int> [lat <int>]`          → ES5Gate
-- |
-- | The optional `lat N` suffix specifies a per-binding latency in ms;
-- | the dispatcher will fire this binding N ms earlier than the pattern
-- | clock would otherwise demand, so the audio onset arrives in phase
-- | with other calibrated sources. Default 0 if omitted.
parseAction :: String -> Either String PrimAction
parseAction s =
  case Array.filter (_ /= "") (String.split (Pattern " ") (trim s)) of
    ["gate", chStr] ->
      mkGate chStr "0"
    ["gate", chStr, "lat", latStr] ->
      mkGate chStr latStr

    ["cv", busStr] ->
      case Int.fromString busStr of
        Just bus -> Right (CV bus LiteralValue)
        Nothing -> Left ("cv: expected integer bus, got '" <> busStr <> "'")

    ["cv", busStr, modeStr] ->
      case Int.fromString busStr, parseMapping modeStr of
        Just bus, Just mode -> Right (CV bus mode)
        Nothing, _ -> Left ("cv: expected integer bus, got '" <> busStr <> "'")
        _, Nothing -> Left ("cv: expected mapping mode (literal|voct), got '" <> modeStr <> "'")

    ["esx", slotStr] ->
      mkESX slotStr "0"
    ["esx", slotStr, "lat", latStr] ->
      mkESX slotStr latStr

    ["es5gate", bitStr] ->
      mkES5Gate bitStr "0"
    ["es5gate", bitStr, "lat", latStr] ->
      mkES5Gate bitStr latStr

    -- midi-note <alias> <ch> <note> [velocity [duration-ms]]
    ["midi-note", device, chStr, noteStr] ->
      parseMidiNote device chStr noteStr "100" "50"
    ["midi-note", device, chStr, noteStr, velStr] ->
      parseMidiNote device chStr noteStr velStr "50"
    ["midi-note", device, chStr, noteStr, velStr, durStr] ->
      parseMidiNote device chStr noteStr velStr durStr

    -- midi-cc <alias> <ch> <cc>
    ["midi-cc", device, chStr, ccStr] ->
      case Int.fromString chStr, Int.fromString ccStr of
        Just ch, Just cc -> Right (MidiCC { device, channel: ch, cc })
        Nothing, _ -> Left ("midi-cc: expected integer channel, got '" <> chStr <> "'")
        _, Nothing -> Left ("midi-cc: expected integer cc, got '" <> ccStr <> "'")

    other ->
      Left ("unrecognized action: '" <> String.joinWith " " other <> "'")

-- | Helpers for the OSC-binding variants. Each takes the channel/slot/bit
-- | and an (already-stringified) latency-ms, validates both as Ints, and
-- | emits a typed PrimAction. Reduces the parseAction case body to one
-- | call per shape.
mkGate :: String -> String -> Either String PrimAction
mkGate chStr latStr =
  case Int.fromString chStr, Int.fromString latStr of
    Just ch, Just lat -> Right (Gate { channel: ch, latencyMs: lat })
    Nothing, _ -> Left ("gate: expected integer channel, got '" <> chStr <> "'")
    _, Nothing -> Left ("gate: expected integer lat, got '" <> latStr <> "'")

mkESX :: String -> String -> Either String PrimAction
mkESX slotStr latStr =
  case Int.fromString slotStr, Int.fromString latStr of
    Just slot, Just lat -> Right (ESX { slot, latencyMs: lat })
    Nothing, _ -> Left ("esx: expected integer slot, got '" <> slotStr <> "'")
    _, Nothing -> Left ("esx: expected integer lat, got '" <> latStr <> "'")

mkES5Gate :: String -> String -> Either String PrimAction
mkES5Gate bitStr latStr =
  case Int.fromString bitStr, Int.fromString latStr of
    Just bit, Just lat -> Right (ES5Gate { bit, latencyMs: lat })
    Nothing, _ -> Left ("es5gate: expected integer bit, got '" <> bitStr <> "'")
    _, Nothing -> Left ("es5gate: expected integer lat, got '" <> latStr <> "'")

-- | Helper for the midi-note variants — packs a typed Int validation
-- | and emits a sensible error message per missing field.
parseMidiNote :: String -> String -> String -> String -> String -> Either String PrimAction
parseMidiNote device chStr noteStr velStr durStr =
  case Int.fromString chStr, Int.fromString noteStr, Int.fromString velStr, Int.fromString durStr of
    Just ch, Just note, Just vel, Just dur ->
      Right (MidiNote { device, channel: ch, defaultNote: note, velocity: vel, durationMs: dur })
    Nothing, _, _, _ ->
      Left ("midi-note: expected integer channel, got '" <> chStr <> "'")
    _, Nothing, _, _ ->
      Left ("midi-note: expected integer note, got '" <> noteStr <> "'")
    _, _, Nothing, _ ->
      Left ("midi-note: expected integer velocity, got '" <> velStr <> "'")
    _, _, _, Nothing ->
      Left ("midi-note: expected integer duration ms, got '" <> durStr <> "'")

parseMapping :: String -> Maybe CVMapping
parseMapping = case _ of
  "literal" -> Just LiteralValue
  "voct"    -> Just NoteNameVoct
  _         -> Nothing

-- ---------------------------------------------------------------------------
-- Continuous-voice destination (server-only — no wire-protocol mirror).
-- ---------------------------------------------------------------------------

-- | Where a continuous (LFO-style) voice sends its sampled value.
-- |
-- | A continuous voice runs at the scheduler tick rate (one sample per
-- | tick) and emits one MIDI CC or CV update per sample.
-- |
-- | **Server-only**: ContDest is dispatch state, not part of the wire
-- | protocol. Do NOT mirror in tidal-protocol's Binding.purs — clients
-- | send the spec text (`midi-cc-cont …` / `cv-cont …`) and the server
-- | parses it via `parseContBinding`.
data ContDest
  = ContMidiCC { device :: String, channel :: Int, cc :: Int }
  | ContCV     { bus :: Int, transforms :: Array Transform }

derive instance eqContDest :: Eq ContDest

-- | Try to parse a binding spec as a continuous-voice declaration.
-- | Recognised shapes:
-- |
-- |   `midi-cc-cont <device> <channel> <cc>`
-- |     Each scheduler tick the voice's pattern is sampled and the
-- |     resulting 0..1 value is scaled to a 0..127 MIDI CC.
-- |
-- |   `cv-cont <bus>`
-- |     Each tick samples the pattern and emits the raw value as a
-- |     CV update on the given bus (cv-router OSC). No scaling — the
-- |     user controls the range via `range` in the expression.
-- |
-- | Returns `Nothing` for any other shape, letting the caller fall
-- | through to the discrete binding parser.
parseContBinding :: String -> Maybe ContDest
parseContBinding s =
  case Array.filter (_ /= "") (String.split (Pattern " ") (trim s)) of
    ["midi-cc-cont", device, chStr, ccStr] -> do
      ch <- Int.fromString chStr
      cc <- Int.fromString ccStr
      Just (ContMidiCC { device, channel: ch, cc })
    ["cv-cont", busStr] -> do
      bus <- Int.fromString busStr
      Just (ContCV { bus, transforms: [] })
    _ -> Nothing
