-- | Tests for `Tidal.Sink` — the typed-voice discipline layer.
-- |
-- | Verifies that:
-- |
-- |   * Each `PrimAction` shape infers the right `SinkType`
-- |     (and therefore the right kind/element/destination triple).
-- |   * Token classification distinguishes sample, note, and numeric
-- |     content with sensible falls-through to ContentMixed for
-- |     ambiguous patterns.
-- |   * `checkPattern` accepts compatible pattern/sink combinations
-- |     and rejects incompatible ones with useful messages.
-- |   * The classification of multi-token TPats summarises correctly
-- |     to ContentSample / ContentNote / ContentNumeric / ContentMixed.
module Test.SinkSpec
  ( runSinkTests
  ) where

import Prelude

import Data.Either (Either(..))
import Effect (Effect)
import Effect.Console (log)
import Tidal.Binding (CVMapping(..), PrimAction(..))
import Tidal.Parse.Parser (parseTPat)
import Tidal.Sink
  ( Element(..)
  , GenKind(..)
  , DestKind(..)
  , PatternType(..)
  , SinkType(..)
  , StringContent(..)
  , checkPattern
  , classifyTPat
  , inferPrimSinkType
  , renderSinkType
  , sinkDestKind
  , sinkElement
  , sinkKind
  )

runSinkTests :: Effect Unit
runSinkTests = do
  log ""
  log "=========================================="
  log "  Tidal.Sink (typed voices) Tests"
  log "=========================================="

  log ""
  log "--- inferPrimSinkType: each PrimAction → expected SinkType ---"
  expectInfer "Gate"
    (Gate { channel: 0, latencyMs: 0 })
    (SinkGate { channel: 0, latencyMs: 0 })
  expectInfer "CV literal"
    (CV 12 LiteralValue)
    (SinkCVLiteral { bus: 12 })
  expectInfer "CV voct"
    (CV 15 NoteNameVoct)
    (SinkCVVoct { bus: 15 })
  expectInfer "ESX"
    (ESX { slot: 3, latencyMs: 0 })
    (SinkESX { slot: 3, latencyMs: 0 })
  expectInfer "ES5Gate"
    (ES5Gate { bit: 4, latencyMs: 0 })
    (SinkES5Gate { bit: 4, latencyMs: 0 })
  expectInfer "MidiNote"
    (MidiNote { device: "live", channel: 1, defaultNote: 36, velocity: 100, durationMs: 50 })
    (SinkMidiNote { device: "live", channel: 1, defaultNote: 36, velocity: 100, durationMs: 50 })
  expectInfer "MidiCC"
    (MidiCC { device: "live", channel: 1, cc: 74 })
    (SinkMidiCC { device: "live", channel: 1, cc: 74 })

  log ""
  log "--- Projections: kind / element / destKind ---"
  expectKind "midi-note is Discrete" (SinkMidiNote nm) Discrete
  expectKind "midi-cc is Discrete" (SinkMidiCC cc1) Discrete
  expectKind "cv-cont is Continuous" (SinkContCV { bus: 12 }) Continuous
  expectKind "midi-cc-cont is Continuous" (SinkContMidiCC cc1) Continuous

  expectElement "midi-note is SampleOrNote" (SinkMidiNote nm) SampleOrNote
  expectElement "midi-cc is Number" (SinkMidiCC cc1) Number
  expectElement "gate is Trigger" (SinkGate { channel: 0, latencyMs: 0 }) Trigger
  expectElement "cv-voct is Note" (SinkCVVoct { bus: 15 }) Note
  expectElement "cv-cont is Number" (SinkContCV { bus: 12 }) Number

  expectDestKind "midi-note → ToMidi" (SinkMidiNote nm) ToMidi
  expectDestKind "cv-cont → ToCV" (SinkContCV { bus: 12 }) ToCV
  expectDestKind "gate → ToGate" (SinkGate { channel: 0, latencyMs: 0 }) ToGate
  expectDestKind "esx → ToESX" (SinkESX { slot: 0, latencyMs: 0 }) ToESX
  expectDestKind "es5gate → ToES5" (SinkES5Gate { bit: 0, latencyMs: 0 }) ToES5

  log ""
  log "--- classifyTPat: token-level pattern classification ---"
  expectClassify "drum samples" "bd sn hh cp" ContentSample
  expectClassify "single drum" "bd" ContentSample
  expectClassify "note tokens (mini-notation note names)" "c4 e4 g4" ContentNote
  expectClassify "sharp note tokens" "f#3 g#3 a#3" ContentNote
  expectClassify "numeric tokens" "0.3 0.5 0.7" ContentNumeric
  expectClassify "integer tokens" "60 64 67 71" ContentNumeric
  expectClassify "mixed sample + note" "bd c4 sn e4" ContentMixed
  expectClassify "all rests" "~ ~ ~" ContentEmpty
  expectClassify "stack of drums" "[bd, sn, hh]" ContentSample
  expectClassify "fast modifier" "bd*4" ContentSample
  expectClassify "alternation of notes" "<c4 e4 g4>" ContentNote

  log ""
  log "--- checkPattern: compatibility matrix ---"
  -- midi-note: permissive on string patterns, rejects numeric
  expectOK "midi-note ← drum samples"
    (SinkMidiNote nm) (PatString ContentSample)
  expectOK "midi-note ← note tokens"
    (SinkMidiNote nm) (PatString ContentNote)
  expectFail "midi-note ← Pattern Number"
    (SinkMidiNote nm) PatNumber

  -- midi-cc: numeric only (or permissive ContentMixed)
  expectOK "midi-cc ← numeric tokens"
    (SinkMidiCC cc1) (PatString ContentNumeric)
  expectFail "midi-cc ← drum samples (no-op trap)"
    (SinkMidiCC cc1) (PatString ContentSample)
  expectFail "midi-cc ← note tokens"
    (SinkMidiCC cc1) (PatString ContentNote)
  expectOK "midi-cc ← Pattern Number"
    (SinkMidiCC cc1) PatNumber

  -- midi-cc-cont: STRICT — only Pattern Number
  expectOK "midi-cc-cont ← Pattern Number (oscillator)"
    (SinkContMidiCC cc1) PatNumber
  expectFail "midi-cc-cont ← drum samples"
    (SinkContMidiCC cc1) (PatString ContentSample)
  expectFail "midi-cc-cont ← numeric mini-notation"
    (SinkContMidiCC cc1) (PatString ContentNumeric)

  -- cv-cont: STRICT — only Pattern Number
  expectOK "cv-cont ← Pattern Number"
    (SinkContCV { bus: 12 }) PatNumber
  expectFail "cv-cont ← drum samples"
    (SinkContCV { bus: 12 }) (PatString ContentSample)

  -- cv-voct: notes accepted, sample-style rejected
  expectOK "cv-voct ← note tokens"
    (SinkCVVoct { bus: 15 }) (PatString ContentNote)
  expectFail "cv-voct ← drum samples"
    (SinkCVVoct { bus: 15 }) (PatString ContentSample)

  -- gate: any string token fires; numeric pattern rejected
  expectOK "gate ← drum samples"
    (SinkGate { channel: 0, latencyMs: 0 }) (PatString ContentSample)
  expectOK "gate ← note tokens"
    (SinkGate { channel: 0, latencyMs: 0 }) (PatString ContentNote)
  expectFail "gate ← Pattern Number"
    (SinkGate { channel: 0, latencyMs: 0 }) PatNumber

  log ""
  log "--- renderSinkType: unaliased rendering ---"
  expectRender (SinkMidiNote nm)
    "Sink Discrete Sample|Note (ToMidi device=\"live\" ch=1 note=36 vel=100 dur=50)"
  expectRender (SinkContCV { bus: 12 })
    "Sink Continuous Number (ToCV bus=12)"
  expectRender (SinkContMidiCC cc1)
    "Sink Continuous Number (ToMidi device=\"live\" ch=1 cc=74)"
  expectRender (SinkCVVoct { bus: 15 })
    "Sink Discrete Note (ToCV bus=15 mode=voct)"
  expectRender (SinkGate { channel: 6, latencyMs: 5 })
    "Sink Discrete Trigger (ToGate ch=6 lat=5)"

  log ""
  log "=========================================="

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

