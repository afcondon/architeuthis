-- | Mini-notation parser entry point.
-- |
-- | Wraps the lower-level parser in `Tidal.Parse.Parser` and the
-- | `tpatToPattern` step from `Tidal.Eval.Interpret`, returning a
-- | `Pattern String` ready for the runtime.
-- |
-- | Used by:
-- |
-- |   * `Tidal.Cell.Prelude.mini` — the cell-level combinator that
-- |     PureScript cell bodies call as `mini "bd sn ~ cp"`.
-- |
-- |   * `Tidal.WebSocket.Handler` — verbs that accept a bare-mini
-- |     pattern argument (`fh2-trigger`, etc.) call this from Erlang
-- |     via the purerl emitted `tidal_pattern_mini@ps` module.
-- |
-- | Sibling/replacement for the long-departed `Tidal.Expr.parseMiniPattern`
-- | (removed when the `:`-expression layer was deleted).
module Tidal.Pattern.Mini
  ( parseMiniPattern
  ) where

import Prelude

import Data.Either (Either(..))
import Tidal.Eval.Interpret (tpatToPattern)
import Tidal.Parse.Parser (parse)
import Tidal.Pattern.Types (Pattern)

-- | Parse a raw mini-notation string into a `Pattern String`. Errors
-- | are returned as `Left` (rendered string) so callers decide whether
-- | to silence or surface them.
parseMiniPattern :: String -> Either String (Pattern String)
parseMiniPattern src = case parse src of
  Right tpat -> Right (tpatToPattern tpat)
  Left err -> Left (show err)
