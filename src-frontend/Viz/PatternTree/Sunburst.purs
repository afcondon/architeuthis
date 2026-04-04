module D3.Viz.PatternTree.Sunburst
  ( drawPatternForestSunburst
  , patternToHierarchy
  , sunburstColor
  , sunburstFill
  , sunburstStroke
  , combinatorBadge
  , isCombinator
  , HierarchyNodeData
  ) where

import Prelude

import Component.PatternTree (PatternTree(..))
import Data.Array as Array
import Data.Int as Int
import Data.Maybe (Maybe(..))
import Data.Number (cos, pi, sin, sqrt)
import DataViz.Layout.Hierarchy.Partition (HierarchyData(..), PartitionNode(..), defaultPartitionConfig, hierarchy, partition, sunburstArcPath, flattenPartition, fixParallelLayout)
import Effect (Effect)
import Hylograph.HATS (Tree, elem, forEach, staticNum, staticStr, thunkedNum, thunkedStr, withBehaviors, onClick, onZoom) as H
import Hylograph.HATS.InterpreterTick (rerender)
import Hylograph.Internal.Behavior.Types (ScaleExtent(..), ZoomConfig(..))
import Hylograph.Internal.Selection.Types (ElementType(..))

-- | Hierarchy node data with path for click handling
type HierarchyNodeData =
  { label :: String
  , nodeType :: String
  , path :: Array Int  -- Path from root (for click handling)
  }

-- | Convert PatternTree to HierarchyData for partition layout
-- | This does SEMANTIC expansion - Fast/Repeat are expanded to show subdivisions
-- | The weight parameter ensures subdivisions get proportional space
patternToHierarchy :: PatternTree -> HierarchyData HierarchyNodeData
patternToHierarchy pattern =
  -- Wrap single sounds/rests in a sequence so they show as full ring
  case pattern of
    Sound _ -> go [] 1.0 (Sequence [pattern])
    Rest -> go [] 1.0 (Sequence [pattern])
    _ -> go [] 1.0 pattern
  where
  -- Helper: is this pattern a container (has structural children)?
  isContainer :: PatternTree -> Boolean
  isContainer = case _ of
    Sound _ -> false
    Rest -> false
    _ -> true  -- All others are containers

  -- weight: the time value each leaf should have (1.0 normally, subdivided inside Fast/Repeat)
  go :: Array Int -> Number -> PatternTree -> HierarchyData HierarchyNodeData
  go currentPath weight = case _ of
    Sound s ->
      HierarchyData
        { data_: { label: s, nodeType: "sound", path: currentPath }
        , value: Just weight  -- Use inherited weight for proper proportions
        , children: Nothing
        }

    Rest ->
      HierarchyData
        { data_: { label: "~", nodeType: "rest", path: currentPath }
        , value: Just weight
        , children: Nothing
        }

    Sequence children ->
      let
        -- Check if any siblings are containers - if so, wrap leaves in spacers
        hasContainers = Array.any isContainer children
        processChild i c =
          if hasContainers && not (isContainer c)
          then -- Wrap leaf in transparent spacer to push it to same depth as container contents
            HierarchyData
              { data_: { label: "", nodeType: "spacer", path: currentPath <> [i] }
              , value: Nothing  -- Will inherit from child
              , children: Just [ go (currentPath <> [i, 0]) weight c ]
              }
          else go (currentPath <> [i]) weight c
      in
        HierarchyData
          { data_: { label: "seq", nodeType: "sequence", path: currentPath }
          , value: Nothing  -- Will sum children
          , children: Just $ Array.mapWithIndex processChild children
          }

    Parallel children ->
      HierarchyData
        { data_: { label: "par", nodeType: "parallel", path: currentPath }
        , value: Just weight  -- Parallel = same time slot (simultaneous)
        , children: Just $ Array.mapWithIndex (\i c -> go (currentPath <> [i]) weight c) children
        }

    Choice children ->
      HierarchyData
        { data_: { label: "?", nodeType: "choice", path: currentPath }
        , value: Nothing
        , children: Just $ Array.mapWithIndex (\i c -> go (currentPath <> [i]) weight c) children
        }

    -- SEMANTIC EXPANSION: Fast n subdivides the slot into n parts
    -- Each child gets weight/n so they total to parent's weight
    -- Keep nodeType as "fast" so it shows pink, even though structurally it's a sequence
    Fast n child ->
      let
        copies = Int.round n
        childWeight = weight / n  -- Subdivide: each copy gets 1/n of parent's time
        expandedChildren = Array.mapWithIndex
          (\i _ -> go (currentPath <> [i]) childWeight child)
          (Array.replicate copies unit)
      in
        HierarchyData
          { data_: { label: "*" <> show (Int.round n), nodeType: "fast", path: currentPath }
          , value: Nothing
          , children: Just expandedChildren
          }

    -- Slow doesn't subdivide, it stretches - keep as wrapper for now
    -- (metrics will show cycle length > 1)
    Slow n child ->
      HierarchyData
        { data_: { label: "/" <> show (Int.round n), nodeType: "slow", path: currentPath }
        , value: Nothing
        , children: Just [ go (currentPath <> [0]) weight child ]
        }

    Euclidean n k child ->
      HierarchyData
        { data_: { label: "(" <> show n <> "," <> show k <> ")", nodeType: "euclidean", path: currentPath }
        , value: Nothing
        , children: Just [ go (currentPath <> [0]) weight child ]
        }

    Degrade prob child ->
      HierarchyData
        { data_: { label: "?" <> show (Int.round (prob * 100.0)) <> "%", nodeType: "degrade", path: currentPath }
        , value: Nothing
        , children: Just [ go (currentPath <> [0]) weight child ]
        }

    -- SEMANTIC EXPANSION: Repeat n means play child n times sequentially
    -- Unlike Fast, Repeat ADDS time (n slots), so each child keeps the weight
    Repeat n child ->
      let
        expandedChildren = Array.mapWithIndex
          (\i _ -> go (currentPath <> [i]) weight child)
          (Array.replicate n unit)
      in
        HierarchyData
          { data_: { label: "seq", nodeType: "sequence", path: currentPath }
          , value: Nothing
          , children: Just expandedChildren
          }

    Elongate n child ->
      HierarchyData
        { data_: { label: "@" <> show (Int.round n), nodeType: "elongate", path: currentPath }
        , value: Nothing
        , children: Just [ go (currentPath <> [0]) weight child ]
        }

