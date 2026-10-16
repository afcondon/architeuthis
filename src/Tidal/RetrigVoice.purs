-- | **LFO resets on the beat: a Selene bank's `# retrig "1 ~ [3 5] ~"`.**
-- |
-- | The pure half of a retrig stream (`tidal_dirt_voice`, stream
-- | `{retrig, Base}`, kept in step with the rack by `selene_retrig`). It is
-- | timed exactly as `d1`..`d16` are (`Tidal.DirtVoice.onsetsUntil`); each
-- | event names a slot of an FH-2 LFO bank, and becomes the note that resets
-- | that output's LFO (fh2-config `FH2.LfoReset`: MIDI channel 16, note =
-- | FH-2 output index), so the LFO restarts at its phase offset on the onset.
-- |
-- | How an event becomes resets: the pattern is read as `s "<pattern>"`, so a
-- | token is a word. `1`..`8` is that slot (output `base + slot - 1`); `all`
-- | is all eight at once. Anything else resets nothing.
module Tidal.RetrigVoice
  ( Reset
  , computeResets
  , resetChannel
  ) where

import Prelude

import Data.Array (concatMap, range)
import Data.Int as Int
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Tidal.DirtVoice (Onset, State, Window, onsetsUntil)
import Tidal.Pattern.Types (Value(..))

-- | One reset: when, and the note (channel `resetChannel`) that does it.
type Reset = { atUnixUs :: Number, note :: Int }

-- | MIDI channel 16, 1-based as Diaphus's `/midi/note/at` takes it.
resetChannel :: Int
resetChannel = 16

computeResets :: Int -> Window -> State -> { newState :: State, resets :: Array Reset }
computeResets base w st =
  let r = onsetsUntil w st
  in { newState: r.newState, resets: concatMap (resetsOf base) r.onsets }

resetsOf :: Int -> Onset -> Array Reset
resetsOf base o = map (\slot -> { atUnixUs: o.atUnixUs, note: base + slot - 1 }) slots
  where
  slots = case Map.lookup "s" o.value of
    Just (VString "all") -> range 1 8
    Just (VString w) -> one (Int.fromString w)
    Just (VInt i) -> one (Just i)
    _ -> []
  one = case _ of
    Just n | n >= 1 && n <= 8 -> [ n ]
    _ -> []
