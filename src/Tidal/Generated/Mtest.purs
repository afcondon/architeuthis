-- | Spike — hand-written cell module for the per-cell-compile pipeline.
-- |
-- | Round-trips through:
-- |   spago build → output-erl/Tidal.Generated.Mtest/...erl
-- |   erlc        → ebin/tidal_generated_mtest@ps.beam
-- |   code:load_file('tidal_generated_mtest@ps')
-- |   ('tidal_generated_mtest@ps':pattern())  — returns a Pattern String
-- |
-- | Mirrors the template tidal_compiler renders for real cells (Phase 1):
-- | imports Tidal.Cell.Prelude which exposes Pattern, silence,
-- | combinators (fast, slow, rev, fastCat, stack, every, …), and
-- | mini-notation parsing via `mini`.
-- |
-- | See docs/per-cell-compile-plan.md.
module Tidal.Generated.Mtest where

import Prelude
import Tidal.Cell.Prelude

pattern :: Pattern String
pattern = mini "bd sn cp"
