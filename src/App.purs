-- | Algorave Visualizer with MIDI Playback
-- |
-- | A round-tripping pattern editor that combines:
-- | - Visual editing (sunburst/tree views of patterns)
-- | - Text editing (mini-notation)
-- | - MIDI playback via Web MIDI API
module App where

import Prelude

import Component.PatternTree (PatternTree(..), parseMiniNotation)
import Control.Promise (toAffE)
import D3.Viz.PatternTree.CombinatorTree (Combinator, TreeMetadata, buildCombinatorTreesFromTracks, drawCombinatorForest)
import D3.Viz.PatternTreeViz (TrackLayout(..), ZoomTransform, drawPatternForestMixed, identityZoom)
import Data.Array as Array
import Data.Either (Either(..))
import Data.Int as Int
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Number as Number
import Data.String as String
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..), uncurry)
import Effect (Effect)
import Effect.Aff (Aff, launchAff_)
import Effect.Aff.Class (class MonadAff)
import Effect.Class (liftEffect)
import Effect.Console as Console
import Effect.Ref (Ref)
import Effect.Ref as Ref
import Halogen as H
import Halogen.Aff as HA
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP
import Halogen.Subscription as HS
import Halogen.VDom.Driver (runUI)
import Parsing (parseErrorMessage)
import Tangle.DragEvents (dragEventSource)
import Tangle.Halogen (ControlAction(..), renderDoc)
import Tangle.TidalTangle (tracksToTangleDoc, parseCombinatorLabel)
import Tidal.Eval.Interpret (tpatToPattern)
import Tidal.Output.Scheduler (Scheduler, NoteMapper, defaultNoteMapper, setBPM, setPattern, startScheduler, stopScheduler)
import Tidal.Output.WebMidi (MidiAccess, MidiOutput, getOutputName, getOutputs, requestMidiAccess)
import Tidal.Parse.Parser (parseMini)
import Tidal.Pattern.Types (Pattern(..))

-------------------------------------------------------------------------------
-- Types
-------------------------------------------------------------------------------

