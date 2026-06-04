-- | `Sound` — the one typed event payload the eDSL converges on.
-- |
-- | This is the realignment described in `docs/typed-edsl-plan.md`.
-- | purerl-tidal grew two incoherent notions of "what a pattern event
-- | is": Family A parsers (`mini`/`drum`/`degree`/`pitch`, each a typed
-- | value pattern) consumed directly by parts, and Family B control-
-- | lifts (`Tidal.Controls` — `s`/`n`/`gain` over a stringly `ValueMap`)
-- | that nothing on the part path uses.  Tidal's own two-layer model
-- | (parse → controls → merge with `#`) is the right shape, but Tidal
-- | pays for it with a `Map String Value` core — stringly control keys
-- | we explicitly reject for the composition/generative ambitions.
-- |
-- | `Sound` keeps Tidal's composability with a **typed** payload: every
-- | control is an optional, typed field; the vocabulary is bounded and
-- | known; adding a control is adding a field (compile-checked); there
-- | are no string keys and no escape hatch.  Every verb yields the same
-- | type, `SoundPattern`, and `#` is a typed right-biased record merge —
-- | so `drum "bd sn" # gain "1 0.6"` is just two `SoundPattern`s merged,
-- | and **accents are simply the `gain` field**, no special mechanism.
-- |
-- | Phase 1 (this module): the types + verbs + merge, compiling in
-- | isolation.  Nothing here is wired into `Calypso.Prelude` or the
-- | voice yet — that is Phases 2–3 of the plan.  Until then the names
-- | here (`s`, `gain`, `degree`, …) deliberately shadow the Family-A/B
-- | originals; the wiring step replaces those, it does not run both.
-- |
-- | Leaf verbs take a mini-notation `String` and parse it (matching
-- | today's `drum "…"` / `degree "…"` surface, and the plan's literal
-- | examples).  Whether to also offer `Pattern`-taking variants or an
-- | `IsString (Pattern a)` instance is an ergonomic call orthogonal to
-- | the type model; deferred.
module Tidal.Sound
  ( Token(..)
  , Pitch(..)
  , Sound
  , SoundPattern
  , emptySound
  -- Source verbs (set `source`)
  , s
  , sound
  , drum
  -- Pitch verbs (set `pitch`)
  , degree
  , note
  , pitch
  -- Sample-index verb (set `index`)
  , n
  -- Numeric control verbs
  , gain
  , pan
  , speed
  , begin
  , end
  , cutoff
  , shape
  -- Typed merge
  , mergeSound
  , merge
  , (#)
  -- Projection / bridge helpers (the boundary to the rest of the engine)
  , classifyToken
  , liftStringToSound
  , drumPatternToSound
  , soundParams
  , controlVerb
  , pitchedNoteToSound
  , toSound
  ) where

import Prelude

import Control.Alt ((<|>))
import Data.Array as Array
import Data.Foldable (foldl)
import Data.Int as Int
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), maybe)
import Data.Number as Number
import Data.String.CodeUnits as SCU
import Data.Tuple (Tuple(..))
import Tidal.Pitch (PitchedNote12(..)) as P
import Tidal.Dispatch.Helpers (noteNameMidi)
import Tidal.MiniNotation (miniTyped)
import Tidal.Notation (toPattern)
import Tidal.Pattern.Types
  ( Arc(..)
  , Event
  , Pattern
  , eventPart
  , eventValue
  , mapEventValue
  , pattern
  , query
  )

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------

-- | A parsed mini-notation token destined for the `source` field —
-- | a kit-hit name (`"bd"`), a sample-bank name (`"arpy"`), whatever
-- | the bound destination decides a token means.  A newtype over
-- | String so a "source token" can't be confused with "a number".
newtype Token = Token String

derive instance eqToken :: Eq Token
derive instance ordToken :: Ord Token

instance showToken :: Show Token where
  show (Token t) = "Token " <> show t

-- | Melodic pitch.  Three intents, mirroring the substrate's existing
-- | `PitchedNote12` carrier but as a field of `Sound`:
-- |
-- |   * `Degree d`   — the `d`-th note of the *active* scale.  Stays
-- |     late-bound; resolved at emit so a live scale change re-renders
-- |     every running degree pattern (the purerl-only feature we keep).
-- |   * `Note s`     — relative semitones (Tidal `note`), fractional ok.
-- |   * `Chromatic m`— an absolute MIDI note number.
data Pitch
  = Degree Int
  | Note Number
  | Chromatic Int

derive instance eqPitch :: Eq Pitch
derive instance ordPitch :: Ord Pitch

