-- | **Vetula's cards, played by the rig.** A card is one line on the stage
-- | (`vetula/v3`, `Reef.Vetula.Lepidoptera.parseCard`): a channel, its chords,
-- | a mini-notation sequence over them and a stack of layers. This module
-- | builds the card's `Pattern (Array Int)` with Tidal (Littorina) and reads
-- | off the chords struck in one slot, for `vetula_cards` to schedule.
-- |
-- | Moved from Triggerfish's Vetula page (`Vetula.App`, `Vetula.Pattern`,
-- | `Vetula.Realise`) on 2026-10-02, unchanged in meaning, so no page evaluates
-- | Tidal (docs/kb/plans/gpl-boundary-review.md, step 3). The page played cards
-- | only through the browser's own MIDI; the rig now plays them.
-- |
-- | The grid, as on the page: a card with a valid sequence plays on the BAR
-- | (one pattern cycle per bar, 16 pulses); a plain card on the BEAT (one chord
-- | per beat, 4 pulses). Slot `c` is the c-th bar or beat since Link beat 0.
module Tidal.Vetula.Card
  ( CardHit
  , cardHits
  , cardOnBar
  , cardStrumMs
  , cardSounds
  , cardHarmony
  ) where

import Prelude

import Data.Array as Array
import Data.Array (foldl, index, length, mapMaybe, sort)
import Data.Either (Either(..))
import Data.Int (fromString)
import Data.Int as Int
import Data.Maybe (Maybe(..), fromMaybe, isJust)
import Haskell.Double (sin)
import Data.String (stripPrefix, trim)
import Data.String as String
import Harmonia.Voicing (Voicing(..), Selector(..), voicingMidi, takeVoicing, openTriad, rootless, drop2, drop2and4, quartal, cluster)
import Haskell.Rational as Rat
import Reef.PatternArg (PatternArg, argSrc)
import Reef.Vetula.Harmony (Shape(..), seqHarmony) as VH
import Reef.Vetula.Lepidoptera (VoiceSpec)
import Reef.Vetula.PerformTypes (Layer, PerfFx(..), PerfSel(..), PerfTerm(..), VoiceShape(..), When(..), arpOrder, parseVoiceShape)
import Tidal.Pattern.Core (cat, every, fast, slow, whenCycle)
import Tidal.Pattern.Mini (parseMiniPattern)
import Tidal.Pattern.Types (Arc(..), Event(..), Pattern, State(..), emptyContext, eventPart, eventValue, eventWhole, mkArc, mkState, pattern, query)

-- | One chord struck in a slot: where it starts and how long it lasts, as
-- | fractions of the slot, and its notes.
type CardHit = { at :: Number, len :: Number, notes :: Array Int }

-- | Whether the card sounds from the rig at all: not muted, and bound for MIDI
-- | or for the rig (`→ rig`, "hand this card to the rig", plays as MIDI on its
-- | channel until the CV/ES-9 destinations exist); `→ odo` conducts Odonus and
-- | makes no notes.
cardSounds :: VoiceSpec -> Boolean
cardSounds spec = not spec.muted && spec.term /= TOdo && Array.length spec.chords > 0

-- | **What the card conducts**, when the router feeds `odonus.out <- vetula
-- | N` from it (Reef.Route): its chords as a Tidal note pattern, which the rig
-- | samples into Odonus's chord each step as it does `harmony "…"`. Which
-- | chord sounds, not how: the sequence and the layers that always move it in
-- | time or pitch (`Reef.Vetula.Harmony.seqHarmony`, as the page conducted).
-- | Odonus's cycle is a bar; a plain card's is a beat, so its pattern runs
-- | four times as fast. Nothing for a muted card or one with no chords.
cardHarmony :: VoiceSpec -> Maybe String
cardHarmony spec
  | spec.muted = Nothing
  | otherwise = do
      p <- VH.seqHarmony spec.chords (if cardOnBar spec then spec.seqText else "") (mapMaybe shape spec.stack)
      pure (if cardOnBar spec then p else "[" <> p <> "]*4")
  where
  shape l = case l.when, l.fx of
    Always, Slow n -> Just (VH.Slow n)
    Always, Fast n -> Just (VH.Fast n)
    Always, Transpose arg -> VH.Transpose <$> fromString (trim (argSrc arg))
    Always, Octave arg -> (\n -> VH.Transpose (12 * n)) <$> fromString (trim (argSrc arg))
    _, _ -> Nothing