-- | Get color for node type (sunburst version - more saturated)
sunburstColor :: String -> String
sunburstColor = case _ of
  "sound" -> "#4CAF50"      -- Green for sounds (default)
  "rest" -> "#9E9E9E"       -- Gray for rests
  "sequence" -> "#2196F3"   -- Blue for sequences
  "parallel" -> "#FF9800"   -- Orange for parallel
  "choice" -> "#9C27B0"     -- Purple for choice
  "fast" -> "#E91E63"       -- Pink for fast
  "slow" -> "#00BCD4"       -- Cyan for slow
  "euclidean" -> "#FFEB3B"  -- Yellow for euclidean
  "degrade" -> "#795548"    -- Brown for degrade/probability
  "repeat" -> "#673AB7"     -- Deep purple for repeat
  "elongate" -> "#009688"   -- Teal for elongate
  "spacer" -> "#FFFFFF"     -- White for spacers (visual depth alignment)
  _ -> "#607D8B"

-- | Get alternating green shade for sound nodes
-- | Uses the index to determine which shade to use (cycles through 4 greens)
soundColorByIndex :: Int -> String
soundColorByIndex idx =
  case idx `mod` 4 of
    0 -> "#4CAF50"  -- Material green 500
    1 -> "#66BB6A"  -- Material green 400
    2 -> "#81C784"  -- Material green 300
    3 -> "#43A047"  -- Material green 600
    _ -> "#4CAF50"

