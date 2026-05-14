-- | Prelude for generated cell modules.
-- |
-- | A cell's source is the right-hand-side of its `pattern` binding;
-- | the surrounding template imports just this module.  Everything
-- | a cell can reach lives here: the `Pattern` type, the discrete-
-- | pattern combinators (`fast`, `slow`, `rev`, `fastCat`, `stack`,
-- | `every`, `iter`, …), and a `mini` helper that takes a mini-
-- | notation string and returns a `Pattern String`.
-- |
-- | Re-exports `Tidal.Pattern.Types` and `Tidal.Pattern.Core` in
-- | bulk — anything those modules expose is reachable from a cell.
-- | Full PureScript-as-cell-language is the long-term direction (see
-- | the architectural-bet doc in calypso/docs); user-defined helpers
-- | promoted from cells into the prelude is the natural follow-up
-- | once cell bodies start sharing structure.
module Tidal.Cell.Prelude
  ( module Tidal.Pattern.Types
  , module Tidal.Pattern.Core
  , module DataRational
  , module Tidal.DejaVu
  , module Tidal.LiveControl
  , module Tidal.Random
  , mini
  , r
  ) where

-- We deliberately don't import Prelude here.  Tidal.Pattern.Core
-- has a few names (append) that would collide; cells import their
-- own Prelude through the cell template, which is the right place
-- for it.
import Data.Either (Either(..))
import Data.Rational (Rational, fromInt)
import Data.Rational (fromInt) as DataRational
import Tidal.Pattern.Types
import Tidal.Pattern.Core
import Tidal.DejaVu
import Tidal.LiveControl
import Tidal.Random
import Tidal.Pattern.Mini (parseMiniPattern)

-- | Parse a mini-notation string into a `Pattern String`.  Failed
-- | parses fall back to `silence` so a typo in a cell doesn't kill
-- | the rig — the bad cell just goes quiet until you fix it.  The
-- | parse error itself is currently swallowed; future work surfaces
-- | it through the modal's reply area.
-- |
-- | Examples:
-- |
-- | ```
-- | mini "bd sn cp"     -- three triggers per cycle
-- | mini "bd*4"         -- four kicks per cycle
-- | mini "[bd sn] hh*2" -- grouped sequencing
-- | mini "<a b c>"      -- alternation
-- | mini "bd(3,8)"      -- euclidean
-- | ```
mini :: String -> Pattern String
mini src = case parseMiniPattern src of
  Right p -> p
  Left _  -> silence

-- | Short alias for `Data.Rational.fromInt`.  `fast` and `slow` take
-- | a `Rational`, so `fast (r 2) (mini "bd sn")` is the cell idiom.
-- | The unaliased `fromInt` is also re-exported.
r :: Int -> Rational
r = fromInt
