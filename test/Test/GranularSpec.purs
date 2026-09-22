-- | The granular read-head vocabulary (C0 of CONSPICILLUM-DESIGN.md).
-- |
-- | Everything here tests a way these verbs can fail **silently**, which is
-- | the only interesting kind of failure for them: a control that never
-- | reaches SuperDirt produces no error, no log line and no sound — it
-- | produces the *same* sound as before, which reads as "the param does
-- | nothing on this material" rather than as a bug.
-- |
-- | Three such paths, one test group each:
-- |
-- |   1. **Negative literals.**  `accelerate` and `curve` are meaningfully
-- |      negative (`curve`'s SuperDirt default is -3).  If mini-notation
-- |      tokenised `-3` as anything but the single token `"-3"`,
-- |      `Number.fromString` would return `Nothing` and `numControl` would
-- |      yield an empty payload.  No error anywhere.
-- |   2. **`mergeSound` completeness.**  A field added to the record and the
-- |      verb but forgotten in `mergeSound` compiles perfectly and is then
-- |      dropped by every `#`.  Since `#` is how these are *always* written,
-- |      that bug would hide behind the whole feature.
-- |   3. **`soundParams` completeness.**  A field that never becomes a map
-- |      entry never reaches `/dirt/play`.  Same invisibility.
module Test.GranularSpec (runGranularTests) where

import Prelude

import Data.Array as Array
import Data.Foldable (for_)
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Rational (fromInt)
import Effect (Effect)
import Effect.Console (log)
import Tidal.Pattern.Core (queryArc)
import Tidal.Pattern.Types (eventValue)
import Tidal.Sound
  ( Sound
  , SoundPattern
  , accelerate
  , curve
  , plat
  , s
  , soundParams
  , sustain
  , tilt
  , timescale
  , timescalewin
  , controlVerb
  , (#)
  )

-- | The payload of the first event of a one-cycle query, if there is one.
firstSound :: SoundPattern -> Maybe Sound
firstSound p = map eventValue (Array.head (queryArc p (fromInt 0) (fromInt 1)))

check :: String -> Boolean -> Effect Unit
check label ok = log $ (if ok then "  ok   " else "  FAIL ") <> label

checkNum :: String -> Maybe Number -> Number -> Effect Unit
checkNum label got want = case got of
  Just v | v == want -> check label true
  Just v -> log $ "  FAIL " <> label <> " — got " <> show v <> ", wanted " <> show want
  Nothing -> log $ "  FAIL " <> label <> " — field unset (silently dropped)"

runGranularTests :: Effect Unit
runGranularTests = do
  log ""
  log "=========================================="
  log "  Granular read-head vocabulary (C0)"
  log "=========================================="

  -- 1 ----------------------------------------------------------------
  log ""
  log "--- negative literals survive mini-notation ---"
  checkNum "accelerate \"-0.5\"" (_.accelerate =<< firstSound (accelerate "-0.5")) (-0.5)
  checkNum "curve \"-3\""        (_.curve      =<< firstSound (curve "-3"))        (-3.0)
  checkNum "accelerate \"0.25\"" (_.accelerate =<< firstSound (accelerate "0.25"))  0.25

  -- 2 ----------------------------------------------------------------
  -- Every new field set through a SEPARATE `#`, so each one has to make it
  -- through `mergeSound` independently.  A field missing from the merge
  -- shows up here and nowhere else.
  log ""
  log "--- every new field survives `#` (mergeSound completeness) ---"
  let merged = firstSound
        ( s "bd"
            # sustain "0.03"
            # accelerate "-0.5"
            # tilt "0.2"
            # plat "0.8"
            # curve "-3"
            # timescale "1.5"
            # timescalewin "0.25"
        )
  checkNum "sustain"      (_.sustain      =<< merged) 0.03
  checkNum "accelerate"   (_.accelerate   =<< merged) (-0.5)
  checkNum "tilt"         (_.tilt         =<< merged) 0.2
  checkNum "plat"         (_.plat         =<< merged) 0.8
  checkNum "curve"        (_.curve        =<< merged) (-3.0)
  checkNum "timescale"    (_.timescale    =<< merged) 1.5
  checkNum "timescalewin" (_.timescalewin =<< merged) 0.25

  -- 3 ----------------------------------------------------------------
  -- The map `soundParams` builds is what `dirtExtras` turns into the
  -- `/dirt/play` float pairs, so a missing key here is a param that never
  -- leaves the BEAM.
  log ""
  log "--- every new field reaches the /dirt/play param bag ---"
  case merged of
    Nothing -> log "  FAIL no event to take params from"
    Just snd -> do
      let params = soundParams snd
      for_ [ "sustain", "accelerate", "tilt", "plat", "curve"
           , "timescale", "timescalewin" ] \k ->
        check ("soundParams has \"" <> k <> "\"") (Map.member k params)

  -- 4 ----------------------------------------------------------------
  -- The live-text path: `# tilt "0.2"` typed into a cell resolves its
  -- control NAME through `controlVerb`.  A verb present in the record but
  -- absent from that table works in PureScript source and does nothing
  -- when typed.
  log ""
  log "--- the live-text `# <name>` path resolves each new name ---"
  for_ [ "sustain", "accelerate", "tilt", "plat", "curve"
       , "timescale", "timescalewin" ] \name ->
    check ("controlVerb \"" <> name <> "\"") (isJustVerb (controlVerb name))
  where
  isJustVerb = case _ of
    Just _ -> true
    Nothing -> false