-- | Get fill for node type - uses patterns for combinators
-- | Returns either a color or a pattern URL
sunburstFill :: String -> String
sunburstFill = case _ of
  "fast" -> "url(#fastPattern)"       -- Diagonal stripes for compression
  "slow" -> "url(#slowPattern)"       -- Horizontal bands for expansion
  "euclidean" -> "url(#euclidPattern)" -- Dots for rhythmic distribution
  "degrade" -> "url(#degradePattern)" -- Checkerboard for probability
  "repeat" -> "url(#repeatPattern)"   -- Vertical stripes for stutter
  "elongate" -> "url(#elongatePattern)" -- Gradient for stretch
  other -> sunburstColor other         -- Regular color for other types

-- | Get stroke style for node type
-- | Different combinators get distinctive strokes
sunburstStroke :: String -> { color :: String, width :: Number, dashArray :: String }
sunburstStroke = case _ of
  "fast" -> { color: "#C2185B", width: 2.0, dashArray: "3,2" }    -- Dashed pink
  "slow" -> { color: "#0097A7", width: 3.0, dashArray: "" }       -- Thick cyan
  "euclidean" -> { color: "#F57F17", width: 2.0, dashArray: "1,3" } -- Dotted yellow
  "degrade" -> { color: "#5D4037", width: 1.5, dashArray: "4,2" }  -- Dashed brown
  "repeat" -> { color: "#512DA8", width: 2.5, dashArray: "" }     -- Thick purple
  "elongate" -> { color: "#00796B", width: 2.0, dashArray: "6,2" } -- Long dash teal
  _ -> { color: "#fff", width: 1.0, dashArray: "" }

-- | Get badge text for combinator nodes
-- | Returns Just for combinators, Nothing for non-combinator nodes
combinatorBadge :: String -> Maybe String
combinatorBadge = case _ of
  "fast" -> Just "fast"
  "slow" -> Just "slow"
  "euclidean" -> Just "euclid"
  "degrade" -> Just "prob"
  "repeat" -> Just "rep"
  "elongate" -> Just "elong"
  _ -> Nothing

-- | Check if a node type is a combinator
isCombinator :: String -> Boolean
isCombinator nodeType = case combinatorBadge nodeType of
  Just _ -> true
  Nothing -> false

-- | Named pattern for standalone sunburst visualization
type NamedPattern = { name :: String, pattern :: PatternTree, trackIndex :: Int, active :: Boolean }

-- | Processed sunburst data for rendering
type SunburstData =
  { name :: String
  , nodes :: Array (PartitionNode HierarchyNodeData)
  , leafNodes :: Array (PartitionNode HierarchyNodeData)
  , centerX :: Number
  , centerY :: Number
  , radius :: Number
  , idx :: Int
  , trackIndex :: Int
  , active :: Boolean
  }

