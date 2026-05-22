-- | The `Notation` typeclass — source-side counterpart to
-- | `Tidal.Emit.Emitable`.
-- |
-- | A `Notation` is anything that can yield a `Pattern a` for the
-- | substrate to query.  Per `docs/north-star.md` §2, this is the
-- | upstream half of the architecture: the substrate takes any
-- | `Notation`, queries its Pattern, and hands events to whatever
-- | `Emitable` destination the voice was bound to.
-- |
-- | Concrete instances (declared elsewhere — orphan rule pushes them
-- | next to their type):
-- |
-- |   * `Pattern a` itself (trivial self-instance, declared here)
-- |   * `MiniNotation a` (in `Tidal.MiniNotation`)
-- |   * `Vetula` (future, in `Tidal.Vetula`)
-- |   * `Balistes` config (in `Tidal.Balistes`, renamed eventually)
-- |   * `Odonus` config (in `Tidal.Odonus`, renamed eventually)
-- |   * `Sufflamen` config (in `Tidal.Polysignal`, renamed eventually)
-- |
-- | The functional dependency `n -> a` ensures the substrate can
-- | infer the payload type from the notation type alone — so a voice
-- | declared as `vetula { ... } >> piano1` carries `Pattern Voicing`
-- | through the substrate without explicit annotation.
-- |
-- | See `docs/north-star.md` for the broader architectural framing
-- | and `docs/verb-sink-table.md` for what each sink consumes.
module Tidal.Notation
  ( class Notation
  , toPattern
  ) where

import Prelude

import Tidal.Pattern.Types (Pattern)

-- | The source-side typeclass.  `n` is the notation type, `a` is the
-- | payload that flows through the substrate's Pattern algebra.
class Notation n a | n -> a where
  toPattern :: n -> Pattern a

-- | Trivial self-instance: a `Pattern a` is its own `Notation`.  This
-- | lets the substrate hold uniform `Notation` voices even when some
-- | of them are bare patterns (a `Pattern PitchedNote12` from `mini`,
-- | a `Pattern Boolean` from a hand-written cell, etc.).
instance notationPattern :: Notation (Pattern a) a where
  toPattern = identity
