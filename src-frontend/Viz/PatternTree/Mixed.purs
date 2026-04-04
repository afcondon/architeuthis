module D3.Viz.PatternTree.Mixed
  ( drawPatternForestMixed
  ) where

import Prelude

import Component.PatternTree (PatternTree, PatternMetrics, analyzePattern)
import Data.Array as Array
import Data.Int as Int
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Number (pi, cos, sin, sqrt)
import DataViz.Layout.Hierarchy.Partition (PartitionNode(..), defaultPartitionConfig, hierarchy, partition, sunburstArcPath, flattenPartition, fixParallelLayout)
import DataViz.Layout.Hierarchy.Tree (tree, defaultTreeConfig)
import Effect (Effect)
import Effect.Console as Console
import Hylograph.HATS (Tree, elem, forEach, staticNum, staticStr, thunkedNum, thunkedStr, withBehaviors, onClick, onZoom) as H
import Hylograph.HATS.InterpreterTick (rerender)
import Hylograph.Internal.Behavior.FFI (attachZoomWithCallback_)
import Hylograph.Internal.Behavior.Types (ScaleExtent(..), ZoomConfig(..))
import Hylograph.Internal.Selection.Types (ElementType(..))
import Web.DOM.NonElementParentNode (getElementById)
import Web.HTML as Web.HTML
import Web.HTML.HTMLDocument as HTMLDocument
import Web.HTML.Window as Window
import D3.Viz.PatternTree.Types (PatternNode, LinkDatum, TrackLayout(..), TrackWithLayout, ZoomTransform)
import D3.Viz.PatternTree.Layout (patternTreeToTree, makeLinks, nodeColor)
import D3.Viz.PatternTree.Euclidean (parseEuclideanLabel, euclideanPattern)
import D3.Viz.PatternTree.Sunburst (patternToHierarchy, sunburstColor, sunburstFill, sunburstStroke, combinatorBadge, isCombinator, HierarchyNodeData)

-- | Draw patterns with per-track layout (tree or sunburst)
-- | onToggleActive: called when center is clicked (toggle mute)
-- | onToggleLayout: called when outer ring is clicked (toggle layout)
-- | initialZoom: zoom transform to restore (use identityZoom if none)
-- | onZoomChange: called when zoom changes (to save state for next render)
drawPatternForestMixed :: String -> Array TrackWithLayout -> (Int -> Effect Unit) -> (Int -> Effect Unit) -> (Int -> Array Int -> Effect Unit) -> (Int -> Array Int -> Int -> Int -> Effect Unit) -> ZoomTransform -> (ZoomTransform -> Effect Unit) -> Effect Unit
drawPatternForestMixed selector tracksWithLayout onToggleActive onToggleLayout onToggleNodeType onAdjustEuclidean initialZoom onZoomChange = do
  Console.log "[Mixed.purs v2] drawPatternForestMixed called - buttons should be visible below tracks"
  let numPatterns = Array.length tracksWithLayout
  let chartWidth = 1400.0
  let chartHeight = 1200.0

  -- Grid layout: determine columns and rows
  let cols = max 1 (min 5 (Int.ceil (sqrt (Int.toNumber numPatterns))))
  let rows = Int.ceil (Int.toNumber numPatterns / Int.toNumber cols)

  -- Calculate size for each pattern based on grid
  let cellWidth = (chartWidth - 100.0) / Int.toNumber cols
  let cellHeight = (chartHeight - 200.0) / Int.toNumber rows
  let patternSize = min 200.0 (min cellWidth cellHeight * 0.85)
  let radius = patternSize / 2.0

  -- Starting position (centered in available space)
  let gridWidth = Int.toNumber cols * cellWidth
  let startX = (chartWidth - gridWidth) / 2.0 + cellWidth / 2.0
  let startY = 150.0 + cellHeight / 2.0

  -- Process each track to get positioned data
  let processTrack idx track =
        let col = idx `mod` cols
            row = idx / cols
            centerX = startX + Int.toNumber col * cellWidth
            centerY = startY + Int.toNumber row * cellHeight
            arcOpacity = if track.active then 0.85 else 0.25
        in { idx, track, centerX, centerY, radius, arcOpacity }

  let processedTracks = Array.mapWithIndex processTrack tracksWithLayout

  -- Build the complete visualization tree
  let
    vizTree :: H.Tree
    vizTree =
      H.elem SVG
        [ H.staticNum "width" chartWidth
        , H.staticNum "height" chartHeight
        , H.staticStr "viewBox" ("0 0 " <> show chartWidth <> " " <> show chartHeight)
        , H.staticStr "class" "pattern-forest-viz pattern-forest-mixed"
        , H.staticStr "id" "pattern-mixed-svg"
        ]
        [ -- Pattern definitions
          patternDefs
        , -- Zoom group
          H.elem Group
            [ H.staticStr "id" "pattern-mixed-zoom-group"
            , H.staticStr "class" "zoom-group"
            ]
            -- Render each track based on its layout
            (Array.concatMap (\pt -> case pt.track.layout of
              SunburstLayout -> renderSunburstTrack pt onToggleActive onToggleLayout onToggleNodeType onAdjustEuclidean
              TreeLayout -> renderTreeTrack pt onToggleActive onToggleLayout onToggleNodeType
            ) processedTracks)
        ]

  _ <- rerender selector vizTree

  -- Attach zoom behavior after rendering (to preserve state)
  doc <- Web.HTML.window >>= Window.document
  let node = HTMLDocument.toNonElementParentNode doc
  maybeSvg <- getElementById "pattern-mixed-svg" node
  case maybeSvg of
    Just svgElem -> do
      _ <- attachZoomWithCallback_ svgElem 0.1 10.0 "#pattern-mixed-zoom-group" initialZoom onZoomChange
      pure unit
    Nothing -> pure unit

