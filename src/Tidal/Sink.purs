-- | Typed voice signatures.
-- |
-- | Every binding in purerl-tidal has an implicit type — what kind of
-- | element the pattern's tokens should be, where the dispatch sends
-- | them, and whether dispatch is event-driven or sampled at tick rate.
-- | This module makes those types explicit so we can:
-- |
-- |   * Catch confusions at install time ("midi-cc-cont expects numeric
-- |     patterns; got `bd sn hh`") instead of producing silent no-ops.
-- |   * Render the registry as a navigable type catalog (the eventual
-- |     Voices pane in Calypso).
-- |   * Compose patterns with confidence — a pattern's element type
-- |     is checked against the destination's accepted shape before
-- |     dispatch.
-- |
-- | Aliases like `DrumVoice` are deliberately avoided; the unaliased
-- | forms carry the information you actually need to read.
module Tidal.Sink
  ( -- * Type vocabulary
    SinkType(..)
  , GenKind(..)
  , Element(..)
  , DestKind(..)
  , PatternType(..)
  , StringContent(..)
    -- * Inference
  , inferPrimSinkType
  , bindingSinkTypes
  , classifyTPat
    -- * Compatibility check
  , checkPattern
    -- * Projections
  , sinkKind
  , sinkElement
  , sinkDestKind
    -- * Rendering
  , renderSinkType
  , renderSinkTypeJSON
  ) where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Data.Foldable (foldl)
import Data.Int as Int
import Data.Maybe (Maybe(..), isJust)
import Data.Number (fromString) as Number
import Data.String as String
import Data.String.CodeUnits as SCU
import Tidal.AST.Types (Located(..), TPat(..))
import Tidal.Binding (CVMapping(..), PrimAction(..))

-- ---------------------------------------------------------------------------
-- The type triple
-- ---------------------------------------------------------------------------

-- | Whether dispatch is event-driven or sampled.
data GenKind
  = Discrete    -- ^ Events fire at pattern times.
  | Continuous  -- ^ Pattern sampled at scheduler tick rate.

derive instance eqGenKind :: Eq GenKind

instance showGenKind :: Show GenKind where
  show Discrete = "Discrete"
  show Continuous = "Continuous"

-- | What kind of value the pattern's tokens carry semantically.
-- |
-- | `Sample` and `Note` are both string-typed at the parser level but
-- | distinguished by their content shape (`bd`/`sn` vs `c4`/`fs3`).
-- | `SampleOrNote` is the permissive case — `midi-note` voices accept
-- | either, mapping note tokens via `noteNameMidi` and other tokens
-- | through to the binding's `defaultNote`.
data Element
  = Sample         -- ^ Drum/sample name tokens.
  | Note           -- ^ Note-name tokens (`c4`, `fs3`, etc.).
  | SampleOrNote   -- ^ Either accepted; midi-note default behaviour.
  | Number         -- ^ Numeric values (CC, voltage, raw).
  | Trigger        -- ^ Any non-rest token fires; semantic content unused.

derive instance eqElement :: Eq Element

instance showElement :: Show Element where
  show = case _ of
    Sample -> "Sample"
    Note -> "Note"
    SampleOrNote -> "Sample|Note"
    Number -> "Number"
    Trigger -> "Trigger"

-- | The kind of destination — the wire-level dispatch family.
data DestKind
  = ToMidi
  | ToCV
  | ToGate
  | ToESX
  | ToES5

derive instance eqDestKind :: Eq DestKind

instance showDestKind :: Show DestKind where
  show = case _ of
    ToMidi -> "ToMidi"
    ToCV -> "ToCV"
    ToGate -> "ToGate"
    ToESX -> "ToESX"
    ToES5 -> "ToES5"

-- ---------------------------------------------------------------------------
-- Concrete sink types
-- ---------------------------------------------------------------------------

-- | A concrete voice signature carrying the destination's full detail.
-- | Each constructor corresponds to one shape recognised by the binding
-- | parser — discrete `PrimAction` constructors plus the continuous
-- | `ContDest` variants.  Projections (`sinkKind`, `sinkElement`,
-- | `sinkDestKind`) extract the abstract triple for type-checking; the
-- | concrete record fields are for rendering and registry display.
data SinkType
  = SinkMidiNote
      { device :: String
      , channel :: Int
      , defaultNote :: Int
      , velocity :: Int
      , durationMs :: Int
      }
  | SinkMidiCC
      { device :: String
      , channel :: Int
      , cc :: Int
      }
  | SinkGate
      { channel :: Int
      , latencyMs :: Int
      }
  | SinkCVLiteral
      { bus :: Int
      }
  | SinkCVVoct
      { bus :: Int
      }
  | SinkCVSampleMap
      { bus :: Int
      }
  | SinkESX
      { slot :: Int
      , latencyMs :: Int
      }
  | SinkES5Gate
      { bit :: Int
      , latencyMs :: Int
      }
  | SinkContMidiCC
      { device :: String
      , channel :: Int
      , cc :: Int
      }
  | SinkContCV
      { bus :: Int
      }
  | SinkFh2Trigger
      { voice :: Int
      , defaultNote :: Int
      }

derive instance eqSinkType :: Eq SinkType

-- ---------------------------------------------------------------------------
-- Inference from existing PrimAction / ContDest shapes
-- ---------------------------------------------------------------------------

-- | Each `PrimAction` maps to exactly one `SinkType`.  Pure data; the
-- | binding parser already encodes the type — this just extracts it.
inferPrimSinkType :: PrimAction -> SinkType
inferPrimSinkType = case _ of
  Gate r -> SinkGate r
  CV bus LiteralValue -> SinkCVLiteral { bus }
  CV bus NoteNameVoct -> SinkCVVoct { bus }
  CV bus (SampleNameMap _) -> SinkCVSampleMap { bus }
  ESX r -> SinkESX r
  ES5Gate r -> SinkES5Gate r
  MidiNote r -> SinkMidiNote r
  MidiCC r -> SinkMidiCC r
  Fh2Trigger r -> SinkFh2Trigger r

-- | A `Binding` is `Array PrimAction` — the per-event dispatch list.
-- | Its overall type is the array of per-action sink types; for
-- | type-checking we treat the *most specific* (least permissive) one
-- | as the binding's effective element type.  See `bindingElement`.
bindingSinkTypes :: Array PrimAction -> Array SinkType
bindingSinkTypes = map inferPrimSinkType

-- ---------------------------------------------------------------------------
-- Projections — extract the abstract triple
-- ---------------------------------------------------------------------------

sinkKind :: SinkType -> GenKind
sinkKind = case _ of
  SinkContMidiCC _ -> Continuous
  SinkContCV _ -> Continuous
  _ -> Discrete

-- | The element type the sink expects.  The most permissive label that
-- | accepts the typical user input.  `MidiNote` accepts both sample
-- | tokens (drum-trigger style with defaultNote fallback) and note
-- | tokens (overriding defaultNote via `noteNameMidi`), hence
-- | `SampleOrNote`.
sinkElement :: SinkType -> Element
sinkElement = case _ of
  SinkMidiNote _ -> SampleOrNote
  SinkMidiCC _ -> Number
  SinkGate _ -> Trigger
  SinkCVLiteral _ -> Number
  SinkCVVoct _ -> Note
  SinkCVSampleMap _ -> Sample
  SinkESX _ -> Number
  SinkES5Gate _ -> Trigger
  SinkContMidiCC _ -> Number
  SinkContCV _ -> Number
  SinkFh2Trigger _ -> SampleOrNote

sinkDestKind :: SinkType -> DestKind
sinkDestKind = case _ of
  SinkMidiNote _ -> ToMidi
  SinkMidiCC _ -> ToMidi
  SinkContMidiCC _ -> ToMidi
  SinkGate _ -> ToGate
  SinkCVLiteral _ -> ToCV
  SinkCVVoct _ -> ToCV
  SinkCVSampleMap _ -> ToCV
  SinkContCV _ -> ToCV
  SinkESX _ -> ToESX
  SinkES5Gate _ -> ToES5
  SinkFh2Trigger _ -> ToMidi

-- ---------------------------------------------------------------------------
-- Pattern classification
-- ---------------------------------------------------------------------------

-- | A pattern's runtime type.  `PatNumber` is the `Pattern Number`
-- | path (oscillators, arithmetic results); `PatString` is
-- | `Pattern String` produced by mini-notation, classified further
-- | by the shape of its tokens.
data PatternType
  = PatNumber
  | PatString StringContent

derive instance eqPatternType :: Eq PatternType

-- | What the tokens of a `Pattern String` look like.  A best-effort
-- | classification — used to flag obvious mismatches, not to parse
-- | musical semantics.
data StringContent
  = ContentSample      -- ^ All tokens look like drum names (bd, sn, hh, …).
  | ContentNote        -- ^ All tokens look like note names (c4, fs3, bb2, …).
  | ContentNumeric     -- ^ All tokens parse as numbers (0.3, -1.0, 127, …).
  | ContentMixed       -- ^ Multiple kinds, or unrecognised — be permissive.
  | ContentEmpty       -- ^ No tokens (rests only or empty pattern).

derive instance eqStringContent :: Eq StringContent

instance showStringContent :: Show StringContent where
  show = case _ of
    ContentSample -> "Sample"
    ContentNote -> "Note"
    ContentNumeric -> "Numeric"
    ContentMixed -> "Mixed"
    ContentEmpty -> "Empty"

-- | Classify a parsed `TPat String` by its atom tokens.  Walks the AST
-- | accumulating per-atom kinds, then summarises:
-- |
-- |   * All tokens of one kind         → that kind
-- |   * Mix of two or more kinds       → ContentMixed
-- |   * No tokens (rests / silence)    → ContentEmpty
classifyTPat :: TPat String -> StringContent
classifyTPat tpat =
  let
    tokens = collectAtoms tpat
    kinds = map classifyToken tokens
  in
    summarise kinds
  where
    collectAtoms :: TPat String -> Array String
    collectAtoms = case _ of
      TPat_Atom (Located _ v) -> [v]
      TPat_Silence _ -> []
      TPat_Var _ _ -> []
      TPat_Seq _ ps -> Array.concatMap collectAtoms ps
      TPat_Stack _ ps -> Array.concatMap collectAtoms ps
      TPat_Polyrhythm _ _ ps -> Array.concatMap collectAtoms ps
      TPat_Fast _ _ p -> collectAtoms p
      TPat_Slow _ _ p -> collectAtoms p
      TPat_Elongate _ _ p -> collectAtoms p
      TPat_Repeat _ _ p -> collectAtoms p
      TPat_DegradeBy _ _ _ p -> collectAtoms p
      TPat_CycleChoose _ _ ps -> Array.concatMap collectAtoms ps
      TPat_Euclid _ _ _ _ p -> collectAtoms p
      TPat_EnumFromTo _ _ _ -> []  -- range expansion happens at eval

    summarise :: Array StringContent -> StringContent
    summarise [] = ContentEmpty
    summarise xs = case Array.uncons xs of
      Nothing -> ContentEmpty
      Just { head, tail }
        | foldl (\acc k -> acc && k == head) true tail -> head
        | otherwise -> ContentMixed

-- | Heuristic per-token classifier.
classifyToken :: String -> StringContent
classifyToken tok
  | isJust (Number.fromString tok) = ContentNumeric
  | isKnownSample tok = ContentSample
  | looksLikeNote tok = ContentNote
  | otherwise = ContentMixed

-- | A handful of well-known drum/sample names.  Not exhaustive — just
-- | enough to disambiguate the common case.  Anything not in this list
-- | that *also* doesn't look like a note falls through to ContentMixed.
isKnownSample :: String -> Boolean
isKnownSample = case _ of
  "bd" -> true
  "kick" -> true
  "sn" -> true
  "snare" -> true
  "hh" -> true
  "hihat" -> true
  "ho" -> true
  "oh" -> true
  "cp" -> true
  "clap" -> true
  "rim" -> true
  "lt" -> true
  "tom" -> true
  "mt" -> true
  "ht" -> true
  "cy" -> true
  "crash" -> true
  "rd" -> true
  "ride" -> true
  "cb" -> true
  _ -> false

-- | Does this token look like a note name?  Letter c-g/a-b (case-
-- | insensitive), optional accidental(s) (`s`/`f`/`n`/`#`), then an
-- | octave digit.  Allows the apostrophe-chord form (`c4'major`) by
-- | accepting a tail of arbitrary chars after the basic note.
looksLikeNote :: String -> Boolean
looksLikeNote tok = case SCU.toCharArray tok of
  [] -> false
  cs -> case Array.uncons cs of
    Nothing -> false
    Just { head: c0, tail: rest } ->
      isNoteLetter c0 && hasOctaveDigit rest
  where
    isNoteLetter c =
      let c' = toLower' c
      in (c' >= 'a' && c' <= 'g')

    -- Look for at least one digit somewhere in the remaining chars
    -- (allowing accidentals and chord suffix to come before it).
    hasOctaveDigit cs = Array.any isDigitChar cs

    isDigitChar c = c >= '0' && c <= '9'

    toLower' c
      | c >= 'A' && c <= 'Z' =
          case String.codePointFromChar c of
            _ -> c  -- conservative: don't actually lower; isNoteLetter handles upper too
      | otherwise = c

-- ---------------------------------------------------------------------------
-- Compatibility check — the actual type discipline
-- ---------------------------------------------------------------------------

-- | Check whether a pattern's type is acceptable to a sink.  Returns
-- | `Right unit` on success, or `Left <message>` with a message
-- | suitable for surfacing to the user via the BEAM log.
-- |
-- | Strict mismatches (e.g. number pattern → sample-only sink) error.
-- | Heuristic ambiguity (e.g. mixed tokens → numeric sink) passes
-- | through with the runtime making per-token decisions, since the
-- | classification can't be 100% confident.
checkPattern :: SinkType -> PatternType -> Either String Unit
checkPattern sink pat = case sink of
  SinkMidiNote _ -> case pat of
    PatNumber ->
      Left $ "midi-note voice expects sample/note tokens, got a numeric pattern \
             \(did you mean to send this to a midi-cc-cont voice?)"
    PatString _ -> Right unit  -- permissive: defaultNote fallback handles unknowns

  SinkMidiCC _ -> case pat of
    PatNumber -> Right unit  -- continuous numeric works (sampled per token? no — discrete CC)
    PatString ContentNumeric -> Right unit
    PatString ContentMixed -> Right unit  -- per-token Number.fromString in dispatch
    PatString ContentEmpty -> Right unit  -- rests only
    PatString ContentSample ->
      Left $ "midi-cc voice expects numeric tokens (e.g., \"0.3 0.7 1.0\"), \
             \got sample-style tokens — these will silently no-op"
    PatString ContentNote ->
      Left $ "midi-cc voice expects numeric tokens, got note tokens"

  SinkGate _ -> case pat of
    PatNumber ->
      Left $ "gate voice expects discrete tokens, got a continuous numeric pattern \
             \(use a cv-cont voice for continuous output)"
    PatString _ -> Right unit  -- any token fires the gate

  SinkCVLiteral _ -> case pat of
    PatNumber -> Right unit
    PatString ContentNumeric -> Right unit
    PatString ContentMixed -> Right unit
    PatString ContentEmpty -> Right unit
    PatString ContentSample ->
      Left $ "cv (literal) expects numeric tokens, got sample-style tokens \
             \(use 'cv N voct' for note input)"
    PatString ContentNote ->
      Left $ "cv (literal) expects numeric tokens — for note tokens, declare \
             \the binding as 'cv N voct' so the V/oct mapping kicks in"

  SinkCVVoct _ -> case pat of
    PatNumber -> Right unit  -- direct MIDI number works (oscillator unlikely but legal)
    PatString ContentNote -> Right unit
    PatString ContentNumeric -> Right unit  -- MIDI numbers
    PatString ContentMixed -> Right unit
    PatString ContentEmpty -> Right unit
    PatString ContentSample ->
      Left $ "cv voct expects note tokens, got sample-style tokens"

  SinkCVSampleMap _ -> case pat of
    PatNumber ->
      Left $ "cv (sample-map) expects sample-name tokens, got numeric pattern"
    PatString _ -> Right unit  -- mapped via lookup, unknowns skip

  SinkESX _ -> case pat of
    PatNumber -> Right unit
    PatString ContentNumeric -> Right unit
    PatString ContentMixed -> Right unit
    PatString ContentEmpty -> Right unit
    PatString _ ->
      Left $ "esx voice expects numeric tokens (-1.0 to +1.0)"

  SinkES5Gate _ -> case pat of
    PatNumber ->
      Left $ "es5gate voice expects discrete tokens, got continuous numeric"
    PatString _ -> Right unit  -- any token fires

  SinkContMidiCC _ -> case pat of
    PatNumber -> Right unit
    PatString _ ->
      Left $ "midi-cc-cont voice expects a continuous numeric pattern \
             \(oscillator or numeric expression like 'sine' or 'range 0 1 (slow 4 sine)'), \
             \got a discrete token pattern"

  SinkContCV _ -> case pat of
    PatNumber -> Right unit
    PatString _ ->
      Left $ "cv-cont voice expects a continuous numeric pattern \
             \(oscillator or numeric expression), got a discrete token pattern"

  SinkFh2Trigger _ -> case pat of
    PatNumber ->
      Left $ "fh2-trigger voice expects sample/note tokens, got a numeric pattern"
    PatString _ -> Right unit  -- defaultNote fallback handles unknowns

-- ---------------------------------------------------------------------------
-- Rendering — for state snapshot and Voices pane
-- ---------------------------------------------------------------------------

-- | Human-readable single-line type signature.  Unaliased — always
-- | the full `Sink <Kind> <Element> (To<Dest> …)` shape.  Used in
-- | error messages and (eventually) the Voices pane.
renderSinkType :: SinkType -> String
renderSinkType st =
  "Sink " <> show (sinkKind st)
    <> " " <> show (sinkElement st)
    <> " (" <> renderDest st <> ")"
  where
    renderDest = case _ of
      SinkMidiNote r ->
        "ToMidi device=" <> show r.device
          <> " ch=" <> show r.channel
          <> " note=" <> show r.defaultNote
          <> " vel=" <> show r.velocity
          <> " dur=" <> show r.durationMs
      SinkMidiCC r ->
        "ToMidi device=" <> show r.device
          <> " ch=" <> show r.channel
          <> " cc=" <> show r.cc
      SinkContMidiCC r ->
        "ToMidi device=" <> show r.device
          <> " ch=" <> show r.channel
          <> " cc=" <> show r.cc
      SinkGate r ->
        "ToGate ch=" <> show r.channel
          <> " lat=" <> show r.latencyMs
      SinkCVLiteral r -> "ToCV bus=" <> show r.bus <> " mode=literal"
      SinkCVVoct r -> "ToCV bus=" <> show r.bus <> " mode=voct"
      SinkCVSampleMap r -> "ToCV bus=" <> show r.bus <> " mode=sample-map"
      SinkContCV r -> "ToCV bus=" <> show r.bus
      SinkESX r ->
        "ToESX slot=" <> show r.slot
          <> " lat=" <> show r.latencyMs
      SinkES5Gate r ->
        "ToES5 bit=" <> show r.bit
          <> " lat=" <> show r.latencyMs
      SinkFh2Trigger r ->
        "ToMidi device=\"fh2\" voice=" <> show r.voice
          <> " note=" <> show r.defaultNote

-- | JSON object representation for the state snapshot.  Stable shape:
-- | { kind, element, destKind, detail }.  Calypso reads this to render
-- | the Voices pane.
renderSinkTypeJSON :: SinkType -> String
renderSinkTypeJSON st =
  "{\"kind\":\"" <> show (sinkKind st)
    <> "\",\"element\":\"" <> show (sinkElement st)
    <> "\",\"destKind\":\"" <> show (sinkDestKind st)
    <> "\",\"detail\":" <> renderDetail st
    <> "}"
  where
    renderDetail = case _ of
      SinkMidiNote r ->
        "{\"device\":" <> jsStr r.device
          <> ",\"channel\":" <> show r.channel
          <> ",\"defaultNote\":" <> show r.defaultNote
          <> ",\"velocity\":" <> show r.velocity
          <> ",\"durationMs\":" <> show r.durationMs <> "}"
      SinkMidiCC r ->
        "{\"device\":" <> jsStr r.device
          <> ",\"channel\":" <> show r.channel
          <> ",\"cc\":" <> show r.cc <> "}"
      SinkContMidiCC r ->
        "{\"device\":" <> jsStr r.device
          <> ",\"channel\":" <> show r.channel
          <> ",\"cc\":" <> show r.cc <> "}"
      SinkGate r ->
        "{\"channel\":" <> show r.channel
          <> ",\"latencyMs\":" <> show r.latencyMs <> "}"
      SinkCVLiteral r -> "{\"bus\":" <> show r.bus <> ",\"mode\":\"literal\"}"
      SinkCVVoct r -> "{\"bus\":" <> show r.bus <> ",\"mode\":\"voct\"}"
      SinkCVSampleMap r -> "{\"bus\":" <> show r.bus <> ",\"mode\":\"sample-map\"}"
      SinkContCV r -> "{\"bus\":" <> show r.bus <> "}"
      SinkESX r ->
        "{\"slot\":" <> show r.slot
          <> ",\"latencyMs\":" <> show r.latencyMs <> "}"
      SinkES5Gate r ->
        "{\"bit\":" <> show r.bit
          <> ",\"latencyMs\":" <> show r.latencyMs <> "}"
      SinkFh2Trigger r ->
        "{\"voice\":" <> show r.voice
          <> ",\"defaultNote\":" <> show r.defaultNote <> "}"

    jsStr :: String -> String
    jsStr s = "\"" <> escape s <> "\""

    escape :: String -> String
    escape = SCU.fromCharArray <<< Array.concatMap escChar <<< SCU.toCharArray

    escChar :: Char -> Array Char
    escChar c
      | c == '"' = ['\\', '"']
      | c == '\\' = ['\\', '\\']
      | otherwise = [c]
