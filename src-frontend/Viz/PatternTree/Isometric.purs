module D3.Viz.PatternTree.Isometric
  ( drawPatternForestIsometric
  , layout3D
  , isometricProject
  , projectIsometric
  ) where

import Prelude

import Component.PatternTree (PatternTree(..))
import Control.Comonad.Cofree (head, tail)
import Data.Array as Array
import Data.Int as Int
import Data.List (List(..))
import Data.Number (pi, cos, sin, abs)
import Data.Tree (Tree, mkTree)
import Effect (Effect)
import Hylograph.HATS (Tree, elem, forEach, staticNum, staticStr, thunkedNum, thunkedStr, withBehaviors, onZoom) as H
import Hylograph.HATS.InterpreterTick (rerender)
import Hylograph.Internal.Behavior.Types (ScaleExtent(..), ZoomConfig(..))
import Hylograph.Internal.Selection.Types (ElementType(..))
import D3.Viz.PatternTree.Types (PatternNode, PatternNode3D, LinkDatum)
import D3.Viz.PatternTree.Layout (makeLinks, nodeColor)

-- | Layout a pattern tree in 3D space where:
-- | - X = temporal progression (sequence children advance in X)
-- | - Y = tree depth (how deep in the hierarchy)
-- | - Z = parallel stack (parallel children stack in Z)
layout3D :: Number -> Number -> Number -> Int -> PatternTree -> Tree PatternNode3D
layout3D xPos yPos zPos depth pattern = case pattern of
  Sound s ->
    mkTree
      { label: s
      , nodeType: "sound"
      , x: xPos
      , y: yPos
      , z: zPos
      , depth
      }
      Nil

  Rest ->
    mkTree
      { label: "~"
      , nodeType: "rest"
      , x: xPos
      , y: yPos
      , z: zPos
      , depth
      }
      Nil

  Sequence children ->
    let
      -- Sequence: children advance in X (temporal progression)
      childDepth = depth + 1
      childY = yPos + 60.0  -- Move down in tree
      spacing = 80.0        -- Horizontal spacing for sequence
      layoutChild idx child =
        layout3D (xPos + (toNumber idx) * spacing) childY zPos childDepth child
      layoutedChildren = Array.mapWithIndex layoutChild children
    in
      mkTree
        { label: "seq"
        , nodeType: "sequence"
        , x: xPos
        , y: yPos
        , z: zPos
        , depth
        }
        (Array.toUnfoldable layoutedChildren)

  Parallel children ->
    let
      -- Parallel: children stack in Z (simultaneity)
      childDepth = depth + 1
      childY = yPos + 60.0  -- Move down in tree
      spacing = 40.0        -- Z spacing for parallel stack
      layoutChild idx child =
        layout3D xPos childY (zPos + (toNumber idx) * spacing) childDepth child
      layoutedChildren = Array.mapWithIndex layoutChild children
    in
      mkTree
        { label: "par"
        , nodeType: "parallel"
        , x: xPos
        , y: yPos
        , z: zPos
        , depth
        }
        (Array.toUnfoldable layoutedChildren)

  Choice children ->
    let
      -- Choice: spread in both X and Z slightly
      childDepth = depth + 1
      childY = yPos + 60.0
      xSpacing = 50.0
      zSpacing = 30.0
      layoutChild idx child =
        layout3D
          (xPos + (toNumber idx) * xSpacing)
          childY
          (zPos + (toNumber idx) * zSpacing)
          childDepth
          child
      layoutedChildren = Array.mapWithIndex layoutChild children
    in
      mkTree
        { label: "choice"
        , nodeType: "choice"
        , x: xPos
        , y: yPos
        , z: zPos
        , depth
        }
        (Array.toUnfoldable layoutedChildren)

  -- New extended constructors - modifiers with single child
  Fast n child ->
    let
      childDepth = depth + 1
      childY = yPos + 60.0
      childTree = layout3D xPos childY zPos childDepth child
    in
      mkTree
        { label: "*" <> show (Int.round n)
        , nodeType: "fast"
        , x: xPos
        , y: yPos
        , z: zPos
        , depth
        }
        (Cons childTree Nil)

  Slow n child ->
    let
      childDepth = depth + 1
      childY = yPos + 60.0
      childTree = layout3D xPos childY zPos childDepth child
    in
      mkTree
        { label: "/" <> show (Int.round n)
        , nodeType: "slow"
        , x: xPos
        , y: yPos
        , z: zPos
        , depth
        }
        (Cons childTree Nil)

  Euclidean n k child ->
    let
      childDepth = depth + 1
      childY = yPos + 60.0
      childTree = layout3D xPos childY zPos childDepth child
    in
      mkTree
        { label: "(" <> show n <> "," <> show k <> ")"
        , nodeType: "euclidean"
        , x: xPos
        , y: yPos
        , z: zPos
        , depth
        }
        (Cons childTree Nil)

  Degrade prob child ->
    let
      childDepth = depth + 1
      childY = yPos + 60.0
      childTree = layout3D xPos childY zPos childDepth child
    in
      mkTree
        { label: "?" <> show (Int.round (prob * 100.0)) <> "%"
        , nodeType: "degrade"
        , x: xPos
        , y: yPos
        , z: zPos
        , depth
        }
        (Cons childTree Nil)

  Repeat n child ->
    let
      childDepth = depth + 1
      childY = yPos + 60.0
      childTree = layout3D xPos childY zPos childDepth child
    in
      mkTree
        { label: "!" <> show n
        , nodeType: "repeat"
        , x: xPos
        , y: yPos
        , z: zPos
        , depth
        }
        (Cons childTree Nil)

  Elongate n child ->
    let
      childDepth = depth + 1
      childY = yPos + 60.0
      childTree = layout3D xPos childY zPos childDepth child
    in
      mkTree
        { label: "@" <> show (Int.round n)
        , nodeType: "elongate"
        , x: xPos
        , y: yPos
        , z: zPos
        , depth
        }
        (Cons childTree Nil)

  where
  toNumber :: Int -> Number
  toNumber = Int.toNumber

