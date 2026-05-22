-- | `MiniNotation a` — mini-notation as a typed first-class value.
-- |
-- | Today's `Tidal.Pitch.Parse.mini :: String -> Pattern PitchedNote12`
-- | resolves a source string to a `Pattern` and throws the source
-- | away.  `MiniNotation a` preserves the parsed tree, deferring
-- | Pattern resolution to the `Notation` instance.
-- |
-- | What this buys (per `docs/north-star.md` §6):
-- |
-- |   * Round-trip to source for editor display — cells can persist
-- |     the literal text the user typed, not the resolved Pattern.
-- |   * Source-level composition — `mini "bd sn" <> mini "hh cp"`
-- |     concatenates at the tree level, equivalent to
-- |     `mini "bd sn hh cp"`.
-- |   * Substrate uniformity — `MiniNotation a` is a `Notation` like
-- |     Vetula / Balistes / Odonus / Sufflamen.  The substrate
-- |     doesn't special-case it.
-- |
-- | This module is additive — it doesn't replace `Tidal.Pitch.Parse.mini`,
-- | which keeps its `Pattern PitchedNote12` return type for back-
-- | compatibility with every existing cell.  New cells can opt into
-- | `miniTyped` for the round-trip-source affordance; cells that
-- | bind a `MiniNotation a` get `Show` / `Semigroup` / `Notation` for
-- | free.
-- |
-- | Long-term direction: `Tidal.Pitch.Parse.mini` lifts to return
-- | `MiniNotation PitchedNote12`, with an automatic `toPattern`
-- | conversion at the boundaries that need a `Pattern`.  See task
-- | `#150` for the broader `Notation`-everywhere work that enables
-- | the lift.
module Tidal.MiniNotation
  ( MiniNotation
  , miniTyped
  , miniSource
  , miniTPat
  ) where

import Prelude

import Data.Either (Either(..))
import Tidal.AST.Pretty (class PrettyAtom, pretty)
import Tidal.AST.Types (TPat(..))
import Tidal.Core.Types (emptySpan)
import Tidal.Eval.Interpret (tpatToPattern)
import Tidal.Notation (class Notation)
import Tidal.Parse.Parser (parse)
import Tidal.Pattern.Types (class TidalEnum)

-- | Mini-notation as a typed value.  The constructor is exported via
-- | smart-constructor (`miniTyped`) only — callers can't bypass the
-- | parser, but `Notation` and `Semigroup` operations preserve the
-- | typed-tree invariant.
newtype MiniNotation a = MiniNotation (TPat a)

-- | Smart constructor.  Parses the source string and wraps the
-- | resulting TPat.  Parse failures fall back to a silence-tree so a
-- | typo in a cell doesn't kill the rig (matches `Tidal.Pitch.Parse.mini`).
-- |
-- | The atom type is determined by usage context (`mini` is generic
-- | over any atom type that the parser accepts — the parser itself
-- | produces `TPat String`, and downstream lift to `a` happens via
-- | the `Notation` instance's `tpatToPattern` step).
miniTyped :: String -> MiniNotation String
miniTyped src = case parse src of
  Right tp -> MiniNotation tp
  Left _   -> MiniNotation (TPat_Silence emptySpan)

-- | Round-trip the value back to its mini-notation source.  Uses the
-- | existing `Tidal.AST.Pretty.pretty` printer, which aims for
-- | semantic equivalence (a parsed-then-pretty-printed value reparses
-- | to an equivalent TPat) rather than exact string identity —
-- | whitespace and sugar may shift.
miniSource :: forall a. PrettyAtom a => MiniNotation a -> String
miniSource (MiniNotation tp) = pretty tp

-- | Escape hatch: expose the wrapped TPat for AST-level manipulation
-- | (e.g. by a visual editor that wants to splice nodes).  Most
-- | callers should reach for `toPattern` instead.
miniTPat :: forall a. MiniNotation a -> TPat a
miniTPat (MiniNotation tp) = tp

-- ---------------------------------------------------------------------------
-- Instances
-- ---------------------------------------------------------------------------

-- | Functor: lift `a -> b` across the wrapped TPat.  Used when a
-- | downstream consumer needs a different atom type (e.g. the
-- | per-token `String -> PitchedNote12` step in `Tidal.Pitch.Parse`).
derive instance functorMiniNotation :: Functor MiniNotation

-- | Show via the existing `Show (TPat a)` — produces a debug-shaped
-- | rendering (constructor names + values), useful for diagnostic
-- | output.  For round-trip-to-source, use `miniSource` (requires
-- | `PrettyAtom a`).
instance showMiniNotation :: Show a => Show (MiniNotation a) where
  show (MiniNotation tp) = show tp

-- | Equality lifted from `Eq (TPat a)`.  Note `Eq (Located a)` is
-- | source-location-insensitive (compares values only), so a parsed
-- | `mini "bd sn"` from different source positions still equals
-- | itself.
-- |
-- | Not derived because TPat doesn't carry an `Eq` instance today —
-- | left as future work.  Cells that need equality compare via
-- | `miniSource` for now.

-- | Concatenation at the tree level.  `mini "bd sn" <> mini "hh cp"`
-- | becomes `TPat_Seq [bd, sn, hh, cp]`, equivalent to parsing
-- | `mini "bd sn hh cp"` directly.  Sequences flatten; non-sequence
-- | values get wrapped.
instance semigroupMiniNotation :: Semigroup (MiniNotation a) where
  append (MiniNotation l) (MiniNotation r) =
    MiniNotation (catTPat l r)

-- | Identity element is the silence tree, matching `Tidal`'s `silence`
-- | pattern semantics.
instance monoidMiniNotation :: Monoid (MiniNotation a) where
  mempty = MiniNotation (TPat_Silence emptySpan)

-- | The headline instance.  Resolves the wrapped TPat to a `Pattern a`
-- | via the existing `tpatToPattern` interpreter, threading the same
-- | `TidalEnum` constraint that bare `mini` needs today.
instance notationMiniNotation :: TidalEnum a => Notation (MiniNotation a) a where
  toPattern (MiniNotation tp) = tpatToPattern tp

-- ---------------------------------------------------------------------------
-- Internal — TPat concatenation
-- ---------------------------------------------------------------------------

-- | Concatenate two TPats, flattening nested `TPat_Seq`s so
-- | `(a <> b) <> c` doesn't accumulate gratuitous nesting.  Silence
-- | annihilates on either side (matches `Monoid`'s left/right
-- | identity laws against `mempty = silence`).
catTPat :: forall a. TPat a -> TPat a -> TPat a
catTPat l r = case l, r of
  TPat_Silence _, x -> x
  x, TPat_Silence _ -> x
  TPat_Seq _ ls, TPat_Seq _ rs -> TPat_Seq emptySpan (ls <> rs)
  TPat_Seq _ ls, x             -> TPat_Seq emptySpan (ls <> [x])
  x, TPat_Seq _ rs             -> TPat_Seq emptySpan ([x] <> rs)
  x, y                          -> TPat_Seq emptySpan [x, y]