-- | Processed track data for rendering
type ProcessedTrack =
  { idx :: Int
  , track :: TrackWithLayout
  , centerX :: Number
  , centerY :: Number
  , radius :: Number
  , arcOpacity :: Number
  }

-- | Render a single track as sunburst
renderSunburstTrack :: ProcessedTrack -> (Int -> Effect Unit) -> (Int -> Effect Unit) -> (Int -> Array Int -> Effect Unit) -> (Int -> Array Int -> Int -> Int -> Effect Unit) -> Array H.Tree
renderSunburstTrack pt onToggleActive onToggleLayout onToggleNodeType onAdjustEuclidean =
  let
    track = pt.track
    hierData = patternToHierarchy track.pattern
    partRoot = hierarchy hierData
    config = defaultPartitionConfig { size = { width: 1.0, height: 1.0 }, padding = 0.002 }
    partitioned = partition config partRoot
    fixedPartitioned = fixParallelLayout (\d -> d.nodeType == "parallel") partitioned
    allNodes = flattenPartition fixedPartitioned
    nodes = Array.filter (\(PartNode n) -> n.depth > 0) allNodes

    innerRadius = pt.radius * 0.35
    rootNode = Array.find (\(PartNode n) -> n.depth == 0) allNodes
    rootType = case rootNode of
      Just (PartNode n) -> n.data_.nodeType
      Nothing -> "sequence"
    centerBg = if track.active then sunburstColor rootType else "#f5f5f5"
    centerStroke = if track.active then "#fff" else "#ccc"
    centerTextColor = if track.active then "#fff" else "#999"

    combinatorNodes = Array.filter (\(PartNode n) -> isCombinator n.data_.nodeType) nodes
    euclideanNodes = Array.filter (\(PartNode n) -> n.data_.nodeType == "euclidean") allNodes
    metrics = analyzePattern track.pattern
    buttonY = pt.centerY + pt.radius + 25.0
  in
    [ -- Arcs
      H.elem Group
        [ H.staticStr "transform" ("translate(" <> show pt.centerX <> "," <> show pt.centerY <> ")") ]
        [ H.forEach ("arcs-" <> show pt.idx) Group nodes arcKey \(PartNode node) ->
            let
              strokeStyle = sunburstStroke node.data_.nodeType
              isToggleable = node.data_.nodeType == "sequence" || node.data_.nodeType == "parallel"
              arcElem = H.elem Path
                [ H.thunkedStr "d" (sunburstArcPath node.x0 node.y0 node.x1 node.y1 pt.radius)
                , H.thunkedStr "fill" (sunburstFill node.data_.nodeType)
                , H.thunkedNum "fill-opacity" pt.arcOpacity
                , H.thunkedStr "stroke" strokeStyle.color
                , H.thunkedNum "stroke-width" strokeStyle.width
                , H.thunkedStr "stroke-dasharray" strokeStyle.dashArray
                , H.thunkedStr "class" ("arc arc-" <> node.data_.nodeType <> if isToggleable then " arc-toggleable" else "")
                ]
                []
            in if isToggleable
               then H.withBehaviors [ H.onClick (onToggleNodeType track.trackIndex node.data_.path) ] $
                      H.elem Group [ H.staticStr "style" "cursor: pointer;" ] [ arcElem ]
               else arcElem
        ]
    , -- Combinator badges (when active)
      if track.active then
        H.elem Group
          [ H.staticStr "transform" ("translate(" <> show pt.centerX <> "," <> show pt.centerY <> ")") ]
          [ H.forEach ("badges-" <> show pt.idx) Text combinatorNodes badgeKey \(PartNode node) ->
              let
                midAngle = ((node.x0 + node.x1) / 2.0) * 2.0 * pi - (pi / 2.0)
                midRadius = ((node.y0 + node.y1) / 2.0) * pt.radius
                labelX = cos midAngle * midRadius
                labelY = sin midAngle * midRadius
                badgeText = fromMaybe "" (combinatorBadge node.data_.nodeType)
              in
                H.elem Text
                  [ H.thunkedNum "x" labelX
                  , H.thunkedNum "y" labelY
                  , H.thunkedStr "textContent" badgeText
                  , H.staticNum "font-size" 8.0
                  , H.staticStr "text-anchor" "middle"
                  , H.staticStr "dominant-baseline" "middle"
                  , H.staticStr "fill" "#fff"
                  , H.staticStr "font-weight" "bold"
                  , H.staticStr "class" "combinator-badge"
                  , H.staticStr "pointer-events" "none"
                  ]
                  []
          ]
      else H.elem Group [] []
    , -- Euclidean visualization (when active)
      if track.active then
        H.elem Group []
          (Array.concatMap (\(PartNode node) ->
            let
              nk = parseEuclideanLabel node.data_.label
              pattern = euclideanPattern nk.n nk.k
              ringRadius = node.y1 * pt.radius
              beatCircleRadius = max 4.0 (min 8.0 (pt.radius * 0.06))
              beatCircles = Array.mapWithIndex (\i isHit ->
                let angle = (Int.toNumber i / Int.toNumber nk.k) * 2.0 * pi - (pi / 2.0)
                    cx' = cos angle * ringRadius
                    cy' = sin angle * ringRadius
                    fillColor = if isHit then "#fff" else "rgba(255,255,255,0.3)"
                    strokeColor = if isHit then "#2E7D32" else "#81C784"
                    sw = if isHit then 3.0 else 1.5
                in { cx: cx', cy: cy', fill: fillColor, stroke: strokeColor, strokeWidth: sw }
              ) pattern
            in
              [ H.elem Group
                  [ H.staticStr "transform" ("translate(" <> show pt.centerX <> "," <> show pt.centerY <> ")")
                  , H.staticStr "class" "euclid-viz"
                  ]
                  [ H.forEach ("euclid-beats-" <> show pt.idx) Circle beatCircles beatKey \beat ->
                      H.elem Circle
                        [ H.thunkedNum "cx" beat.cx
                        , H.thunkedNum "cy" beat.cy
                        , H.thunkedNum "r" beatCircleRadius
                        , H.thunkedStr "fill" beat.fill
                        , H.thunkedStr "stroke" beat.stroke
                        , H.thunkedNum "stroke-width" beat.strokeWidth
                        ]
                        []
                  ]
              ]
          ) euclideanNodes)
      else H.elem Group [] []
    , -- Center circle (clickable)
      H.withBehaviors [ H.onClick (onToggleActive track.trackIndex) ] $
        H.elem Group
          [ H.staticStr "transform" ("translate(" <> show pt.centerX <> "," <> show pt.centerY <> ")")
          , H.staticStr "class" "sunburst-center"
          , H.staticStr "style" "cursor: pointer;"
          ]
          [ H.elem Circle
              [ H.staticNum "cx" 0.0
              , H.staticNum "cy" 0.0
              , H.thunkedNum "r" innerRadius
              , H.thunkedStr "fill" centerBg
              , H.thunkedStr "stroke" centerStroke
              , H.staticNum "stroke-width" 2.0
              ]
              []
          , H.elem Text
              [ H.staticNum "x" 0.0
              , H.staticNum "y" 4.0
              , H.thunkedStr "textContent" track.name
              , H.staticNum "font-size" 12.0
              , H.staticStr "text-anchor" "middle"
              , H.thunkedStr "fill" centerTextColor
              , H.staticStr "font-weight" "600"
              ]
              []
          ]
    , -- Euclidean controls (when active)
      if track.active && Array.length euclideanNodes > 0 then
        H.elem Group []
          (Array.concatMap (\(PartNode node) ->
            let
              nk = parseEuclideanLabel node.data_.label
              btnSize = 7.0
              btnSpacing = 18.0
            in
              [ H.elem Group
                  [ H.staticStr "transform" ("translate(" <> show pt.centerX <> "," <> show pt.centerY <> ")")
                  , H.staticStr "class" "euclid-controls"
                  ]
                  [ -- n/k label
                    H.elem Text
                      [ H.staticNum "x" 0.0
                      , H.staticNum "y" (-22.0)
                      , H.thunkedStr "textContent" (show nk.n <> "/" <> show nk.k)
                      , H.staticNum "font-size" 10.0
                      , H.staticStr "text-anchor" "middle"
                      , H.staticStr "fill" "#4CAF50"
                      , H.staticStr "font-weight" "bold"
                      ]
                      []
                  , -- +n button (top)
                    H.withBehaviors [ H.onClick (onAdjustEuclidean track.trackIndex node.data_.path 1 0) ] $
                      H.elem Group
                        [ H.staticStr "transform" ("translate(0," <> show (-btnSpacing * 0.6) <> ")")
                        , H.staticStr "style" "cursor: pointer;"
                        ]
                        [ H.elem Circle [ H.staticNum "cx" 0.0, H.staticNum "cy" 0.0, H.thunkedNum "r" btnSize, H.staticStr "fill" "#e8f5e9", H.staticStr "stroke" "#4CAF50", H.staticNum "stroke-width" 1.5 ] []
                        , H.elem Text [ H.staticNum "x" 0.0, H.staticNum "y" 2.5, H.staticStr "textContent" "+n", H.staticNum "font-size" 6.0, H.staticStr "text-anchor" "middle", H.staticStr "fill" "#4CAF50", H.staticStr "font-weight" "bold" ] []
                        ]
                  , -- -n button (bottom)
                    H.withBehaviors [ H.onClick (onAdjustEuclidean track.trackIndex node.data_.path (-1) 0) ] $
                      H.elem Group
                        [ H.staticStr "transform" ("translate(0," <> show (btnSpacing * 0.6) <> ")")
                        , H.staticStr "style" "cursor: pointer;"
                        ]
                        [ H.elem Circle [ H.staticNum "cx" 0.0, H.staticNum "cy" 0.0, H.thunkedNum "r" btnSize, H.staticStr "fill" "#ffebee", H.staticStr "stroke" "#f44336", H.staticNum "stroke-width" 1.5 ] []
                        , H.elem Text [ H.staticNum "x" 0.0, H.staticNum "y" 2.5, H.staticStr "textContent" "-n", H.staticNum "font-size" 6.0, H.staticStr "text-anchor" "middle", H.staticStr "fill" "#f44336", H.staticStr "font-weight" "bold" ] []
                        ]
                  , -- +k button (right)
                    H.withBehaviors [ H.onClick (onAdjustEuclidean track.trackIndex node.data_.path 0 1) ] $
                      H.elem Group
                        [ H.staticStr "transform" ("translate(" <> show btnSpacing <> ",0)")
                        , H.staticStr "style" "cursor: pointer;"
                        ]
                        [ H.elem Circle [ H.staticNum "cx" 0.0, H.staticNum "cy" 0.0, H.thunkedNum "r" btnSize, H.staticStr "fill" "#e3f2fd", H.staticStr "stroke" "#2196F3", H.staticNum "stroke-width" 1.5 ] []
                        , H.elem Text [ H.staticNum "x" 0.0, H.staticNum "y" 2.5, H.staticStr "textContent" "+k", H.staticNum "font-size" 6.0, H.staticStr "text-anchor" "middle", H.staticStr "fill" "#2196F3", H.staticStr "font-weight" "bold" ] []
                        ]
                  , -- -k button (left)
                    H.withBehaviors [ H.onClick (onAdjustEuclidean track.trackIndex node.data_.path 0 (-1)) ] $
                      H.elem Group
                        [ H.staticStr "transform" ("translate(" <> show (-btnSpacing) <> ",0)")
                        , H.staticStr "style" "cursor: pointer;"
                        ]
                        [ H.elem Circle [ H.staticNum "cx" 0.0, H.staticNum "cy" 0.0, H.thunkedNum "r" btnSize, H.staticStr "fill" "#fff3e0", H.staticStr "stroke" "#FF9800", H.staticNum "stroke-width" 1.5 ] []
                        , H.elem Text [ H.staticNum "x" 0.0, H.staticNum "y" 2.5, H.staticStr "textContent" "-k", H.staticNum "font-size" 6.0, H.staticStr "text-anchor" "middle", H.staticStr "fill" "#FF9800", H.staticStr "font-weight" "bold" ] []
                        ]
                  ]
              ]
          ) euclideanNodes)
      else H.elem Group [] []
    , -- Mute button
      renderMuteButton (pt.centerX - 20.0) buttonY track.trackIndex track.active onToggleActive
    , -- Layout toggle button
      renderToggleButton (pt.centerX + 20.0) buttonY track.trackIndex onToggleLayout "tree"
    , -- Metrics
      renderMetrics pt.centerX (buttonY + 18.0) metrics track.active pt.idx
    ]
  where
  arcKey (PartNode n) = show n.depth <> "-" <> show n.x0
  badgeKey (PartNode n) = n.data_.label <> "-" <> show n.x0
  beatKey b = show b.cx <> "-" <> show b.cy

