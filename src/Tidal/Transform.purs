-- | Per-event value transforms applied AFTER the Tidal mini-notation
-- | parser produces a numeric value. Lets us write `esx 0 "0 0.3 0.6
-- | 0.9" | offset -0.5` to get bipolar output without changing the
-- | upstream pattern parser (which doesn't accept leading `-`).
-- |
-- | The transforms are intentionally simple — Blinds/Veils-style
-- | per-channel conditioning. Composed in left-to-right pipe order:
-- | `pat | offset 0.1 | scale -1 1` means
-- | `(value + 0.1) → rescale to [-1..1]`.
-- |
-- | Server-side parallel of any future tidal-protocol Transform type.
-- | Today the Erlang handler parses the pipe syntax and sends a list
-- | of these to the scheduler; tidal-protocol's typed Outgoing layer
-- | can grow Transform constructors later when client-side construction
-- | is needed.
module Tidal.Transform
  ( Transform(..)
  , applyTransforms
  , applyTransform
  ) where

import Prelude

import Data.Array (foldl)

-- | Value-level transforms. Each takes a Number and returns a Number.
-- | Adding new ones = adding a constructor + branch in `applyTransform`.
data Transform
  = Offset Number              -- value + n
  | Invert                     -- -value
  | Scale Number Number        -- linear remap [0..1] → [lo..hi]

derive instance eqTransform :: Eq Transform

instance showTransform :: Show Transform where
  show = case _ of
    Offset n -> "Offset " <> show n
    Invert -> "Invert"
    Scale lo hi -> "Scale " <> show lo <> " " <> show hi

-- | Apply one transform to a value.
applyTransform :: Transform -> Number -> Number
applyTransform = case _ of
  Offset n -> \v -> v + n
  Invert -> \v -> negate v
  Scale lo hi -> \v -> lo + v * (hi - lo)

-- | Apply a chain of transforms in left-to-right (pipe) order.
-- | `applyTransforms [Offset 0.1, Scale (-1.0) 1.0] 0.5`
-- | = `Scale -1 1 (Offset 0.1 0.5)`
-- | = `Scale -1 1 0.6`
-- | = `-1 + 0.6 * 2`
-- | = `0.2`
applyTransforms :: Array Transform -> Number -> Number
applyTransforms ts v = foldl (\acc t -> applyTransform t acc) v ts