-- | Isometric projection: convert (x, y, z) to (iso_x, iso_y)
-- | Uses standard 30-degree isometric angle
isometricProject :: forall r. { x :: Number, y :: Number, z :: Number | r } -> { x :: Number, y :: Number }
isometricProject pos =
  { x: (pos.x - pos.z) * cos (pi / 6.0)  -- 30 degrees
  , y: pos.y + (pos.x + pos.z) * sin (pi / 6.0)
  }

-- | Apply isometric projection to all nodes in tree
-- | Note: path is not tracked for isometric view (experimental)
projectIsometric :: Tree PatternNode3D -> Tree PatternNode
projectIsometric tree3d =
  let
    val = head tree3d
    children = tail tree3d
    projected = isometricProject val
    projectedChildren = map projectIsometric children
  in
    mkTree
      { label: val.label
      , nodeType: val.nodeType
      , x: projected.x
      , y: projected.y
      , depth: val.depth
      , path: []  -- Isometric view doesn't use click paths
      }
      projectedChildren

-- | Isometric link path generator
-- | Creates bezier curves that follow isometric perspective
isometricLinkPath :: Number -> Number -> Number -> Number -> String
isometricLinkPath x1 y1 x2 y2 =
  let
    distance = abs (x2 - x1) + abs (y2 - y1)
    parentOffset = distance * 0.1
    childOffset = distance * 0.25
    cx1 = x1 + parentOffset
    cy1 = y1 + parentOffset
    cx2 = x2 - childOffset
    cy2 = y2 - childOffset
  in
    "M" <> show x1 <> "," <> show y1
    <> " C" <> show cx1 <> "," <> show cy1
    <> " " <> show cx2 <> "," <> show cy2
    <> " " <> show x2 <> "," <> show y2