-- | Render a single track as vertical tree
renderTreeTrack :: ProcessedTrack -> (Int -> Effect Unit) -> (Int -> Effect Unit) -> (Int -> Array Int -> Effect Unit) -> Array H.Tree
renderTreeTrack pt onToggleActive onToggleLayout onToggleNodeType =
  let
    track = pt.track
    dataTree = patternTreeToTree track.pattern
    treeWidth = pt.radius * 1.6
    treeHeight = pt.radius * 1.2
    treeConfig = defaultTreeConfig { size = { width: treeWidth, height: treeHeight } }
    positioned = tree treeConfig dataTree
    nodes = Array.fromFoldable positioned
    links = makeLinks positioned

    offsetX = pt.centerX - treeWidth / 2.0
    offsetY = pt.centerY - pt.radius + 20.0

    combinatorNodes = Array.filter (\n -> isCombinator n.nodeType) nodes
    metrics = analyzePattern track.pattern
    buttonY = pt.centerY + pt.radius + 15.0
  in
    [ -- Links
      H.elem Group
        [ H.staticStr "transform" ("translate(" <> show offsetX <> "," <> show offsetY <> ")") ]
        [ H.forEach ("tree-links-" <> show pt.idx) Path links linkKey \link ->
            H.elem Path
              [ H.thunkedStr "d" (verticalLinkPath link.source.x link.source.y link.target.x link.target.y)
              , H.staticStr "fill" "none"
              , H.staticStr "stroke" "#ccc"
              , H.staticNum "stroke-width" 2.0
              , H.thunkedNum "opacity" pt.arcOpacity
              ]
              []
        ]
    , -- Nodes
      H.elem Group
        [ H.staticStr "transform" ("translate(" <> show offsetX <> "," <> show offsetY <> ")") ]
        [ H.forEach ("tree-nodes-" <> show pt.idx) Group nodes nodeKey \node ->
            let
              isToggleable = node.nodeType == "sequence" || node.nodeType == "parallel"
              nodeContent = H.elem Group
                [ H.thunkedStr "class" (if isToggleable then "node-toggleable" else "")
                , H.thunkedStr "style" (if isToggleable then "cursor: pointer;" else "")
                ]
                [ H.elem Circle
                    [ H.thunkedNum "cx" node.x
                    , H.thunkedNum "cy" node.y
                    , H.staticNum "r" 8.0
                    , H.thunkedStr "fill" (nodeColor node.nodeType)
                    , H.staticStr "stroke" "#fff"
                    , H.staticNum "stroke-width" 2.0
                    , H.thunkedNum "opacity" pt.arcOpacity
                    ]
                    []
                , H.elem Text
                    [ H.thunkedNum "x" node.x
                    , H.thunkedNum "y" (node.y - 12.0)
                    , H.thunkedStr "textContent" node.label
                    , H.staticNum "font-size" 10.0
                    , H.staticStr "text-anchor" "middle"
                    , H.thunkedStr "fill" (if track.active then "#000" else "#999")
                    ]
                    []
                ]
            in if isToggleable
               then H.withBehaviors [ H.onClick (onToggleNodeType track.trackIndex node.path) ] nodeContent
               else nodeContent
        ]
    , -- Combinator badges (when active)
      if track.active then
        H.elem Group
          [ H.staticStr "transform" ("translate(" <> show offsetX <> "," <> show offsetY <> ")") ]
          [ H.forEach ("tree-badges-" <> show pt.idx) Text combinatorNodes nodeKey \node ->
              let badgeText = fromMaybe "" (combinatorBadge node.nodeType)
              in H.elem Text
                [ H.thunkedNum "x" node.x
                , H.thunkedNum "y" (node.y + 18.0)
                , H.thunkedStr "textContent" badgeText
                , H.staticNum "font-size" 7.0
                , H.staticStr "text-anchor" "middle"
                , H.thunkedStr "fill" (sunburstColor node.nodeType)
                , H.staticStr "font-weight" "bold"
                , H.staticStr "class" "combinator-badge-tree"
                ]
                []
          ]
      else H.elem Group [] []
    , -- Track label (clickable)
      H.withBehaviors [ H.onClick (onToggleActive track.trackIndex) ] $
        H.elem Group
          [ H.staticStr "transform" ("translate(" <> show pt.centerX <> "," <> show (pt.centerY - pt.radius - 5.0) <> ")")
          , H.staticStr "style" "cursor: pointer;"
          ]
          [ H.elem Text
              [ H.staticNum "x" 0.0
              , H.staticNum "y" 0.0
              , H.thunkedStr "textContent" track.name
              , H.staticNum "font-size" 12.0
              , H.staticStr "text-anchor" "middle"
              , H.thunkedStr "fill" (if track.active then "#333" else "#999")
              , H.staticStr "font-weight" "600"
              ]
              []
          ]
    , -- Mute button
      renderMuteButton (pt.centerX - 20.0) buttonY track.trackIndex track.active onToggleActive
    , -- Layout toggle button
      renderToggleButton (pt.centerX + 20.0) buttonY track.trackIndex onToggleLayout "sunburst"
    , -- Metrics
      renderMetrics pt.centerX (buttonY + 18.0) metrics track.active pt.idx
    ]
  where
  linkKey link = show link.source.x <> "-" <> show link.target.x
  nodeKey node = node.label

