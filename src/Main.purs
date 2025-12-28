-- | Browser entry point for Tidal MIDI
-- |
-- | This module provides a simple UI for testing pattern → MIDI output.
module Main where

import Prelude

import Control.Promise (toAffE)
import Data.Array as Array
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Effect (Effect)
import Effect.Aff (Aff, launchAff_)
import Effect.Class (liftEffect)
import Effect.Ref (Ref)
import Effect.Ref as Ref
import Tidal.Eval.Interpret (tpatToPattern)
import Tidal.Output.Scheduler (Scheduler, defaultNoteMapper, setBPM, setPattern, startScheduler, stopScheduler)
import Tidal.Output.WebMidi (MidiOutput, getOutputName, getOutputs, requestMidiAccess)
import Tidal.Parse.Parser (parseMini)

-------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------

type AppState =
  { output :: Maybe MidiOutput
  , scheduler :: Maybe (Scheduler String)
  , currentPattern :: String
  , bpm :: Number
  , playing :: Boolean
  }

foreign import getPatternInput :: Effect String
foreign import getBpmInput :: Effect Number
foreign import setStatus :: String -> Effect Unit
foreign import setOutputList :: Array String -> Effect Unit
foreign import onPlayClick :: Effect Unit -> Effect Unit
foreign import onStopClick :: Effect Unit -> Effect Unit
foreign import onPatternChange :: Effect Unit -> Effect Unit
foreign import onBpmChange :: Effect Unit -> Effect Unit
foreign import onOutputSelect :: (Int -> Effect Unit) -> Effect Unit

-------------------------------------------------------------------------------
-- Main
-------------------------------------------------------------------------------

main :: Effect Unit
main = do
  -- Initialize state
  stateRef <- Ref.new
    { output: Nothing
    , scheduler: Nothing
    , currentPattern: "bd sn hh cp"
    , bpm: 120.0
    , playing: false
    }

  setStatus "Requesting MIDI access..."

  launchAff_ do
    -- Request MIDI access
    result <- attemptMidiAccess
    case result of
      Left err -> liftEffect $ setStatus $ "MIDI Error: " <> err
      Right outputs -> do
        liftEffect $ setupUI stateRef outputs

attemptMidiAccess :: Aff (Either String (Array MidiOutput))
attemptMidiAccess = do
  access <- toAffE requestMidiAccess
  outputs <- liftEffect $ getOutputs access
  if Array.null outputs
    then pure $ Left "No MIDI outputs found. Connect a MIDI device and refresh."
    else pure $ Right outputs

setupUI :: Ref AppState -> Array MidiOutput -> Effect Unit
setupUI stateRef outputs = do
  -- Populate output list
  let names = map getOutputName outputs
  setOutputList names

  -- Select first output by default
  case Array.head outputs of
    Just out -> Ref.modify_ (_ { output = Just out }) stateRef
    Nothing -> pure unit

  setStatus "Ready. Enter a pattern and click Play."

  -- Wire up event handlers
  onOutputSelect \idx -> do
    case Array.index outputs idx of
      Just out -> Ref.modify_ (_ { output = Just out }) stateRef
      Nothing -> pure unit

  onPlayClick do
    state <- Ref.read stateRef
    case state.output of
      Nothing -> setStatus "No MIDI output selected"
      Just output -> do
        patternText <- getPatternInput
        bpm <- getBpmInput

        case parseMini patternText of
          Left err -> setStatus $ "Parse error: " <> show err
          Right ast -> do
            let pattern = tpatToPattern ast

            -- Stop existing scheduler if any
            case state.scheduler of
              Just s -> stopScheduler s
              Nothing -> pure unit

            -- Start new scheduler
            scheduler <- startScheduler output pattern defaultNoteMapper bpm
            Ref.write
              { output: Just output
              , scheduler: Just scheduler
              , currentPattern: patternText
              , bpm
              , playing: true
              } stateRef

            setStatus $ "Playing: " <> patternText <> " @ " <> show bpm <> " BPM"

  onStopClick do
    state <- Ref.read stateRef
    case state.scheduler of
      Just s -> do
        stopScheduler s
        Ref.modify_ (_ { scheduler = Nothing, playing = false }) stateRef
        setStatus "Stopped"
      Nothing -> setStatus "Not playing"

  onPatternChange do
    state <- Ref.read stateRef
    when state.playing do
      patternText <- getPatternInput
      case state.scheduler of
        Nothing -> pure unit
        Just scheduler ->
          case parseMini patternText of
            Left _ -> pure unit  -- Don't update on parse error
            Right ast -> do
              let pattern = tpatToPattern ast
              setPattern scheduler pattern
              Ref.modify_ (_ { currentPattern = patternText }) stateRef
              setStatus $ "Pattern updated: " <> patternText

  onBpmChange do
    state <- Ref.read stateRef
    when state.playing do
      bpm <- getBpmInput
      case state.scheduler of
        Nothing -> pure unit
        Just scheduler -> do
          setBPM scheduler bpm
          Ref.modify_ (_ { bpm = bpm }) stateRef
          setStatus $ "BPM: " <> show bpm