instance showPitch :: Show Pitch where
  show = case _ of
    Degree d    -> "Degree " <> show d
    Note x      -> "Note " <> show x
    Chromatic m -> "Chromatic " <> show m

-- | The typed event payload.  Every control is an optional, typed
-- | field; the vocabulary is bounded and known.  `source`/`index`/
-- | `gain`/`speed`/`begin`/`end` together form the generic sample-
-- | trigger vocabulary shared by SuperDirt / Squarp Rample / Digitakt
-- | (the binding does the target-specific addressing); `pitch`/`gain`
-- | drive synth + drum voices.  No string keys, no escape hatch —
-- | adding a control means adding a field here.
type Sound =
  { source :: Maybe Token     -- token meaning is decided by the binding
  , index  :: Maybe Int       -- sample slot within a bank (Dirt `n`, Rample slot)
  , pitch  :: Maybe Pitch     -- melodic pitch; `Degree` stays late-bound
  , gain   :: Maybe Number    -- 0..1 neutral loudness → vel / amp / accent
  , pan    :: Maybe Number
  , speed  :: Maybe Number    -- sample playback rate
  , begin  :: Maybe Number    -- sample start 0..1
  , end    :: Maybe Number    -- sample end 0..1
  , cutoff :: Maybe Number
  , shape  :: Maybe Number
  }

-- | A pattern of typed `Sound` payloads — the single carrier the whole
-- | verb vocabulary converges on.
type SoundPattern = Pattern Sound

-- | The empty payload: every field unset.  Every verb is "`emptySound`
-- | with one field set"; `#` merges two payloads field-by-field.
emptySound :: Sound
emptySound =
  { source: Nothing
  , index: Nothing
  , pitch: Nothing
  , gain: Nothing
  , pan: Nothing
  , speed: Nothing
  , begin: Nothing
  , end: Nothing
  , cutoff: Nothing
  , shape: Nothing
  }

-- ---------------------------------------------------------------------------
-- Mini-notation parsing (shared by every leaf verb)
-- ---------------------------------------------------------------------------

-- | Parse a mini-notation string to its per-step token pattern.  Reuses
-- | the engine's existing parser (`miniTyped` → `toPattern`), so the
-- | full grammar (subdivisions, `*`, euclid `(3,8)`, `<…>`, rests `~`)
-- | applies uniformly to sources, pitches, and numeric controls.  A
-- | rest token produces no event for that step, so an unset control on
-- | one step (`gain "1 ~ 0.6"`) just leaves that step's payload alone.
parseTokens :: String -> Pattern String
parseTokens = toPattern <<< miniTyped

-- | Lift a per-token `Sound`-builder over a parsed mini-notation string.
fromTokens :: (String -> Sound) -> String -> SoundPattern
fromTokens f = map f <<< parseTokens

-- ---------------------------------------------------------------------------
-- Source verbs — set `source`
-- ---------------------------------------------------------------------------