-- | Vertical link path (cubic bezier from top to bottom)
verticalLinkPath :: Number -> Number -> Number -> Number -> String
verticalLinkPath sx sy tx ty =
  let midY = (sy + ty) / 2.0
  in "M" <> show sx <> "," <> show sy
     <> " C" <> show sx <> "," <> show midY
     <> " " <> show tx <> "," <> show midY
     <> " " <> show tx <> "," <> show ty

-- | Render a toggle button for layout switching
renderToggleButton :: Number -> Number -> Int -> (Int -> Effect Unit) -> String -> H.Tree
renderToggleButton btnX btnY trackIdx onToggle targetLayout =
  H.withBehaviors [ H.onClick (onToggle trackIdx) ] $
    H.elem Group
      [ H.staticStr "transform" ("translate(" <> show btnX <> "," <> show btnY <> ")")
      , H.staticStr "style" "cursor: pointer;"
      , H.staticStr "class" "layout-toggle-btn"
      ]
      [ H.elem Circle
          [ H.staticNum "cx" 0.0
          , H.staticNum "cy" 0.0
          , H.staticNum "r" 14.0
          , H.staticStr "fill" "#e3f2fd"
          , H.staticStr "stroke" "#2196f3"
          , H.staticNum "stroke-width" 2.0
          ]
          []
      , H.elem Text
          [ H.staticNum "x" 0.0
          , H.staticNum "y" 5.0
          , H.staticStr "textContent" (if targetLayout == "sunburst" then "◉" else "⬡")
          , H.staticNum "font-size" 14.0
          , H.staticStr "text-anchor" "middle"
          , H.staticStr "fill" "#1565c0"
          , H.staticStr "font-weight" "bold"
          ]
          []
      ]

