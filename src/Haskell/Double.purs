-- | **Haskell's `Double` functions**: the `Floating Double` methods Tidal
-- | uses, and `floor :: Double -> Integer`.
-- |
-- | Part of the reference-semantics types (`Haskell.*`). PureScript's
-- | `Number` is already an IEEE double, so only the functions are here, and
-- | only because the two package sets disagree on where they live (`Math`
-- | in the purerl set, `Data.Number` in the registry): the engine imports
-- | them from one place that compiles on both.
-- |
-- | GHC calls the C library for `sin`, `cos` and `sqrt`, and so does
-- | Erlang's `math` module, so on the BEAM the results are GHC's to the bit.
-- | V8's `Math.sin` is its own port of fdlibm and may differ from the C
-- | library in the last bit.
module Haskell.Double
  ( sin
  , cos
  , sqrt
  , pi
  , floor
  ) where

import Prelude

import Haskell.Integer (Integer)
import Haskell.Integer as Integer
import JS.BigInt (BigInt)

foreign import sin :: Number -> Number
foreign import cos :: Number -> Number
foreign import sqrt :: Number -> Number
foreign import pi :: Number
foreign import floorImpl :: Number -> BigInt

-- | Exact: the largest integer not above the argument.
floor :: Number -> Integer
floor = Integer.fromBigInt <<< floorImpl
