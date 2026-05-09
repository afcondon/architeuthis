-- | Spike — hand-written cell module for the per-cell-compile pipeline.
-- |
-- | This file MUST round-trip through:
-- |   spago build → output-erl/Tidal.Generated.Mtest/...erl
-- |   erlc        → ebin/tidal_generated_mtest@ps.beam
-- |   code:load_file('tidal_generated_mtest@ps')
-- |   ('tidal_generated_mtest@ps':result())  — returns an Int
-- |
-- | When the compile_and_load API in tidal_compiler.erl renders a real
-- | generated cell, it uses this same template (Int result, for the
-- | PR2 integrated-test phase).  PR3 will flip the template back to
-- | `pattern :: Pattern String` and wire voice install.
-- |
-- | See docs/per-cell-compile-plan.md.
module Tidal.Generated.Mtest where

import Prelude

result :: Int
result = 2 + 2