-- | Draw multiple pattern trees as sunbursts side by side
-- | onToggle callback is called with track index when center is clicked
drawPatternForestSunburst :: String -> Array NamedPattern -> (Int -> Effect Unit) -> Effect Unit
drawPatternForestSunburst selector namedPatterns onToggle = do
  let numPatterns = Array.length namedPatterns
  let chartWidth = 1400.0
  let chartHeight = 1200.0  -- Taller for grid layout

  -- Grid layout: determine columns and rows
  let cols = max 1 (min 5 (Int.ceil (sqrt (Int.toNumber numPatterns))))
  let rows = Int.ceil (Int.toNumber numPatterns / Int.toNumber cols)

  -- Calculate size for each sunburst based on grid
  let cellWidth = (chartWidth - 100.0) / Int.toNumber cols
  let cellHeight = (chartHeight - 200.0) / Int.toNumber rows
  let sunburstSize = min 200.0 (min cellWidth cellHeight * 0.85)
  let radius = sunburstSize / 2.0

  -- Starting position (centered in available space)
  let gridWidth = Int.toNumber cols * cellWidth
  let startX = (chartWidth - gridWidth) / 2.0 + cellWidth / 2.0
  let startY = 150.0 + cellHeight / 2.0  -- Below header area

  -- Convert each pattern to partitioned hierarchy with grid position
  let processPattern idx { name, pattern, trackIndex, active } =
        let
          hierData = patternToHierarchy pattern
          partRoot = hierarchy hierData
          config = defaultPartitionConfig
            { size = { width: 1.0, height: 1.0 }
            , padding = 0.002
            }
          partitioned = partition config partRoot
          -- Fix parallel layout: make parallel children share angular extent
          fixedPartitioned = fixParallelLayout (\d -> d.nodeType == "parallel") partitioned
          -- Flatten all nodes - show everything for consistent structure visualization
          -- (center circle is rendered on top to maintain label area)
          allNodes = flattenPartition fixedPartitioned
          nodes = allNodes
          -- Separate leaf nodes (sounds/rests) for labeling
          leafNodes = Array.filter (\(PartNode n) -> n.data_.nodeType == "sound" || n.data_.nodeType == "rest") nodes
          -- Grid position
          col = idx `mod` cols
          row = idx / cols
          centerX = startX + Int.toNumber col * cellWidth
          centerY = startY + Int.toNumber row * cellHeight
        in
          { name, nodes, leafNodes, centerX, centerY, radius, idx, trackIndex, active }

  let sunburstData = Array.mapWithIndex processPattern namedPatterns

  -- Zoom configuration
  let zoomConfig = ZoomConfig
        { scaleExtent: ScaleExtent 0.1 10.0
        , targetSelector: "#pattern-sunburst-zoom-group"
        }

  -- Build the complete visualization tree
  let
    vizTree :: H.Tree
    vizTree =
      H.withBehaviors [ H.onZoom zoomConfig ] $
        H.elem SVG
          [ H.staticNum "width" chartWidth
          , H.staticNum "height" chartHeight
          , H.staticStr "viewBox" ("0 0 " <> show chartWidth <> " " <> show chartHeight)
          , H.staticStr "class" "pattern-forest-viz pattern-forest-sunburst"
          ]
          [ -- Pattern definitions for combinator visual treatment
            patternDefs
          , -- Zoom group containing all sunbursts
            H.elem Group
              [ H.staticStr "id" "pattern-sunburst-zoom-group"
              , H.staticStr "class" "zoom-group"
              ]
              -- Render each sunburst as a child
              (Array.concatMap (renderSunburst onToggle) sunburstData)
          ]

  _ <- rerender selector vizTree
  pure unit