-- | Effect/control pattern (the # operator in Tidal)
type TidalEffect =
  { name :: String
  , value :: String
  , enabled :: Boolean
  }

-- | Named pattern (a track in the set)
type Track =
  { name :: String
  , pattern :: PatternTree
  , active :: Boolean
  , layout :: TrackLayout
  , combinators :: Array Combinator
  , effects :: Array TidalEffect
  }

-- | View mode for the visualization
data ViewMode = PatternView | CombinatorTreeView

derive instance Eq ViewMode

-- | Drag state for adjustable Tangle controls
type DragInfo =
  { id :: String
  , startValue :: Number
  , startX :: Number
  , step :: Number
  , min :: Number
  , max :: Number
  , subscriptionId :: H.SubscriptionId
  }

-- | MIDI playback state
type MidiState =
  { access :: Maybe MidiAccess
  , outputs :: Array MidiOutput
  , selectedOutput :: Maybe MidiOutput
  , scheduler :: Maybe (Scheduler String)
  , playing :: Boolean
  , bpm :: Number
  }

-- | Component state
type State =
  { tracks :: Array Track
  , miniNotationInput :: String
  , parseError :: Maybe String
  , zoomTransform :: ZoomTransform
  , leftPanelOpen :: Boolean
  , viewMode :: ViewMode
  , showSunburstLeaves :: Boolean
  , adjustDrag :: Maybe DragInfo
  , midi :: MidiState
  }

-- | Path to a node in the pattern tree
type NodePath = Array Int

-- | Component actions
data Action
  = Initialize
  | ToggleTrack Int
  | ToggleTrackLayout Int
  | RenderForest
  | ToggleTrackFromViz Int
  | ToggleLayoutFromViz Int
  | ToggleNodeTypeFromViz Int NodePath
  | AdjustEuclideanFromViz Int NodePath Int Int
  | ToggleCombinatorFromViz Int Int
  | TangleControl ControlAction
  | DragMove Int
  | DragEnd
  | ZoomChanged ZoomTransform
  | UpdateMiniNotation String
  | ParseAndAddTrack
  | AddPresetPattern String String
  | ClearTracks
  | ToggleLeftPanel
  | ToggleViewMode
  | ToggleSunburstLeaves
  -- MIDI actions
  | SelectMidiOutput Int
  | SetBPM String
  | TogglePlayback
  | UpdateSchedulerPattern

-- | Helper to create enabled combinators
comb :: String -> Combinator
comb label = { label, enabled: true }

-- | Helper to create effects
fx :: String -> String -> TidalEffect
fx name value = { name, value, enabled: true }

-- | Example set with patterns
exampleSet :: Array Track
exampleSet =
  [ { name: "kick"
    , pattern: Sequence [Sound "bd", Rest, Sound "bd", Rest]
    , active: true
    , layout: SunburstLayout
    , combinators: []
    , effects: []
    }
  , { name: "snare"
    , pattern: Sequence [Rest, Sound "sn", Rest, Sound "sn"]
    , active: true
    , layout: SunburstLayout
    , combinators: []
    , effects: []
    }
  , { name: "hats"
    , pattern: Fast 2.0 (Sound "hh")
    , active: true
    , layout: SunburstLayout
    , combinators: []
    , effects: []
    }
  ]

-------------------------------------------------------------------------------
-- Component
-------------------------------------------------------------------------------

component :: forall q i o m. MonadAff m => H.Component q i o m
component = H.mkComponent
  { initialState: \_ ->
      { tracks: exampleSet
      , miniNotationInput: "bd sn [hh hh] cp"
      , parseError: Nothing
      , zoomTransform: identityZoom
      , leftPanelOpen: true
      , viewMode: PatternView
      , showSunburstLeaves: true
      , adjustDrag: Nothing
      , midi:
          { access: Nothing
          , outputs: []
          , selectedOutput: Nothing
          , scheduler: Nothing
          , playing: false
          , bpm: 120.0
          }
      }
  , render
  , eval: H.mkEval H.defaultEval
      { handleAction = handleAction
      , initialize = Just Initialize
      }
  }

handleAction :: forall o m. MonadAff m => Action -> H.HalogenM State Action () o m Unit
handleAction = case _ of
  Initialize -> do
    -- Request MIDI access
    liftEffect $ Console.log "Requesting MIDI access..."
    result <- H.liftAff do
      access <- toAffE requestMidiAccess
      outputs <- liftEffect $ getOutputs access
      liftEffect $ Console.log $ "Found " <> show (Array.length outputs) <> " MIDI outputs"
      pure { access, outputs }
    -- Update state with MIDI info
    H.modify_ \s -> s
      { midi = s.midi
          { access = Just result.access
          , outputs = result.outputs
          , selectedOutput = Array.head result.outputs
          }
      }
    -- Render initial forest
    handleAction RenderForest

  ToggleTrack idx -> do
    H.modify_ \s -> s { tracks = updateAt idx (\t -> t { active = not t.active }) s.tracks }

  ToggleTrackLayout idx -> do
    H.modify_ \s -> s { tracks = updateAt idx (\t -> t { layout = toggleLayout t.layout }) s.tracks }
    handleAction RenderForest

  ToggleTrackFromViz idx -> do
    H.modify_ \s -> s { tracks = updateAt idx (\t -> t { active = not t.active }) s.tracks }
    handleAction RenderForest

  ToggleLayoutFromViz idx -> do
    H.modify_ \s -> s { tracks = updateAt idx (\t -> t { layout = toggleLayout t.layout }) s.tracks }
    handleAction RenderForest

  ToggleNodeTypeFromViz trackIdx nodePath -> do
    liftEffect $ Console.log $ "Toggle node type at track " <> show trackIdx <> " path " <> show nodePath
    H.modify_ \s -> s { tracks = updateAt trackIdx (\t -> t { pattern = toggleNodeType nodePath t.pattern }) s.tracks }
    handleAction RenderForest

  AdjustEuclideanFromViz trackIdx nodePath deltaN deltaK -> do
    liftEffect $ Console.log $ "Adjust euclidean at track " <> show trackIdx
    H.modify_ \s -> s { tracks = updateAt trackIdx (\t -> t { pattern = adjustEuclidean nodePath deltaN deltaK t.pattern }) s.tracks }
    handleAction RenderForest

  ToggleCombinatorFromViz trackIdx combIdx -> do
    liftEffect $ Console.log $ "Toggle combinator at track " <> show trackIdx
    H.modify_ \s -> s { tracks = updateAt trackIdx (\t -> t { combinators = toggleCombinator combIdx t.combinators }) s.tracks }
    handleAction RenderForest

  TangleControl ctrlAction -> handleTangleAction ctrlAction

  DragMove clientX -> handleDragMove clientX

  DragEnd -> handleDragEnd

  UpdateMiniNotation input -> do
    H.modify_ \s -> s { miniNotationInput = input, parseError = Nothing }

  ParseAndAddTrack -> do
    state <- H.get
    case parseMiniNotation state.miniNotationInput of
      Left err -> do
        liftEffect $ Console.log $ "Parse error: " <> parseErrorMessage err
        H.modify_ \s -> s { parseError = Just (parseErrorMessage err) }
      Right pattern -> do
        let trackName = "track" <> show (Array.length state.tracks + 1)
        let newTrack = { name: trackName, pattern, active: true, layout: SunburstLayout, combinators: [], effects: [] }
        H.modify_ \s -> s { tracks = Array.snoc s.tracks newTrack, miniNotationInput = "", parseError = Nothing }
        handleAction RenderForest
        handleAction UpdateSchedulerPattern

  AddPresetPattern name patternStr -> do
    case parseMiniNotation patternStr of
      Left _ -> pure unit
      Right pattern -> do
        let newTrack = { name, pattern, active: true, layout: SunburstLayout, combinators: [], effects: [] }
        H.modify_ \s -> s { tracks = Array.snoc s.tracks newTrack }
        handleAction RenderForest
        handleAction UpdateSchedulerPattern

  ClearTracks -> do
    H.modify_ \s -> s { tracks = [] }
    handleAction RenderForest
    handleAction UpdateSchedulerPattern

  ToggleLeftPanel -> H.modify_ \s -> s { leftPanelOpen = not s.leftPanelOpen }

  ToggleViewMode -> do
    H.modify_ \s -> s { viewMode = if s.viewMode == PatternView then CombinatorTreeView else PatternView }
    handleAction RenderForest

  ToggleSunburstLeaves -> do
    H.modify_ \s -> s { showSunburstLeaves = not s.showSunburstLeaves }
    handleAction RenderForest

  RenderForest -> renderPatternForest

  -- MIDI actions
  SelectMidiOutput idx -> do
    state <- H.get
    case Array.index state.midi.outputs idx of
      Just output -> H.modify_ \s -> s { midi = s.midi { selectedOutput = Just output } }
      Nothing -> pure unit

  SetBPM bpmStr -> do
    case Number.fromString bpmStr of
      Just bpm -> do
        H.modify_ \s -> s { midi = s.midi { bpm = bpm } }
        state <- H.get
        case state.midi.scheduler of
          Just scheduler -> liftEffect $ setBPM scheduler bpm
          Nothing -> pure unit
      Nothing -> pure unit

  TogglePlayback -> do
    state <- H.get
    if state.midi.playing
      then do
        -- Stop playback
        case state.midi.scheduler of
          Just scheduler -> liftEffect $ stopScheduler scheduler
          Nothing -> pure unit
        H.modify_ \s -> s { midi = s.midi { playing = false, scheduler = Nothing } }
      else do
        -- Start playback
        case state.midi.selectedOutput of
          Nothing -> liftEffect $ Console.log "No MIDI output selected"
          Just output -> do
            let combinedPattern = combineActivePatterns state.tracks
            scheduler <- liftEffect $ startScheduler output combinedPattern defaultNoteMapper state.midi.bpm
            H.modify_ \s -> s { midi = s.midi { playing = true, scheduler = Just scheduler } }

  UpdateSchedulerPattern -> do
    state <- H.get
    case state.midi.scheduler of
      Nothing -> pure unit
      Just scheduler -> do
        let combinedPattern = combineActivePatterns state.tracks
        liftEffect $ setPattern scheduler combinedPattern

  ZoomChanged transform -> H.modify_ \s -> s { zoomTransform = transform }

-------------------------------------------------------------------------------
-- Pattern combination for MIDI
-------------------------------------------------------------------------------

-- | Combine all active tracks into a single Pattern for MIDI output
combineActivePatterns :: Array Track -> Pattern String
combineActivePatterns tracks =
  let
    activeTracks = Array.filter _.active tracks
    patterns = map (\t -> patternTreeToMini t.pattern) activeTracks
    combined = if Array.null patterns then "~" else String.joinWith ", " patterns
  in
    case parseMini combined of
      Right ast -> tpatToPattern ast
      Left _ -> silentPattern

-- | A silent pattern that returns no events
silentPattern :: Pattern String
silentPattern =
  -- "~" should always parse - if it doesn't, return empty pattern
  case parseMini "~" of
    Right ast -> tpatToPattern ast
    Left _ -> emptyPattern
  where
    -- Empty pattern returns no events for any query
    emptyPattern = Pattern (\_ -> [])

-- | Convert PatternTree to mini-notation string
patternTreeToMini :: PatternTree -> String
patternTreeToMini = case _ of
  Sound s -> s
  Rest -> "~"
  Sequence children -> String.joinWith " " (map patternTreeToMini children)
  Parallel children -> "[" <> String.joinWith ", " (map patternTreeToMini children) <> "]"
  Choice children -> String.joinWith " | " (map patternTreeToMini children)
  Fast n child -> patternTreeToMini child <> "*" <> show n
  Slow n child -> patternTreeToMini child <> "/" <> show n
  Euclidean n k child -> patternTreeToMini child <> "(" <> show n <> "," <> show k <> ")"
  Degrade prob child -> patternTreeToMini child <> "?" <> show prob
  Repeat n child -> patternTreeToMini child <> "!" <> show n
  Elongate n child -> patternTreeToMini child <> "@" <> show n

-------------------------------------------------------------------------------
-- Rendering
-------------------------------------------------------------------------------

renderPatternForest :: forall o m. MonadAff m => H.HalogenM State Action () o m Unit
renderPatternForest = do
  state <- H.get
  case state.viewMode of
    PatternView -> do
      let allTracksWithLayout = Array.mapWithIndex (\idx t ->
            { name: t.name
            , pattern: t.pattern
            , trackIndex: idx
            , active: t.active
            , layout: t.layout
            }) state.tracks
      { emitter: activeEmitter, listener: activeListener } <- liftEffect HS.create
      { emitter: layoutEmitter, listener: layoutListener } <- liftEffect HS.create
      { emitter: nodeTypeEmitter, listener: nodeTypeListener } <- liftEffect HS.create
      { emitter: euclidEmitter, listener: euclidListener } <- liftEffect HS.create
      { emitter: zoomEmitter, listener: zoomListener } <- liftEffect HS.create
      _ <- H.subscribe (ToggleTrackFromViz <$> activeEmitter)
      _ <- H.subscribe (ToggleLayoutFromViz <$> layoutEmitter)
      _ <- H.subscribe (uncurry ToggleNodeTypeFromViz <$> nodeTypeEmitter)
      _ <- H.subscribe ((\(Tuple trackIdx (Tuple path (Tuple dn dk))) -> AdjustEuclideanFromViz trackIdx path dn dk) <$> euclidEmitter)
      _ <- H.subscribe (ZoomChanged <$> zoomEmitter)
      liftEffect $ drawPatternForestMixed "#pattern-forest-viz" allTracksWithLayout
        (HS.notify activeListener)
        (HS.notify layoutListener)
        (\trackIdx path -> HS.notify nodeTypeListener (Tuple trackIdx path))
        (\trackIdx path dn dk -> HS.notify euclidListener (Tuple trackIdx (Tuple path (Tuple dn dk))))
        state.zoomTransform
        (HS.notify zoomListener)

    CombinatorTreeView -> do
      let indexedTracks = Array.mapWithIndex (\i t -> { idx: i, track: t }) state.tracks
      let tracksWithCombinators = Array.filter (\t -> Array.length t.track.combinators > 0) indexedTracks
      let trackInfos = map (\t ->
            { name: t.track.name
            , pattern: t.track.pattern
            , combinators: t.track.combinators
            , expandPattern: t.track.layout == TreeLayout
            }) tracksWithCombinators
      let combTrees = buildCombinatorTreesFromTracks trackInfos
      let metadata :: Array TreeMetadata
          metadata = map (\t ->
            { trackIndex: t.idx
            , active: t.track.active
            , useTreeLayout: t.track.layout == TreeLayout
            }) tracksWithCombinators
      { emitter: muteEmitter, listener: muteListener } <- H.liftEffect HS.create
      _ <- H.subscribe (ToggleTrackFromViz <$> muteEmitter)
      { emitter: layoutEmitter, listener: layoutListener } <- H.liftEffect HS.create
      _ <- H.subscribe (ToggleLayoutFromViz <$> layoutEmitter)
      { emitter: combEmitter, listener: combListener } <- H.liftEffect HS.create
      _ <- H.subscribe (uncurry ToggleCombinatorFromViz <$> combEmitter)
      { emitter: zoomEmitter, listener: zoomListener } <- H.liftEffect HS.create
      _ <- H.subscribe (ZoomChanged <$> zoomEmitter)
      liftEffect $ drawCombinatorForest "#pattern-forest-viz" combTrees metadata
        (HS.notify muteListener)
        (HS.notify layoutListener)
        (\trackIdx combIdx -> HS.notify combListener (Tuple trackIdx combIdx))
        state.zoomTransform
        (HS.notify zoomListener)

render :: forall m. State -> H.ComponentHTML Action () m
render state =
  HH.div
    [ HP.classes [ HH.ClassName "algorave-app" ] ]
    [ -- Header
      HH.header
        [ HP.classes [ HH.ClassName "app-header" ] ]
        [ HH.h1_ [ HH.text "Algorave Visualizer" ]
        , HH.span
            [ HP.classes [ HH.ClassName "subtitle" ] ]
            [ HH.text "Visual + Text + MIDI" ]
        ]

    -- Main content
    , HH.div
        [ HP.classes [ HH.ClassName "app-container" ] ]
        [ -- Left panel (slide-out)
          HH.div
            [ HP.classes $
                [ HH.ClassName "slide-panel" ] <>
                if state.leftPanelOpen then [ HH.ClassName "slide-panel--open" ] else []
            ]
            [ renderControlPanel state ]

        -- Toggle button
        , HH.button
            [ HE.onClick \_ -> ToggleLeftPanel
            , HP.classes [ HH.ClassName "panel-toggle" ]
            ]
            [ HH.text $ if state.leftPanelOpen then "◀" else "▶" ]

        -- Main visualization area
        , HH.div
            [ HP.id "pattern-forest-viz"
            , HP.classes [ HH.ClassName "viz-container" ]
            ]
            []

        -- MIDI control panel (bottom)
        , HH.div
            [ HP.classes [ HH.ClassName "midi-panel" ] ]
            [ renderMidiControls state ]
        ]
    ]

renderControlPanel :: forall m. State -> H.ComponentHTML Action () m
renderControlPanel state =
  HH.div
    [ HP.classes [ HH.ClassName "control-panel" ] ]
    [ -- Mini-notation input
      HH.div
        [ HP.classes [ HH.ClassName "control-section" ] ]
        [ HH.label_ [ HH.text "Mini-notation" ]
        , HH.textarea
            [ HP.value state.miniNotationInput
            , HE.onValueInput UpdateMiniNotation
            , HP.placeholder "bd sn [hh hh] cp"
            , HP.rows 2
            ]
        , HH.div
            [ HP.classes [ HH.ClassName "button-row" ] ]
            [ HH.button
                [ HE.onClick \_ -> ParseAndAddTrack
                , HP.classes [ HH.ClassName "btn-primary" ]
                ]
                [ HH.text "Add Track" ]
            , HH.button
                [ HE.onClick \_ -> ClearTracks
                , HP.classes [ HH.ClassName "btn-secondary" ]
                ]
                [ HH.text "Clear" ]
            ]
        , case state.parseError of
            Just err -> HH.div [ HP.classes [ HH.ClassName "error" ] ] [ HH.text err ]
            Nothing -> HH.text ""
        ]

    -- View mode toggle
    , HH.div
        [ HP.classes [ HH.ClassName "control-section" ] ]
        [ HH.button
            [ HE.onClick \_ -> ToggleViewMode
            , HP.classes [ HH.ClassName "btn-accent" ]
            ]
            [ HH.text $ case state.viewMode of
                PatternView -> "Tree View"
                CombinatorTreeView -> "Pattern View"
            ]
        ]

    -- Preset patterns
    , HH.div
        [ HP.classes [ HH.ClassName "control-section" ] ]
        [ HH.label_ [ HH.text "Presets" ]
        , HH.div
            [ HP.classes [ HH.ClassName "preset-grid" ] ]
            [ presetButton "kick" "bd ~ bd ~"
            , presetButton "snare" "~ sn ~ sn"
            , presetButton "hats" "hh*4"
            , presetButton "euclid" "bd(3,8)"
            , presetButton "poly" "[bd sn, cp cp cp]"
            ]
        ]

    -- Track list
    , HH.div
        [ HP.classes [ HH.ClassName "control-section" ] ]
        [ HH.label_ [ HH.text "Tracks" ]
        , HH.ul
            [ HP.classes [ HH.ClassName "track-list" ] ]
            (Array.mapWithIndex renderTrackItem state.tracks)
        ]

    -- Tangle output
    , HH.div
        [ HP.classes [ HH.ClassName "control-section" ] ]
        [ HH.label_ [ HH.text "Tidal Code" ]
        , HH.pre
            [ HP.classes [ HH.ClassName "code-output" ] ]
            [ HH.code_ [ renderDoc TangleControl (tracksToTangleDoc state.tracks) ] ]
        ]
    ]

renderTrackItem :: forall m. Int -> Track -> H.ComponentHTML Action () m
renderTrackItem idx track =
  HH.li
    [ HP.classes $
        [ HH.ClassName "track-item" ] <>
        if track.active then [] else [ HH.ClassName "track-muted" ]
    ]
    [ HH.span
        [ HE.onClick \_ -> ToggleTrack idx
        , HP.classes [ HH.ClassName "track-name" ]
        ]
        [ HH.text track.name ]
    , HH.span
        [ HP.classes [ HH.ClassName "track-pattern" ] ]
        [ HH.text $ patternTreeToMini track.pattern ]
    ]

presetButton :: forall m. String -> String -> H.ComponentHTML Action () m
presetButton name pattern =
  HH.button
    [ HE.onClick \_ -> AddPresetPattern name pattern
    , HP.classes [ HH.ClassName "preset-btn" ]
    , HP.title pattern
    ]
    [ HH.text name ]

renderMidiControls :: forall m. State -> H.ComponentHTML Action () m
renderMidiControls state =
  HH.div
    [ HP.classes [ HH.ClassName "midi-controls" ] ]
    [ -- MIDI output selector
      HH.div
        [ HP.classes [ HH.ClassName "midi-output" ] ]
        [ HH.label_ [ HH.text "MIDI Output" ]
        , HH.select
            [ HE.onValueChange \s -> SelectMidiOutput (fromMaybe 0 $ Int.fromString s) ]
            (if Array.null state.midi.outputs
              then [ HH.option_ [ HH.text "No MIDI outputs" ] ]
              else Array.mapWithIndex (\i o ->
                HH.option [ HP.value (show i) ] [ HH.text (getOutputName o) ]
              ) state.midi.outputs
            )
        ]

    -- BPM control
    , HH.div
        [ HP.classes [ HH.ClassName "midi-bpm" ] ]
        [ HH.label_ [ HH.text "BPM" ]
        , HH.input
            [ HP.type_ HP.InputNumber
            , HP.value (show state.midi.bpm)
            , HE.onValueInput SetBPM
            , HP.min 20.0
            , HP.max 300.0
            ]
        ]

    -- Play/Stop button
    , HH.button
        [ HE.onClick \_ -> TogglePlayback
        , HP.classes [ HH.ClassName $ if state.midi.playing then "btn-stop" else "btn-play" ]
        ]
        [ HH.text $ if state.midi.playing then "◼ Stop" else "▶ Play" ]

    -- Status
    , HH.div
        [ HP.classes [ HH.ClassName "midi-status" ] ]
        [ HH.text $ if state.midi.playing
            then "Playing @ " <> show state.midi.bpm <> " BPM"
            else "Stopped"
        ]
    ]

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

-- | Toggle between tree and sunburst layout
toggleLayout :: TrackLayout -> TrackLayout
toggleLayout TreeLayout = SunburstLayout
toggleLayout SunburstLayout = TreeLayout

-- | Update array element at index
updateAt :: forall a. Int -> (a -> a) -> Array a -> Array a
updateAt idx f arr =
  case Array.index arr idx of
    Nothing -> arr
    Just elem -> fromMaybe arr $ Array.updateAt idx (f elem) arr

-- | Toggle combinator enabled state
toggleCombinator :: Int -> Array Combinator -> Array Combinator
toggleCombinator idx combs = updateAt idx (\c -> c { enabled = not c.enabled }) combs

-- | Toggle node type (Sequence↔Parallel)
toggleNodeType :: NodePath -> PatternTree -> PatternTree
toggleNodeType path tree = case Array.uncons path of
  Nothing -> case tree of
    Sequence children -> Parallel children
    Parallel children -> Sequence children
    other -> other
  Just { head: idx, tail: rest } -> case tree of
    Sequence children -> Sequence $ updateAt idx (toggleNodeType rest) children
    Parallel children -> Parallel $ updateAt idx (toggleNodeType rest) children
    Choice children -> Choice $ updateAt idx (toggleNodeType rest) children
    Fast n child -> Fast n (if idx == 0 then toggleNodeType rest child else child)
    Slow n child -> Slow n (if idx == 0 then toggleNodeType rest child else child)
    Euclidean n k child -> Euclidean n k (if idx == 0 then toggleNodeType rest child else child)
    Degrade p child -> Degrade p (if idx == 0 then toggleNodeType rest child else child)
    Repeat n child -> Repeat n (if idx == 0 then toggleNodeType rest child else child)
    Elongate n child -> Elongate n (if idx == 0 then toggleNodeType rest child else child)
    other -> other

-- | Adjust euclidean parameters
adjustEuclidean :: NodePath -> Int -> Int -> PatternTree -> PatternTree
adjustEuclidean path deltaN deltaK tree = case Array.uncons path of
  Nothing -> case tree of
    Euclidean n k child ->
      let newN = max 1 (n + deltaN)
          newK = max newN (k + deltaK)
      in Euclidean newN newK child
    other -> other
  Just { head: idx, tail: rest } -> case tree of
    Sequence children -> Sequence $ updateAt idx (adjustEuclidean rest deltaN deltaK) children
    Parallel children -> Parallel $ updateAt idx (adjustEuclidean rest deltaN deltaK) children
    Choice children -> Choice $ updateAt idx (adjustEuclidean rest deltaN deltaK) children
    Fast n child -> Fast n (if idx == 0 then adjustEuclidean rest deltaN deltaK child else child)
    Slow n child -> Slow n (if idx == 0 then adjustEuclidean rest deltaN deltaK child else child)
    Euclidean n k child -> Euclidean n k (if idx == 0 then adjustEuclidean rest deltaN deltaK child else child)
    Degrade p child -> Degrade p (if idx == 0 then adjustEuclidean rest deltaN deltaK child else child)
    Repeat n child -> Repeat n (if idx == 0 then adjustEuclidean rest deltaN deltaK child else child)
    Elongate n child -> Elongate n (if idx == 0 then adjustEuclidean rest deltaN deltaK child else child)
    other -> other

-- | Handle Tangle control actions
handleTangleAction :: forall o m. MonadAff m => ControlAction -> H.HalogenM State Action () o m Unit
handleTangleAction = case _ of
  ToggleClicked id newValue -> do
    liftEffect $ Console.log $ "Tangle toggle: " <> id
    case parseTangleId "mute-" id of
      Just trackIdx -> do
        H.modify_ \s -> s { tracks = updateAt trackIdx (\t -> t { active = newValue }) s.tracks }
        handleAction RenderForest
        handleAction UpdateSchedulerPattern
      Nothing -> pure unit

  AdjustChanged id newValue -> do
    liftEffect $ Console.log $ "Tangle adjust: " <> id <> " -> " <> show newValue
    pure unit

  CycleClicked _ _ -> pure unit
  ActionClicked _ _ -> pure unit
  AdjustDragStart dragInfo -> do
    subscriptionId <- H.subscribe (dragEventSource DragMove DragEnd)
    H.modify_ \s -> s
      { adjustDrag = Just
          { id: dragInfo.id
          , startValue: dragInfo.startValue
          , startX: dragInfo.startX
          , step: dragInfo.step
          , min: dragInfo.min
          , max: dragInfo.max
          , subscriptionId
          }
      }

-- | Handle drag movement
handleDragMove :: forall o m. MonadAff m => Int -> H.HalogenM State Action () o m Unit
handleDragMove _ = pure unit

-- | Handle drag end
handleDragEnd :: forall o m. MonadAff m => H.HalogenM State Action () o m Unit
handleDragEnd = do
  state <- H.get
  case state.adjustDrag of
    Nothing -> pure unit
    Just dragInfo -> do
      H.unsubscribe dragInfo.subscriptionId
      H.modify_ \s -> s { adjustDrag = Nothing }

-- | Parse Tangle ID with prefix
parseTangleId :: String -> String -> Maybe Int
parseTangleId prefix id =
  if String.take (String.length prefix) id == prefix
    then Int.fromString (String.drop (String.length prefix) id)
    else Nothing

-------------------------------------------------------------------------------
-- Entry point
-------------------------------------------------------------------------------

main :: Effect Unit
main = HA.runHalogenAff do
  body <- HA.awaitBody
  runUI component unit body
