-- | **Drums written in Tidal: `drums $ s "bd*2 [~ sn] hh*8"`.**
-- |
-- | The pure half of the `drums` stream (`tidal_dirt_voice`, stream `drums`).
-- | It is timed exactly as `d1`..`d16` are (`Tidal.DirtVoice.onsetsUntil`),
-- | but where a `d` stream sends each event to SuperDirt, this one turns each
-- | into a hit on a lane of the drum kit (`Reef.Balistes.Kit`), and the rig
-- | plays the hit through the drum routing table, as it plays Balistes' Grids
-- | and Rhythm: Ableton's drum rack, the FH-2 gates, a Rample, a sample voice.
-- |
-- | How an event becomes a hit:
-- |
-- | - `s` names the lane, by the kit's names or the usual Dirt-Samples ones
-- |   (`bd`, `sn`, `hh`, `oh`, `cp`, `rim`, `cb` …). With no `s`, `n` is the
-- |   MIDI note itself. An event that names no lane plays nothing.
-- | - Velocity is `velocity` (0..1, Tidal's MIDI control, default 0.8) times
-- |   `gain` (default 1), on 1..127.
-- | - The gate is `sustain` (seconds) if given, else `legato` times the event's
-- |   length, else 30 ms, a trigger.
module Tidal.DrumVoice
  ( Hit
  , computeHits
  ) where

import Prelude

import Control.Alt ((<|>))
import Data.Array (mapMaybe, (!!))
import Data.Int as Int
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe)
import Haskell.Rational (toNumber)
import Reef.Balistes.Kit (canonKit, laneOfName)
import Tidal.DirtVoice (Onset, State, Window, onsetsUntil)
import Tidal.Pattern.Types (Value(..), ValueMap)

-- | A drum hit: when, which note (a kit lane's, so the routing table finds
-- | its lane), how hard, the gate, and the event's length (what a chopped
-- | sample voice spreads its slices across).
type Hit = { atUnixUs :: Number, note :: Int, velocity :: Int, durMs :: Number, spanMs :: Number }

computeHits :: Window -> State -> { newState :: State, hits :: Array Hit }
computeHits w st =
  let r = onsetsUntil w st
  in { newState: r.newState, hits: mapMaybe hit r.onsets }

hit :: Onset -> Maybe Hit
hit o = do
  note <- noteOf o.value
  let
    vel = fromMaybe 0.8 (num "velocity" o.value) * fromMaybe 1.0 (num "gain" o.value)
    spanMs = o.deltaS * 1000.0
    durMs = case num "sustain" o.value, num "legato" o.value of
      Just s, _ -> s * 1000.0
      _, Just l -> l * spanMs
      _, _ -> 30.0
  pure
    { atUnixUs: o.atUnixUs
    , note
    , velocity: clamp 1 127 (Int.round (vel * 127.0))
    , durMs: max 5.0 durMs
    , spanMs
    }

noteOf :: ValueMap -> Maybe Int
noteOf m = case Map.lookup "s" m of
  Just (VString name) -> laneOfName name >>= \lane -> map _.note (canonKit !! lane)
  Just _ -> Nothing
  Nothing -> map (clamp 0 127 <<< Int.round) (num "n" m <|> num "note" m)

num :: String -> ValueMap -> Maybe Number
num k m = case Map.lookup k m of
  Just (VNumber x) -> Just x
  Just (VNote x) -> Just x
  Just (VInt i) -> Just (Int.toNumber i)
  Just (VRational r) -> Just (toNumber r)
  _ -> Nothing