-- | Set the `source` token.  The *binding* decides what a token means:
-- | `on vDrums kit (sound "bd sn")` resolves to kit notes; a sampler
-- | binding resolves to a slot; a Dirt binding to a sample name.  `s`,
-- | `sound`, and `drum` are the same operation — three spellings for
-- | author muscle-memory (Tidal's `s`/`sound`, our `drum`).
sound :: String -> SoundPattern
sound = fromTokens \tok -> emptySound { source = Just (Token tok) }

-- | Alias for `sound` (Tidal's short spelling).
s :: String -> SoundPattern
s = sound

-- | Alias for `sound`, kept for the drum-kit reading
-- | `on vDrums kit (drum "bd ~ sn ~")`.  Same type, same payload.
drum :: String -> SoundPattern
drum = sound

-- ---------------------------------------------------------------------------
-- Pitch verbs — set `pitch`
-- ---------------------------------------------------------------------------

-- | Scale degrees → `Degree`.  Stays late-bound; the voice resolves
-- | each degree against the active scale at emit.  Non-integer tokens
-- | leave the step's pitch unset.
degree :: String -> SoundPattern
degree = fromTokens \tok -> emptySound { pitch = Degree <$> Int.fromString tok }

-- | Relative semitones (Tidal `note`) → `Note`.  Decimal tokens are
-- | allowed (`note "0 0.5 7"`).  Note-*names* go through `pitch`.
note :: String -> SoundPattern
note = fromTokens \tok -> emptySound { pitch = Note <$> Number.fromString tok }

-- | Note-names (`c4`, `fs3`) and MIDI integers → `Chromatic`.  A
-- | trailing apostrophe chord suffix (`c4'maj7`) is stripped to its
-- | bare note for now (chord expansion is later work).  Anything that
-- | resolves to neither leaves the step's pitch unset.
pitch :: String -> SoundPattern
pitch = fromTokens \tok -> emptySound { pitch = chromaticTok tok }

chromaticTok :: String -> Maybe Pitch
chromaticTok tok =
  case Map.lookup (stripApostropheChord tok) noteNameMidi of
    Just m  -> Just (Chromatic m)
    Nothing -> case Number.fromString tok of
      Just num -> Just (Chromatic (Int.floor num))
      Nothing  -> Nothing

stripApostropheChord :: String -> String
stripApostropheChord tok =
  SCU.fromCharArray (Array.takeWhile (\c -> c /= '\'') (SCU.toCharArray tok))

-- ---------------------------------------------------------------------------
-- Sample-index verb — set `index`
-- ---------------------------------------------------------------------------

-- | Sample slot within a bank (SuperDirt `n`, Rample slot, Digitakt
-- | sample).  Tidal overloads `n` as both sample-index and synth-pitch;
-- | here `n` is unambiguously the index and `note`/`degree`/`pitch`
-- | carry melody.  Non-integer tokens leave the step's index unset.
n :: String -> SoundPattern
n = fromTokens \tok -> emptySound { index = Int.fromString tok }

-- ---------------------------------------------------------------------------
-- Numeric control verbs
-- ---------------------------------------------------------------------------

-- | Build a numeric-control verb: parse mini-notation, read each token
-- | as a `Number`, and set the chosen field.  A token that isn't a
-- | number leaves the step's payload empty.
numControl :: (Number -> Sound) -> String -> SoundPattern
numControl set = fromTokens \tok -> maybe emptySound set (Number.fromString tok)

-- | 0..1 neutral loudness → MIDI velocity / Dirt amp / modular accent.
-- | This is the field accents live in.
gain :: String -> SoundPattern
gain = numControl \v -> emptySound { gain = Just v }

pan :: String -> SoundPattern
pan = numControl \v -> emptySound { pan = Just v }

speed :: String -> SoundPattern
speed = numControl \v -> emptySound { speed = Just v }

begin :: String -> SoundPattern
begin = numControl \v -> emptySound { begin = Just v }

end :: String -> SoundPattern
end = numControl \v -> emptySound { end = Just v }

cutoff :: String -> SoundPattern
cutoff = numControl \v -> emptySound { cutoff = Just v }

shape :: String -> SoundPattern
shape = numControl \v -> emptySound { shape = Just v }

-- ---------------------------------------------------------------------------
-- The typed merge — `#`
-- ---------------------------------------------------------------------------

-- | Right-biased field merge of two payloads: structure carries, and a
-- | field set on the right wins over the same field on the left.  No
-- | string keys — every field is named and typed.  (`<|>` on `Maybe`
-- | takes the first `Just`, so `r.field <|> l.field` is right-biased.)
mergeSound :: Sound -> Sound -> Sound
mergeSound l r =
  { source: r.source <|> l.source
  , index:  r.index  <|> l.index
  , pitch:  r.pitch  <|> l.pitch
  , gain:   r.gain   <|> l.gain
  , pan:    r.pan    <|> l.pan
  , speed:  r.speed  <|> l.speed
  , begin:  r.begin  <|> l.begin
  , end:    r.end    <|> l.end
  , cutoff: r.cutoff <|> l.cutoff
  , shape:  r.shape  <|> l.shape
  }

-- | Combine two `SoundPattern`s: structure from the left, each left
-- | event's payload merged (right-biased) with every right event that
-- | overlaps it.  This is Tidal's `#` (structure-from-left) — but the
-- | per-event combine is the typed `mergeSound`, not `Map.union`.
-- |
-- | `drum "bd sn" # gain "1 0.6"` keeps the two-step structure of the
-- | drums and stamps each step's gain onto its payload.
merge :: SoundPattern -> SoundPattern -> SoundPattern
merge left right = pattern \st ->
  let
    lefts  = query left st
    rights = query right st
  in
    lefts >>= \l ->
      let
        matching = Array.filter (overlaps l) rights
        merged   = foldl (\acc r -> mergeSound acc (eventValue r)) (eventValue l) matching
      in
        [ mapEventValue (const merged) l ]
  where
  overlaps :: Event Sound -> Event Sound -> Boolean
  overlaps a b = arcOverlaps (eventPart a) (eventPart b)

  arcOverlaps :: Arc -> Arc -> Boolean
  arcOverlaps (Arc a) (Arc b) = a.start < b.stop && b.start < a.stop

infixl 4 merge as #

-- ---------------------------------------------------------------------------
-- Bridge helpers — the boundary between `Sound` and the rest of the engine
-- ---------------------------------------------------------------------------

-- | Classify a bare mini-notation token into a `Sound`.  This is the
-- | one-arg analogue of the old `Tidal.Pitch.Parse.pitchTok`: a token
-- | that resolves to a note-name or a number becomes a `Chromatic`
-- | pitch; anything else becomes a `source` token (drum hit / sample
-- | name).  Used by the raw-string boundaries (`liftStringToSound`,
-- | the live-text `installFromSpec` path) where the parser only knows
-- | the token is a String and the destination decides its meaning.
classifyToken :: String -> Sound
classifyToken tok = case chromaticTok tok of
  Just p  -> emptySound { pitch = Just p }
  Nothing -> emptySound { source = Just (Token tok) }

-- | Lift a `Pattern String` (bare mini-notation) into a `Pattern Sound`
-- | by classifying each token.  Replaces the old
-- | `Tidal.Voice.liftStringToPitch` (which produced `Pattern PitchedNote12`)
-- | at the Erlang string-boundary verbs (`fh2-trigger`, `kit`).
liftStringToSound :: Pattern String -> Pattern Sound
liftStringToSound = map classifyToken

-- | Lift a drum `Pattern String` (every token is a hit name) into a
-- | `Pattern Sound` with each token in `source`.  Replaces the old
-- | `Tidal.Drum.drumPatternToPitch` (String → PitchedNote12 via Sample)
-- | at the drum-kit dispatch boundary.
drumPatternToSound :: Pattern String -> Pattern Sound
drumPatternToSound = map \tok -> emptySound { source = Just (Token tok) }

-- | Project a `Sound`'s typed control fields to the string-keyed param
-- | map the Erlang dispatcher consumes.  This is the ONLY place the
-- | stringly control-key namespace survives — confined to the wire to
-- | Erlang (`DiscreteEvent.params`), not the authored eDSL.  `gain` is
-- | the key the dispatcher maps to MIDI velocity / Dirt amp / modular
-- | accent (`Dispatcher.velFromParams`); the rest are forward-compat
-- | for the sampler / SuperDirt bindings and are harmless where unread.
-- | `index` is emitted as `n` (Dirt's sample-index spelling).
soundParams :: Sound -> Map String String
soundParams snd = Map.fromFoldable $ Array.catMaybes
  [ numEntry "gain" snd.gain
  , numEntry "pan" snd.pan
  , numEntry "speed" snd.speed
  , numEntry "begin" snd.begin
  , numEntry "end" snd.end
  , numEntry "cutoff" snd.cutoff
  , numEntry "shape" snd.shape
  , map (\i -> Tuple "n" (show i)) snd.index
  ]
  where
  numEntry :: String -> Maybe Number -> Maybe (Tuple String String)
  numEntry key = map (\v -> Tuple key (show v))

-- | Resolve a control NAME to its verb, for the live-text
-- | `installFromSpec` path (`# gain "1 0.6"`).  Bounded and known — an
-- | unrecognised name yields `Nothing` (the caller drops it; the old
-- | open `# <binding-name>` fanout is intentionally not reinstated
-- | here — see docs/typed-edsl-plan.md).  `vel` is deliberately absent:
-- | the typed surface speaks `gain` (0..1); absolute `vel` stays a
-- | raw-dispatcher concern.
controlVerb :: String -> Maybe (String -> SoundPattern)
controlVerb = case _ of
  "gain"   -> Just gain
  "pan"    -> Just pan
  "speed"  -> Just speed
  "begin"  -> Just begin
  "end"    -> Just end
  "cutoff" -> Just cutoff
  "shape"  -> Just shape
  "n"      -> Just n
  "degree" -> Just degree
  "note"   -> Just note
  _        -> Nothing

-- | Bridge the existing pitch carrier `PitchedNote12` into a `Sound`.
-- | `Sample` (a drum hit / sample-name token) becomes the `source`
-- | field; `Chromatic`/`Degree` become `pitch`.  This is the lift the
-- | `on` instance applies so pitched authoring (`inKey`/`degree`/…,
-- | which stay `PitchedNote12`-typed and untouched) flows into the
-- | unified `Sound` carrier.
pitchedNoteToSound :: P.PitchedNote12 -> Sound
pitchedNoteToSound = case _ of
  P.Sample t    -> emptySound { source = Just (Token t) }
  P.Chromatic m -> emptySound { pitch = Just (Chromatic m) }
  P.Degree d    -> emptySound { pitch = Just (Degree d) }

-- | Lift a whole `Pattern PitchedNote12` into a `Pattern Sound`.
toSound :: Pattern P.PitchedNote12 -> Pattern Sound
toSound = map pitchedNoteToSound
