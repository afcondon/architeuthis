-- | `Tidal.Vetula.Bridge` — the palette→brush handoff, and the per-pulse query the
-- | reef-family Vetula voice drives.
-- |
-- | The browser Vetula (the palette) authors a chord progression by direct
-- | manipulation and pushes its HAND-PICKED voicings — a JSON `Array (Array Int)`,
-- | each inner array the ascending MIDI of one voiced chord — to the rig over the
-- | WebSocket. This module turns that push into a real Tidal `Pattern` (the brush)
-- | and lets a bespoke reef voice PLAY it by querying one pulse's arc at a time.
-- |
-- | Two calls, both flat for Erlang:
-- |
-- |   * `buildVoicingsPattern renderer json` — decode + wrap as `Voicing`s + pick the
-- |     renderer → a `Pattern PitchedNote12`. Called ONCE on push; the reef voice
-- |     stores the returned pattern in its state.
-- |   * `queryNotes pattern stepNum quantum` — query the pattern over the exact cycle
-- |     arc of pulse `stepNum` and return each note-onset in that pulse as a flat
-- |     record the reef voice converts to a scheduled MIDI note. Called every pulse.
-- |
-- | This is Option B: the reef voice holds and queries the Pattern itself (staying on
-- | Odonus's Link 1/16 grid, self-contained, no Calypso/dispatcher), rather than
-- | installing it into a `tidal_voice`. The Pattern is queried per pulse but each
-- | event is placed at its TRUE fractional cycle position, so arps/triplets finer
-- | than 1/16 still land at their real time — 1/16 is only the poll cadence.
-- |
-- | Cycle mapping: the reef grid step is a 1/16 note (0.25 beat) and `cycle =
-- | beat / quantum`, so pulse `s` spans the exact rational cycle arc
-- | `[s/(4·quantum), (s+1)/(4·quantum))` — built from integers here, no float→rational
-- | approximation. `quantum` (beats per cycle, from the Link anchor) is passed in.
module Tidal.Vetula.Bridge
  ( buildVoicingsPattern
  , chordPcs
  , WireNote
  , queryNotes
  ) where

import Prelude

import Data.Array (mapMaybe, nub, sort)
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.Rational (fromInt, toNumber)

import Tidal.Pattern.Core (queryArc)
import Tidal.Pattern.Types (Arc(..), Event(..), Pattern)
import Tidal.Pitch (PitchedNote12(..))
import Tidal.Vetula.Pattern (fromVoicings, fromVoicingsArp, fromVoicingsHeld)
import Tidal.Vetula.Voicing (Voicing(..))
import Simple.JSON (readJSON)

-- | Decode a pushed progression (JSON `Array (Array Int)` of voiced MIDI) and render
-- | it through the named brush into a `Pattern PitchedNote12`.
-- |
-- |   renderer ∈ { "block", "arp", "held" | "legato" }  (unknown → "block")
-- |
-- | `held`/`legato` is the horizontal / common-tone reading — the audible form of the
-- | voice-leading (what the palette used to call "strum"). One chord per cycle for
-- | now; the palette's bars-per-chord dwell and skips become mininotation weighting
-- | later, and the brush's own combinators (fast, every, euclid, …) compose on top.
-- | Empty / unparseable input yields `silence` (via fromVoicings []).
buildVoicingsPattern :: String -> String -> Pattern PitchedNote12
buildVoicingsPattern renderer json =
  let
    voicings :: Array Voicing
    voicings = case (readJSON json :: Either _ (Array (Array Int))) of
      Right vss -> map Voicing vss
      Left _ -> []
  in
    case renderer of
      "arp" -> fromVoicingsArp voicings
      "held" -> fromVoicingsHeld voicings
      "legato" -> fromVoicingsHeld voicings
      _ -> fromVoicings voicings

-- | The chord-clock the Odonus conduct follows: each pushed voicing reduced to its
-- | sorted, unique PITCH CLASSES (0..11). Same JSON, same cat timeline as the MIDI
-- | pattern (chord i in cycle i), so the `FollowChord` conduct and the pads move on
-- | one pulse — aligned by construction. The reef voice holds this and indexes it by
-- | the active chord each pulse, handing chord i's pcs to `Reef.Input.mkFollowChord`.
chordPcs :: String -> Array (Array Int)
chordPcs json =
  case (readJSON json :: Either _ (Array (Array Int))) of
    Right vss -> map (nub <<< sort <<< map (\n -> mod n 12)) vss
    Left _ -> []

-- | One note-onset the reef voice will schedule: the absolute MIDI note plus the
-- | event's start/stop as fractional CYCLE positions (Numbers). The voice converts
-- | those to a wall-time (start) and a gate length (stop − start) using the same Link
-- | affine map it already uses for its own step wall-times.
type WireNote = { note :: Int, startCycle :: Number, stopCycle :: Number }

-- | Query the pattern for the note-onsets that fall within pulse `stepNum`'s exact
-- | cycle arc. Only events whose ONSET (`whole.start`) lies in this pulse are kept —
-- | notes that merely sustain through it were already emitted at their own onset
-- | pulse — so with the voice's per-pulse dedup each note fires exactly once. Only
-- | `Chromatic` values carry an absolute MIDI number; `Degree`/analog are dropped.
queryNotes :: Pattern PitchedNote12 -> Int -> Int -> Array WireNote
queryNotes pat stepNum quantum =
  let
    denom = 4 * quantum -- cyclesPerStep = (1/4 beat) / quantum = 1/(4·quantum)
    aStart = fromInt stepNum / fromInt denom
    aStop = fromInt (stepNum + 1) / fromInt denom
    onsetIn (Arc w) = w.start >= aStart && w.start < aStop
  in
    mapMaybe
      ( case _ of
          Digital d
            | onsetIn d.whole -> case d.value, d.whole of
                Chromatic n, Arc w ->
                  Just { note: n, startCycle: toNumber w.start, stopCycle: toNumber w.stop }
                _, _ -> Nothing
          _ -> Nothing
      )
      (queryArc pat aStart aStop)