-- | Render a mute/unmute button with speaker icon
renderMuteButton :: Number -> Number -> Int -> Boolean -> (Int -> Effect Unit) -> H.Tree
renderMuteButton btnX btnY trackIdx isActive onToggle =
  let speakerIcon = if isActive then "🔊" else "🔇"
  in
    H.withBehaviors [ H.onClick (onToggle trackIdx) ] $
      H.elem Group
        [ H.staticStr "transform" ("translate(" <> show btnX <> "," <> show btnY <> ")")
        , H.staticStr "style" "cursor: pointer;"
        , H.staticStr "class" "mute-toggle-btn"
        ]
        [ H.elem Circle
            [ H.staticNum "cx" 0.0
            , H.staticNum "cy" 0.0
            , H.staticNum "r" 14.0
            , H.staticStr "fill" (if isActive then "#e8f5e9" else "#ffebee")
            , H.staticStr "stroke" (if isActive then "#4CAF50" else "#f44336")
            , H.staticNum "stroke-width" 2.0
            ]
            []
        , H.elem Text
            [ H.staticNum "x" 0.0
            , H.staticNum "y" 5.0
            , H.staticStr "textContent" speakerIcon
            , H.staticNum "font-size" 12.0
            , H.staticStr "text-anchor" "middle"
            , H.staticStr "fill" (if isActive then "#2e7d32" else "#c62828")
            ]
            []
        ]