-- | Render a single sunburst as an array of tree elements (arcs, center, labels)
renderSunburst :: (Int -> Effect Unit) -> SunburstData -> Array H.Tree
renderSunburst onToggle sb =
  let
    arcOpacity = if sb.active then 0.85 else 0.25
    innerRadius = sb.radius * 0.35

    -- Filter out depth-0 nodes (root spans full circle, SVG arc limitation)
    nonRootNodes = Array.filter (\(PartNode n) -> n.depth > 0) sb.nodes

    -- Find root node for center coloring
    rootNode = Array.find (\(PartNode n) -> n.depth == 0) sb.nodes
    rootType = case rootNode of
      Just (PartNode n) -> n.data_.nodeType
      Nothing -> "sequence"

    centerBg = if sb.active then sunburstColor rootType else "#f5f5f5"
    centerStroke = if sb.active then "#fff" else "#ccc"
    centerTextColor = if sb.active then "#fff" else "#999"

    -- Sound leaves for labels
    soundLeaves = Array.filter (\(PartNode n) -> n.data_.nodeType == "sound") sb.leafNodes
  in
    [ -- Arcs group
      H.elem Group
        [ H.staticStr "transform" ("translate(" <> show sb.centerX <> "," <> show sb.centerY <> ")") ]
        [ H.forEach ("arcs-" <> show sb.idx) Path nonRootNodes arcKey \(PartNode node) ->
            let
              strokeStyle = sunburstStroke node.data_.nodeType
              pathIdx = case Array.last node.data_.path of
                Just i -> i
                Nothing -> 0
              fillColor = if node.data_.nodeType == "sound"
                then soundColorByIndex pathIdx
                else sunburstFill node.data_.nodeType
            in
              H.elem Path
                [ H.thunkedStr "d" (sunburstArcPath node.x0 node.y0 node.x1 node.y1 sb.radius)
                , H.thunkedStr "fill" fillColor
                , H.thunkedNum "fill-opacity" arcOpacity
                , H.thunkedStr "stroke" strokeStyle.color
                , H.thunkedNum "stroke-width" strokeStyle.width
                , H.thunkedStr "stroke-dasharray" strokeStyle.dashArray
                , H.thunkedStr "class" ("arc arc-" <> node.data_.nodeType)
                ]
                []
        ]
    , -- Center circle with track name (clickable)
      H.withBehaviors [ H.onClick (onToggle sb.trackIndex) ] $
        H.elem Group
          [ H.staticStr "transform" ("translate(" <> show sb.centerX <> "," <> show sb.centerY <> ")")
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
              , H.staticStr "class" "center-circle"
              ]
              []
          , H.elem Text
              [ H.staticNum "x" 0.0
              , H.staticNum "y" 4.0
              , H.thunkedStr "textContent" sb.name
              , H.staticNum "font-size" 12.0
              , H.staticStr "text-anchor" "middle"
              , H.thunkedStr "fill" centerTextColor
              , H.staticStr "font-weight" "600"
              , H.staticStr "class" "center-label"
              ]
              []
          ]
    ] <>
    -- Sound labels (only when active)
    if sb.active then
      [ H.elem Group
          [ H.staticStr "transform" ("translate(" <> show sb.centerX <> "," <> show sb.centerY <> ")") ]
          [ H.forEach ("labels-" <> show sb.idx) Text soundLeaves labelKey \(PartNode node) ->
              let
                midAngle = ((node.x0 + node.x1) / 2.0) * 2.0 * pi - (pi / 2.0)
                midRadius = ((node.y0 + node.y1) / 2.0) * sb.radius
                labelX = cos midAngle * midRadius
                labelY = sin midAngle * midRadius
                rotateAngle = ((node.x0 + node.x1) / 2.0) * 360.0 - 90.0
                finalRotate = if rotateAngle > 90.0 && rotateAngle < 270.0
                  then rotateAngle + 180.0
                  else rotateAngle
              in
                H.elem Text
                  [ H.thunkedNum "x" labelX
                  , H.thunkedNum "y" labelY
                  , H.thunkedStr "textContent" node.data_.label
                  , H.staticNum "font-size" 9.0
                  , H.staticStr "text-anchor" "middle"
                  , H.staticStr "dominant-baseline" "middle"
                  , H.staticStr "fill" "#000"
                  , H.thunkedStr "transform" ("rotate(" <> show finalRotate <> "," <> show labelX <> "," <> show labelY <> ")")
                  , H.staticStr "class" "sound-label"
                  ]
                  []
          ]
      ]
    else []
  where
  arcKey :: PartitionNode HierarchyNodeData -> String
  arcKey (PartNode n) = show n.depth <> "-" <> show n.x0

  labelKey :: PartitionNode HierarchyNodeData -> String
  labelKey (PartNode n) = n.data_.label <> "-" <> show n.x0

