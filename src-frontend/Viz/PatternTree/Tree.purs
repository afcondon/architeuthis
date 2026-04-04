module D3.Viz.PatternTree.Tree
  ( drawPatternTree
  , drawPatternForest
  ) where

import Prelude

import Component.PatternTree (PatternTree)
import Data.Array as Array
import DataViz.Layout.Hierarchy.Tree (tree, defaultTreeConfig)
import Effect (Effect)
import Hylograph.HATS (Tree, elem, forEach, staticNum, staticStr, thunkedNum, thunkedStr, withBehaviors, onZoom)
import Hylograph.HATS.InterpreterTick (rerender)
import Hylograph.Internal.Behavior.Types (ScaleExtent(..), ZoomConfig(..))
import Hylograph.Internal.Selection.Types (ElementType(..))
import D3.Viz.PatternTree.Types (PatternNode, LinkDatum)
import D3.Viz.PatternTree.Layout (patternTreeToTree, patternForestToTree, makeLinks, makeForestLinks, makeForestNodes, linkPath, nodeColor)

-- | Draw a single pattern tree
drawPatternTree :: String -> PatternTree -> Effect Unit
drawPatternTree selector patternTree = do
  let chartWidth = 600.0
  let chartHeight = 400.0
  let padding = 40.0

  -- Convert to Data.Tree and apply layout
  let dataTree = patternTreeToTree patternTree
  let
    config = defaultTreeConfig
      { size =
          { width: chartWidth - (2.0 * padding)
          , height: chartHeight - (2.0 * padding)
          }
      }
  let positioned = tree config dataTree

  -- Flatten to arrays
  let nodes = Array.fromFoldable positioned
  let links = makeLinks positioned

  -- Combined tree with links and nodes
  let
    vizTree :: Tree
    vizTree =
      elem SVG
        [ staticNum "width" chartWidth
        , staticNum "height" chartHeight
        , staticStr "viewBox" ("0 0 " <> show chartWidth <> " " <> show chartHeight)
        , staticStr "class" "pattern-tree-viz"
        ]
        [ elem Group
            [ staticStr "class" "tree-content" ]
            [ -- Links layer
              elem Group
                [ staticStr "class" "links" ]
                [ forEach "links" Path links linkKey \link ->
                    elem Path
                      [ thunkedStr "d" (linkPath
                          (link.source.x + padding)
                          (link.source.y + padding)
                          (link.target.x + padding)
                          (link.target.y + padding))
                      , staticStr "fill" "none"
                      , staticStr "stroke" "#ccc"
                      , staticNum "stroke-width" 2.0
                      , staticStr "class" "link"
                      ]
                      []
                ]
            , -- Nodes layer (on top)
              elem Group
                [ staticStr "class" "nodes" ]
                [ forEach "nodeGroups" Group nodes nodeKey \node ->
                    elem Group
                      [ staticStr "class" ("node node-" <> node.nodeType) ]
                      [ elem Circle
                          [ thunkedNum "cx" (node.x + padding)
                          , thunkedNum "cy" (node.y + padding)
                          , staticNum "r" 8.0
                          , thunkedStr "fill" (nodeColor node.nodeType)
                          , staticStr "stroke" "#fff"
                          , staticNum "stroke-width" 2.0
                          ]
                          []
                      , elem Text
                          [ thunkedNum "x" (node.x + padding)
                          , thunkedNum "y" (node.y + padding - 14.0)
                          , thunkedStr "textContent" node.label
                          , staticNum "font-size" 13.0
                          , staticStr "text-anchor" "middle"
                          , staticStr "fill" "#000"
                          , staticStr "font-weight" "bold"
                          , staticStr "class" "pattern-node-label"
                          ]
                          []
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

-- | Draw a forest of pattern trees side-by-side
drawPatternForest :: String -> Array PatternTree -> Effect Unit
drawPatternForest selector patterns = do
  let chartWidth = 1200.0
  let chartHeight = 600.0
  let padding = 40.0

  -- Create forest with fake root
  let forestTree = patternForestToTree patterns
  let
    config = defaultTreeConfig
      { size =
          { width: chartWidth - (2.0 * padding)
          , height: chartHeight - (2.0 * padding)
          }
      }
  let positioned = tree config forestTree

  -- Flatten to arrays, filtering out fake root
  let nodes = makeForestNodes positioned
  let links = makeForestLinks positioned

  let zoomConfig = ZoomConfig
        { scaleExtent: ScaleExtent 0.1 10.0
        , targetSelector: "#pattern-forest-zoom-group"
        }

  -- Combined tree with zoom, links, and nodes
  let
    vizTree :: Tree
    vizTree =
      withBehaviors [ onZoom zoomConfig ] $
        elem SVG
          [ staticNum "width" chartWidth
          , staticNum "height" chartHeight
          , staticStr "viewBox" ("0 0 " <> show chartWidth <> " " <> show chartHeight)
          , staticStr "class" "pattern-forest-viz"
          ]
          [ elem Group
              [ staticStr "class" "forest-zoom-container" ]
              [ elem Group
                  [ staticStr "id" "pattern-forest-zoom-group"
                  , staticStr "class" "zoom-group"
                  ]
                  [ elem Group
                      [ staticStr "class" "forest-content" ]
                      [ -- Links layer
                        elem Group
                          [ staticStr "class" "links" ]
                          [ forEach "links" Path links linkKey \link ->
                              elem Path
                                [ thunkedStr "d" (linkPath
                                    (link.source.x + padding)
                                    (link.source.y + padding)
                                    (link.target.x + padding)
                                    (link.target.y + padding))
                                , staticStr "fill" "none"
                                , staticStr "stroke" "#ccc"
                                , staticNum "stroke-width" 2.0
                                , staticStr "class" "link"
                                ]
                                []
                          ]
                      , -- Nodes layer (on top)
                        elem Group
                          [ staticStr "class" "nodes" ]
                          [ forEach "nodeGroups" Group nodes nodeKey \node ->
                              elem Group
                                [ staticStr "class" ("node node-" <> node.nodeType) ]
                                [ elem Circle
                                    [ thunkedNum "cx" (node.x + padding)
                                    , thunkedNum "cy" (node.y + padding)
                                    , staticNum "r" 8.0
                                    , thunkedStr "fill" (nodeColor node.nodeType)
                                    , staticStr "stroke" "#fff"
                                    , staticNum "stroke-width" 2.0
                                    ]
                                    []
                                , elem Text
                                    [ thunkedNum "x" (node.x + padding)
                                    , thunkedNum "y" (node.y + padding - 14.0)
                                    , thunkedStr "textContent" node.label
                                    , staticNum "font-size" 13.0
                                    , staticStr "text-anchor" "middle"
                                    , staticStr "fill" "#000"
                                    , staticStr "font-weight" "bold"
                                    , staticStr "class" "pattern-node-label"
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