-- | Render pattern metrics as a small info line
renderMetrics :: Number -> Number -> PatternMetrics -> Boolean -> Int -> H.Tree
renderMetrics metricsX metricsY metrics isActive idx =
  let
    densityPct = Int.round (metrics.density * 100.0)
    speedStr = if metrics.speedFactor == 1.0 then ""
               else if metrics.speedFactor > 1.0 then " ×" <> show (Int.round metrics.speedFactor)
               else " ÷" <> show (Int.round (1.0 / metrics.speedFactor))
    polyStr = if metrics.maxPolyphony > 1 then " ♪" <> show metrics.maxPolyphony else ""
    flagsStr = (if metrics.hasEuclidean then " E" else "")
            <> (if metrics.hasProbability then " ?" else "")
    metricsStr = show metrics.events <> "/" <> show metrics.slots
              <> " (" <> show densityPct <> "%)"
              <> polyStr <> speedStr <> flagsStr
  in
    H.elem Group
      [ H.staticStr "transform" ("translate(" <> show metricsX <> "," <> show metricsY <> ")") ]
      [ H.elem Text
          [ H.staticNum "x" 0.0
          , H.staticNum "y" 0.0
          , H.staticStr "textContent" metricsStr
          , H.staticNum "font-size" 9.0
          , H.staticStr "text-anchor" "middle"
          , H.staticStr "fill" (if isActive then "#666" else "#aaa")
          , H.staticStr "font-family" "monospace"
          , H.staticStr "class" "pattern-metrics"
          ]
          []
      ]

