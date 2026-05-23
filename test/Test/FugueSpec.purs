-- | Tests for `Tidal.Fugue` — scale-aware transposition (task #62 sibling).
-- |
-- | The Fugue module already uses `transposeDiatonic` for the
-- | `transpose` field of `Voice`, so the substrate is degree-arithmetic
-- | rather than semitone-arithmetic.  These tests pin that down so a
-- | future "let's just `transposeChromatic` it" change can't quietly
-- | flip the model and stack minor seconds across the voices on a
-- | wire-level `set-scale`.
-- |
-- | The companion check is end-to-end: render through `inKey` against
-- | two different scales and confirm the rendered MIDI moves the
-- | scale-degree way (degree 5 of C major = G4 = 67; degree 5 of D
-- | dorian = A4 = 69).  That's the property a hand-written fugue
-- | demonstrably has.
module Test.FugueSpec
  ( runFugueTests
  ) where

import Prelude

import Data.Array (sortBy)
import Data.Rational (fromInt)
import Effect (Effect)
import Effect.Console (log)

import Tidal.Fugue (defaultVoice, doubleSpeed, fugueVoice)
import Tidal.Pattern.Core (queryArc)
import Tidal.Pattern.Types (Pattern, arcStart, eventPart, eventValue)
import Tidal.Pitch (PitchedNote12(..))
import Tidal.Pitch.Parse (degree, pitch)
import Tidal.Scales (cMajor, dDorian, inKey)

runFugueTests :: Effect Unit
runFugueTests = do
  log ""
  log "--- Fugue scale-aware transposition (task #62 sibling) ---"

  -- --------------------------------------------------------------------
  -- Identity: `defaultVoice` is the unprocessed subject.
  -- --------------------------------------------------------------------
  expectPitches
    "defaultVoice is identity"
    [Degree 1, Degree 5]
    (fugueVoice defaultVoice (degree "1 5"))

  -- --------------------------------------------------------------------
  -- Diatonic transpose: +4 shifts Degree by 4, NOT by semitones.  This
  -- is the property that prevents minor-second stacking under live
  -- `set-scale`: every voice stays the same degree-shift away from the
  -- subject, so retuning the scale shifts all voices coherently.
  -- --------------------------------------------------------------------
  expectPitches
    "transpose = 4 maps degree 1, 5 → degree 5, 9"
    [Degree 5, Degree 9]
    (fugueVoice (defaultVoice { transpose = 4 }) (degree "1 5"))

  -- --------------------------------------------------------------------
  -- Retrograde + transpose order: speed → rev → transpose.  Verifies
  -- the order of composition documented in the Fugue module.
  -- --------------------------------------------------------------------
  expectPitches
    "retrograde then transpose +4: d 1 5 → degrees 9, 5"
    [Degree 9, Degree 5]
    (fugueVoice (defaultVoice { retrograde = true, transpose = 4 }) (degree "1 5"))

  -- --------------------------------------------------------------------
  -- Speed: doubleSpeed packs two cycles of the source into one cycle
  -- of the clock — four events for `d "1 5"` over [0, 1].
  -- --------------------------------------------------------------------
  let
    fastEvents = queryArc
      (fugueVoice (defaultVoice { speed = doubleSpeed }) (degree "1 5"))
      (fromInt 0) (fromInt 1)
  if (map eventValue fastEvents) == [Degree 1, Degree 5, Degree 1, Degree 5]
    then log "  ✓ doubleSpeed packs two passes into one cycle"
    else log $ "  ✗ doubleSpeed: got " <> show (map eventValue fastEvents)

  -- --------------------------------------------------------------------
  -- Chromatic input is INTENTIONALLY untouched by transpose.  The
  -- fugue model expects degree-based subjects; chromatic notes (sharps,
  -- absolute alterations) are passed through verbatim.  This is the
  -- safety: a user who writes `pitch "c4"` in the middle of a degree
  -- subject keeps the literal C4 across every voice, no surprises.
  -- --------------------------------------------------------------------
  expectPitches
    "transpose does NOT shift Chromatic notes"
    [Chromatic 60, Chromatic 64]
    (fugueVoice (defaultVoice { transpose = 4 }) (pitch "c4 e4"))

  -- --------------------------------------------------------------------
  -- Cross-scale end-to-end: same fugue voice, two different active
  -- scales, different rendered MIDI.  Degree 5 of cMajor = G4 = 67;
  -- degree 5 of dDorian = A4 = 69.  This is the property a fugue
  -- under live `set-scale` exhibits in performance.
  -- --------------------------------------------------------------------
  expectPitches
    "transpose +4 on d 1, rendered through cMajor → Chromatic 67 (G4)"
    [Chromatic 67]
    (inKey cMajor (fugueVoice (defaultVoice { transpose = 4 }) (degree "1")))

  expectPitches
    "transpose +4 on d 1, rendered through dDorian → Chromatic 69 (A4)"
    [Chromatic 69]
    (inKey dDorian (fugueVoice (defaultVoice { transpose = 4 }) (degree "1")))

-- | `queryArc` returns events in array order, NOT time order.  `rev`
-- | moves events' whole/part positions in time but doesn't reshuffle
-- | the result array — so musical-order checks (what a listener hears)
-- | must sort by `part.start` before extracting values.
expectPitches :: String -> Array PitchedNote12 -> Pattern PitchedNote12 -> Effect Unit
expectPitches desc expected pat =
  let
    events = queryArc pat (fromInt 0) (fromInt 1)
    sorted = sortBy (\a b -> compare (arcStart (eventPart a))
                                      (arcStart (eventPart b))) events
    actual = map eventValue sorted
  in
    if actual == expected
      then log $ "  ✓ " <> desc
      else log $ "  ✗ " <> desc <> "\n     got:      " <> show actual
                                       <> "\n     expected: " <> show expected