nm :: { device :: String, channel :: Int, defaultNote :: Int, velocity :: Int, durationMs :: Int }
nm = { device: "live", channel: 1, defaultNote: 36, velocity: 100, durationMs: 50 }

cc1 :: { device :: String, channel :: Int, cc :: Int }
cc1 = { device: "live", channel: 1, cc: 74 }

expectInfer :: String -> PrimAction -> SinkType -> Effect Unit
expectInfer desc act expected =
  let got = inferPrimSinkType act
  in if got == expected
       then log $ "  ✓ " <> desc
       else log $ "  ✗ " <> desc <> ": got "
              <> renderSinkType got <> ", expected " <> renderSinkType expected

expectKind :: String -> SinkType -> GenKind -> Effect Unit
expectKind desc s k =
  if sinkKind s == k
    then log $ "  ✓ " <> desc
    else log $ "  ✗ " <> desc <> ": got " <> show (sinkKind s)

expectElement :: String -> SinkType -> Element -> Effect Unit
expectElement desc s e =
  if sinkElement s == e
    then log $ "  ✓ " <> desc
    else log $ "  ✗ " <> desc <> ": got " <> show (sinkElement s)

expectDestKind :: String -> SinkType -> DestKind -> Effect Unit
expectDestKind desc s d =
  if sinkDestKind s == d
    then log $ "  ✓ " <> desc
    else log $ "  ✗ " <> desc <> ": got " <> show (sinkDestKind s)

expectClassify :: String -> String -> StringContent -> Effect Unit
expectClassify desc src expected =
  case parseTPat src of
    Left err ->
      log $ "  ✗ " <> desc <> ": parse failed for '" <> src <> "': " <> show err
    Right tpat ->
      let got = classifyTPat tpat
      in if got == expected
           then log $ "  ✓ " <> desc <> " '" <> src <> "': " <> show got
           else log $ "  ✗ " <> desc <> " '" <> src <> "': got "
                  <> show got <> ", expected " <> show expected

expectOK :: String -> SinkType -> PatternType -> Effect Unit
expectOK desc sink pat = case checkPattern sink pat of
  Right _ -> log $ "  ✓ " <> desc
  Left msg -> log $ "  ✗ " <> desc <> " (unexpectedly rejected): " <> msg

expectFail :: String -> SinkType -> PatternType -> Effect Unit
expectFail desc sink pat = case checkPattern sink pat of
  Left _ -> log $ "  ✓ " <> desc <> " (correctly rejected)"
  Right _ -> log $ "  ✗ " <> desc <> " (should have been rejected but was accepted)"

expectRender :: SinkType -> String -> Effect Unit
expectRender sink expected =
  let got = renderSinkType sink
  in if got == expected
       then log $ "  ✓ render: " <> got
       else log $ "  ✗ render: got '" <> got <> "', expected '" <> expected <> "'"
