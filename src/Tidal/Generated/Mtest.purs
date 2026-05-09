-- | Spike — hand-written cell module for the per-cell-compile pipeline.
-- |
-- | This file MUST round-trip through:
-- |   spago build → output-erl/Tidal.Generated.Mtest/...erl
-- |   erlc        → ebin/tidal_generated_mtest@ps.beam
-- |   code:load_file('tidal_generated_mtest@ps')
-- |   ('tidal_generated_mtest@ps':pattern())()  — returns a Pattern String
-- |
-- | When the compile_and_load API lands in tidal_compiler.erl, the body
-- | of this file becomes the literal template (with one substitution
-- | point: the body of `pattern`).  See docs/per-cell-compile-plan.md.
module Tidal.Generated.Mtest where

import Prelude

import Tidal.Pattern.Types (Pattern)

pattern :: Pattern String
pattern = pure "bd2"