-- | Pattern definitions for combinator visual treatment
patternDefs :: H.Tree
patternDefs =
  H.elem Defs []
    [ H.elem PatternFill
        [ H.staticStr "id" "fastPattern"
        , H.staticStr "patternUnits" "userSpaceOnUse"
        , H.staticNum "width" 6.0
        , H.staticNum "height" 6.0
        , H.staticStr "patternTransform" "rotate(45)"
        ]
        [ H.elem Rect [ H.staticNum "width" 3.0, H.staticNum "height" 6.0, H.staticStr "fill" "#E91E63" ] []
        , H.elem Rect [ H.staticNum "x" 3.0, H.staticNum "width" 3.0, H.staticNum "height" 6.0, H.staticStr "fill" "#F48FB1" ] []
        ]
    , H.elem PatternFill
        [ H.staticStr "id" "slowPattern"
        , H.staticStr "patternUnits" "userSpaceOnUse"
        , H.staticNum "width" 8.0
        , H.staticNum "height" 8.0
        ]
        [ H.elem Rect [ H.staticNum "width" 8.0, H.staticNum "height" 4.0, H.staticStr "fill" "#00BCD4" ] []
        , H.elem Rect [ H.staticNum "y" 4.0, H.staticNum "width" 8.0, H.staticNum "height" 4.0, H.staticStr "fill" "#4DD0E1" ] []
        ]
    , H.elem PatternFill
        [ H.staticStr "id" "euclidPattern"
        , H.staticStr "patternUnits" "userSpaceOnUse"
        , H.staticNum "width" 10.0
        , H.staticNum "height" 10.0
        ]
        [ H.elem Rect [ H.staticNum "width" 10.0, H.staticNum "height" 10.0, H.staticStr "fill" "#FFEB3B" ] []
        , H.elem Circle [ H.staticNum "cx" 5.0, H.staticNum "cy" 5.0, H.staticNum "r" 2.5, H.staticStr "fill" "#FFF176" ] []
        ]
    , H.elem PatternFill
        [ H.staticStr "id" "degradePattern"
        , H.staticStr "patternUnits" "userSpaceOnUse"
        , H.staticNum "width" 8.0
        , H.staticNum "height" 8.0
        ]
        [ H.elem Rect [ H.staticNum "width" 8.0, H.staticNum "height" 8.0, H.staticStr "fill" "#795548" ] []
        , H.elem Rect [ H.staticNum "width" 4.0, H.staticNum "height" 4.0, H.staticStr "fill" "#A1887F" ] []
        , H.elem Rect [ H.staticNum "x" 4.0, H.staticNum "y" 4.0, H.staticNum "width" 4.0, H.staticNum "height" 4.0, H.staticStr "fill" "#A1887F" ] []
        ]
    , H.elem PatternFill
        [ H.staticStr "id" "repeatPattern"
        , H.staticStr "patternUnits" "userSpaceOnUse"
        , H.staticNum "width" 6.0
        , H.staticNum "height" 6.0
        ]
        [ H.elem Rect [ H.staticNum "width" 3.0, H.staticNum "height" 6.0, H.staticStr "fill" "#673AB7" ] []
        , H.elem Rect [ H.staticNum "x" 3.0, H.staticNum "width" 3.0, H.staticNum "height" 6.0, H.staticStr "fill" "#9575CD" ] []
        ]
    , H.elem PatternFill
        [ H.staticStr "id" "elongatePattern"
        , H.staticStr "patternUnits" "userSpaceOnUse"
        , H.staticNum "width" 12.0
        , H.staticNum "height" 4.0
        ]
        [ H.elem Rect [ H.staticNum "width" 12.0, H.staticNum "height" 4.0, H.staticStr "fill" "#009688" ] []
        , H.elem Rect [ H.staticNum "width" 4.0, H.staticNum "height" 4.0, H.staticStr "fill" "#4DB6AC" ] []
        , H.elem Rect [ H.staticNum "x" 8.0, H.staticNum "width" 4.0, H.staticNum "height" 4.0, H.staticStr "fill" "#4DB6AC" ] []
        ]
    ]