-- | Whether the card plays on the bar grid (a sequence that parses).
cardOnBar :: VoiceSpec -> Boolean
cardOnBar spec = isJust (seqPattern spec.chords spec.seqText)

-- | The strum stagger between a chord's notes, in ms (0: struck together).
cardStrumMs :: VoiceSpec -> Int
cardStrumMs spec = foldl pick 0 (map _.fx spec.stack)
  where
  pick acc = case _ of
    Strum ms -> ms
    _ -> acc

-- | The chords the card strikes in slot `c`: only those whose onset falls in
-- | the slot, so a chord held across slots by `slow` is struck once.
cardHits :: VoiceSpec -> Int -> Array CardHit
cardHits spec c =
  mapMaybe hit (query (cardPattern spec) (mkState (mkArc (Rat.fromInt c) (Rat.fromInt (c + 1)))))
  where
  hit ev = do
    Arc w <- onsetWhole ev
    pure { at: Rat.toNumber (w.start - Rat.fromInt c), len: Rat.toNumber (w.stop - w.start), notes: eventValue ev }

cardPattern :: VoiceSpec -> Pattern (Array Int)
cardPattern spec = foldl (\p lyr -> applyLayer lyr p) base spec.stack
  where
  base = fromMaybe (fromChords spec.chords) (seqPattern spec.chords spec.seqText)

fromChords :: Array (Array Int) -> Pattern (Array Int)
fromChords = cat <<< map pure

-- | The sequence over the card's chord indices (cycle = one bar); an index
-- | past the end is a rest. Nothing when empty or unparseable.
seqPattern :: Array (Array Int) -> String -> Maybe (Pattern (Array Int))
seqPattern chords txt
  | trim txt == "" = Nothing
  | otherwise = case parseMiniPattern txt of
      Left _ -> Nothing
      Right idxPat -> Just (map (\s -> fromMaybe [] (fromString (trim s) >>= index chords)) idxPat)

onsetWhole :: forall a. Event a -> Maybe Arc
onsetWhole ev = do
  wa@(Arc w) <- eventWhole ev
  let Arc p = eventPart ev
  if w.start == p.start then Just wa else Nothing

-- | A layer, gated by its `when` clause.
applyLayer :: Layer -> Pattern (Array Int) -> Pattern (Array Int)
applyLayer { fx, when: w } = case w of
  Always -> applyFx fx
  Every n -> every n (applyFx fx)
  Prob p -> whenCycle (\c -> cycleRand c < p) (applyFx fx)
  AfterBar n -> whenCycle (\c -> c >= n) (applyFx fx)
  Whenmod n r -> whenCycle (\c -> mod c n >= r) (applyFx fx)

applyFx :: PerfFx -> Pattern (Array Int) -> Pattern (Array Int)
applyFx = case _ of
  Transpose arg -> withSampledArg (\s -> map (_ + tokInt 0 s)) (argEval arg)
  Octave arg -> withSampledArg (\s -> map (_ + 12 * tokInt 0 s)) (argEval arg)
  Slow n -> slow (Rat.fromInt (max 1 n))
  Fast n -> fast (Rat.fromInt (max 1 n))
  Voice arg -> withSampledArg (\s -> revoice (voiceStrategy (shapeOf s))) (argEval arg)
  Select (Low arg) -> withSampledArg (\s -> revoice (takeVoicing (TakeLow (selInt s)))) (argEval arg)
  Select (High arg) -> withSampledArg (\s -> revoice (takeVoicing (TakeHigh (selInt s)))) (argEval arg)
  Arpg dir rate -> arpRate rate <<< map (arpOrder dir)
  ArpP src -> arpIndexed arpSelect (idxPattern src)
  Strum _ -> identity

idxPattern :: String -> Pattern String
idxPattern src = case parseMiniPattern src of
  Right p -> p
  Left _ -> pure "0"