-- | Draw a forest of pattern trees in isometric 3D layout
drawPatternForestIsometric :: String -> Array PatternTree -> Effect Unit
drawPatternForestIsometric selector patterns = do
  let chartWidth = 1200.0
  let chartHeight = 800.0
  let centerX = chartWidth / 2.0
  let centerY = 100.0  -- Start near top

  -- Layout each pattern tree in 3D, spacing them in X
  let spacing = 200.0
  let layout3DPattern idx pattern' =
        layout3D (Int.toNumber idx * spacing) 0.0 0.0 0 pattern'

  let trees3D = Array.mapWithIndex layout3DPattern patterns

  -- Project to isometric 2D
  let projectedTrees = map projectIsometric trees3D

  -- Flatten all trees to node and link arrays
  let allNodes = Array.foldl (<>) [] $ map (Array.fromFoldable) projectedTrees
  let allLinks = Array.foldl (<>) [] $ map makeLinks projectedTrees

  -- Zoom configuration
  let zoomConfig = ZoomConfig
        { scaleExtent: ScaleExtent 0.1 10.0
        , targetSelector: "#pattern-forest-zoom-group"
        }

  -- Combined visualization tree
  let
    vizTree :: H.Tree
    vizTree =
      H.withBehaviors [ H.onZoom zoomConfig ] $
        H.elem SVG
          [ H.staticNum "width" chartWidth
          , H.staticNum "height" chartHeight
          , H.staticStr "viewBox" ("0 0 " <> show chartWidth <> " " <> show chartHeight)
          , H.staticStr "class" "pattern-forest-viz pattern-forest-isometric"
          ]
          [ H.elem Group
              [ H.staticStr "class" "forest-zoom-container" ]
              [ H.elem Group
                  [ H.staticStr "id" "pattern-forest-zoom-group"
                  , H.staticStr "class" "zoom-group"
                  , H.staticStr "transform" ("translate(" <> show centerX <> "," <> show centerY <> ")")
                  ]
                  [ H.elem Group
                      [ H.staticStr "class" "forest-content" ]
                      [ -- Links layer
                        H.elem Group
                          [ H.staticStr "class" "links" ]
                          [ H.forEach "links" Path allLinks linkKey \link ->
                              H.elem Path
                                [ H.thunkedStr "d" (isometricLinkPath
                                    link.source.x
                                    link.source.y
                                    link.target.x
                                    link.target.y)
                                , H.staticStr "fill" "none"
                                , H.staticStr "stroke" "#ccc"
                                , H.staticNum "stroke-width" 2.0
                                , H.staticStr "class" "link"
                                ]
                                []
                          ]
                      , -- Nodes layer (on top)
                        H.elem Group
                          [ H.staticStr "class" "nodes" ]
                          [ H.forEach "nodeGroups" Group allNodes nodeKey \node ->
                              H.elem Group
                                [ H.staticStr "class" ("node node-" <> node.nodeType) ]
                                [ H.elem Circle
                                    [ H.thunkedNum "cx" node.x
                                    , H.thunkedNum "cy" node.y
                                    , H.staticNum "r" 8.0
                                    , H.thunkedStr "fill" (nodeColor node.nodeType)
                                    , H.staticStr "stroke" "#fff"
                                    , H.staticNum "stroke-width" 2.0
                                    ]
                                    []
                                , H.elem Text
                                    [ H.thunkedNum "x" node.x
                                    , H.thunkedNum "y" (node.y - 14.0)
                                    , H.thunkedStr "textContent" node.label
                                    , H.staticNum "font-size" 13.0
                                    , H.staticStr "text-anchor" "middle"
                                    , H.staticStr "fill" "#000"
                                    , H.staticStr "font-weight" "bold"
                                    , H.staticStr "class" "pattern-node-label"
                                    ]
                                    []
                                ]
                          ]
                      ]
                  ]
              ]
          ]

  _ <- rerender selector vizTree
  pure unit
  where
  linkKey :: LinkDatum -> String
  linkKey link = show link.source.x <> "-" <> show link.target.x

  nodeKey :: PatternNode -> String
  nodeKey node = node.label