-- | Pattern definitions for combinator visual treatment
patternDefs :: H.Tree
patternDefs =
  H.elem Defs []
    [ -- Fast pattern: diagonal stripes (compression feel)
      H.elem PatternFill
        [ H.staticStr "id" "fastPattern"
        , H.staticStr "patternUnits" "userSpaceOnUse"
        , H.staticNum "width" 6.0
        , H.staticNum "height" 6.0
        , H.staticStr "patternTransform" "rotate(45)"
        ]
        [ H.elem Rect
            [ H.staticNum "width" 3.0
            , H.staticNum "height" 6.0
            , H.staticStr "fill" "#E91E63"
            ]
            []
        , H.elem Rect
            [ H.staticNum "x" 3.0
            , H.staticNum "width" 3.0
            , H.staticNum "height" 6.0
            , H.staticStr "fill" "#F48FB1"
            ]
            []
        ]
    , -- Slow pattern: horizontal gradient bands (expansion feel)
      H.elem PatternFill
        [ H.staticStr "id" "slowPattern"
        , H.staticStr "patternUnits" "userSpaceOnUse"
        , H.staticNum "width" 8.0
        , H.staticNum "height" 8.0
        ]
        [ H.elem Rect
            [ H.staticNum "width" 8.0
            , H.staticNum "height" 4.0
            , H.staticStr "fill" "#00BCD4"
            ]
            []
        , H.elem Rect
            [ H.staticNum "y" 4.0
            , H.staticNum "width" 8.0
            , H.staticNum "height" 4.0
            , H.staticStr "fill" "#4DD0E1"
            ]
            []
        ]
    , -- Euclidean pattern: dots for rhythmic distribution
      H.elem PatternFill
        [ H.staticStr "id" "euclidPattern"
        , H.staticStr "patternUnits" "userSpaceOnUse"
        , H.staticNum "width" 10.0
        , H.staticNum "height" 10.0
        ]
        [ H.elem Rect
            [ H.staticNum "width" 10.0
            , H.staticNum "height" 10.0
            , H.staticStr "fill" "#FFEB3B"
            ]
            []
        , H.elem Circle
            [ H.staticNum "cx" 5.0
            , H.staticNum "cy" 5.0
            , H.staticNum "r" 2.5
            , H.staticStr "fill" "#FFF176"
            ]
            []
        ]
    , -- Degrade pattern: checkerboard for probability/uncertainty
      H.elem PatternFill
        [ H.staticStr "id" "degradePattern"
        , H.staticStr "patternUnits" "userSpaceOnUse"
        , H.staticNum "width" 8.0
        , H.staticNum "height" 8.0
        ]
        [ H.elem Rect
            [ H.staticNum "width" 8.0
            , H.staticNum "height" 8.0
            , H.staticStr "fill" "#795548"
            ]
            []
        , H.elem Rect
            [ H.staticNum "width" 4.0
            , H.staticNum "height" 4.0
            , H.staticStr "fill" "#A1887F"
            ]
            []
        , H.elem Rect
            [ H.staticNum "x" 4.0
            , H.staticNum "y" 4.0
            , H.staticNum "width" 4.0
            , H.staticNum "height" 4.0
            , H.staticStr "fill" "#A1887F"
            ]
            []
        ]
    , -- Repeat pattern: vertical stripes for stutter/echo
      H.elem PatternFill
        [ H.staticStr "id" "repeatPattern"
        , H.staticStr "patternUnits" "userSpaceOnUse"
        , H.staticNum "width" 6.0
        , H.staticNum "height" 6.0
        ]
        [ H.elem Rect
            [ H.staticNum "width" 3.0
            , H.staticNum "height" 6.0
            , H.staticStr "fill" "#673AB7"
            ]
            []
        , H.elem Rect
            [ H.staticNum "x" 3.0
            , H.staticNum "width" 3.0
            , H.staticNum "height" 6.0
            , H.staticStr "fill" "#9575CD"
            ]
            []
        ]
    , -- Elongate pattern: diagonal gradient for stretch
      H.elem PatternFill
        [ H.staticStr "id" "elongatePattern"
        , H.staticStr "patternUnits" "userSpaceOnUse"
        , H.staticNum "width" 12.0
        , H.staticNum "height" 4.0
        ]
        [ H.elem Rect
            [ H.staticNum "width" 12.0
            , H.staticNum "height" 4.0
            , H.staticStr "fill" "#009688"
            ]
            []
        , H.elem Rect
            [ H.staticNum "width" 4.0
            , H.staticNum "height" 4.0
            , H.staticStr "fill" "#4DB6AC"
            ]
            []
        , H.elem Rect
            [ H.staticNum "x" 8.0
            , H.staticNum "width" 4.0
            , H.staticNum "height" 4.0
            , H.staticStr "fill" "#4DB6AC"
            ]
            []
        ]
    ]