-- | A note picked from a chord sorted low to high (0 = lowest), wrapping an
-- | octave past either end; a non-number is a rest.
arpSelect :: Array Int -> String -> Maybe Int
arpSelect ns tok = case fromString (trim tok) of
  Nothing -> Nothing
  Just idx ->
    let sorted = sort ns
        m = length sorted
    in if m == 0 then Nothing
       else
         let i = ((idx `mod` m) + m) `mod` m
             oct = (idx - i) / m
         in (\v -> v + 12 * oct) <$> index sorted i

argEval :: PatternArg -> Pattern String
argEval arg = case parseMiniPattern (argSrc arg) of
  Right p -> p
  Left _ -> pure (argSrc arg)

shapeOf :: String -> VoiceShape
shapeOf s = fromMaybe Open (parseVoiceShape (trim s))

selInt :: String -> Int
selInt s = clamp 1 6 (tokInt 1 s)

tokInt :: Int -> String -> Int
tokInt def s = fromMaybe def (fromString (fromMaybe s (stripPrefix (String.Pattern "+") s)))

revoice :: (Voicing -> Voicing) -> Array Int -> Array Int
revoice f = voicingMidi <<< f <<< Voicing <<< sort

voiceStrategy :: VoiceShape -> (Voicing -> Voicing)
voiceStrategy = case _ of
  Open -> openTriad
  Rootless -> rootless
  Drop2 -> drop2
  Drop24 -> drop2and4
  Quartal -> quartal
  Cluster -> cluster

-- | Explode each chord across its own whole, `rate` notes per cycle of it,
-- | cycling the chord; only onsets in the query are emitted.
arpRate :: forall a. Int -> Pattern (Array a) -> Pattern (Array a)
arpRate rate pat = pattern \(State st) ->
  let Arc q = st.arc
  in Array.concatMap (burst q) (query pat (State st))
  where
  burst q = case _ of
    Analog e -> [ Analog e ]
    Digital e ->
      let Arc w = e.whole
          notes = e.value
          m = Array.length notes
          d = w.stop - w.start
          n = max 1 (Int.round (Rat.toNumber d * Int.toNumber rate))
          sd = d / Rat.fromInt n
      in if m == 0 then []
         else Array.mapMaybe (step q w.start notes m sd) (Array.range 0 (n - 1))
  step q ws notes m sd j =
    let onset = ws + Rat.fromInt j * sd
        stop = onset + sd
    in if onset >= q.start && onset < q.stop
       then map
              (\note -> Digital
                 { context: emptyContext
                 , whole: Arc { start: onset, stop }
                 , part: Arc { start: onset, stop: min stop q.stop }
                 , value: [ note ]
                 })
              (Array.index notes (mod j m))
       else Nothing

-- | Arpeggiate by an index figure, queried within each chord's own slot.
arpIndexed :: forall a b. (Array a -> b -> Maybe a) -> Pattern b -> Pattern (Array a) -> Pattern (Array a)
arpIndexed sel ip pat = pattern \(State st) ->
  Array.concatMap
    (case _ of
        Analog e -> [ Analog e ]
        Digital e -> Array.mapMaybe (pick e.value) (query ip (State (st { arc = e.part }))))
    (query pat (State st))
  where
  pick ns = case _ of
    Analog _ -> Nothing
    Digital je -> map (\v -> Digital (je { value = [ v ] })) (sel ns je.value)

-- | A verb's argument sampled per event, at the event's part.
withSampledArg :: forall a. (String -> a -> a) -> Pattern String -> Pattern a -> Pattern a
withSampledArg f argp pat = pattern \(State st) ->
  map (go st) (query pat (State st))
  where
  go st = case _ of
    Analog e -> Analog e
    Digital e ->
      let s = case Array.head (query argp (State (st { arc = e.part }))) of
                Just ae -> eventValue ae
                Nothing -> ""
      in Digital (e { value = f s e.value })

-- | A deterministic value in [0,1) per cycle (hashed sine), for `prob` gates.
cycleRand :: Int -> Number
cycleRand c =
  let v = sin (Int.toNumber c * 12.9898 + 78.233) * 43758.5453
  in v - Int.toNumber (Int.floor v)
