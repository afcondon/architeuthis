module D3.Viz.PatternTree.Radial
  ( drawPatternForestRadial
  , radialPoint
  , projectRadial
  ) where

import Prelude

import Component.PatternTree (PatternTree)
import Control.Comonad.Cofree (head, tail)
import Data.Array as Array
import Data.Number (pi, cos, sin)
import Data.Tree (Tree, mkTree)
import DataViz.Layout.Hierarchy.Link (linkBezierRadialCartesian)
import DataViz.Layout.Hierarchy.Tree (tree, defaultTreeConfig)
import Effect (Effect)
import Hylograph.HATS (Tree, elem, forEach, staticNum, staticStr, thunkedNum, thunkedStr, withBehaviors, onZoom) as H
import Hylograph.HATS.InterpreterTick (rerender)
import Hylograph.Internal.Behavior.Types (ScaleExtent(..), ZoomConfig(..))
import Hylograph.Internal.Selection.Types (ElementType(..))
import D3.Viz.PatternTree.Types (PatternNode, LinkDatum)
import D3.Viz.PatternTree.Layout (patternForestToTree, makeForestLinks, makeForestNodes, nodeColor)

-- | Radial projection: convert (x, y) to polar coordinates
-- | x is mapped to angle, y (depth) is mapped to radius
radialPoint :: forall r. { x :: Number, y :: Number | r } -> Number -> Number -> { x :: Number, y :: Number }
radialPoint node w h =
  let
    -- Map x to angle (0 to 2π)
    angle = (node.x / w) * 2.0 * pi - (pi / 2.0) -- Start at top (-π/2)
    -- Map y (depth) to radius
    minDim = if w < h then w else h
    rad = (node.y / h) * (minDim / 2.0) * 0.85 -- Scale to 85% of radius
  in
    { x: rad * cos angle
    , y: rad * sin angle
    }

-- | Apply radial projection to a tree
projectRadial :: forall r. Number -> Number -> Tree { x :: Number, y :: Number | r } -> Tree { x :: Number, y :: Number | r }
projectRadial w h t =
  let
    val = head t
    children = tail t
    projected = radialPoint val w h
    projectedChildren = map (projectRadial w h) children
  in
    mkTree (val { x = projected.x, y = projected.y }) projectedChildren

-- | Draw a forest of pattern trees in radial layout
drawPatternForestRadial :: String -> Array PatternTree -> Effect Unit
drawPatternForestRadial selector patterns = do
  let chartSize = 1200.0
  let centerX = chartSize / 2.0
  let centerY = chartSize / 2.0

  -- Create forest with fake root
  let forestTree = patternForestToTree patterns
  let
    config = defaultTreeConfig
      { size =
          { width: chartSize
          , height: chartSize
          }
      }
  let positioned = tree config forestTree

  -- Apply radial projection
  let radialTree = projectRadial chartSize chartSize positioned

  -- Flatten to arrays, filtering out fake root
  let nodes = makeForestNodes radialTree
  let links = makeForestLinks radialTree

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
          [ H.staticNum "width" chartSize
          , H.staticNum "height" chartSize
          , H.staticStr "viewBox" ("0 0 " <> show chartSize <> " " <> show chartSize)
          , H.staticStr "class" "pattern-forest-viz pattern-forest-radial"
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
                          [ H.forEach "links" Path links linkKey \link ->
                              H.elem Path
                                [ H.thunkedStr "d" (linkBezierRadialCartesian
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
                          [ H.forEach "nodeGroups" Group nodes nodeKey \node ->
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
