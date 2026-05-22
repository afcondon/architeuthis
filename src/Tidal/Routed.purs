-- | The `>>` operator — notation routed to a destination.
-- |
-- | Class-only module: declares `RoutedTo` with no instances.  The
-- | instances live in `Calypso.Prelude` next to the destination types
-- | (`Instrument`, `DrumKit`) and the resulting Part types
-- | (`PitchedPart`, `DrumPart`).  Splitting the class out from its
-- | instances lets `Calypso.Prelude` re-export `Tidal.Routed.(>>)`
-- | without a circular import (the instances reside in the prelude
-- | itself).
-- |
-- | The class signature is `dest -> result` (functional dependency):
-- | the destination type determines the result shape.  An
-- | `Instrument note` resolves to `String -> PitchedPart note`; a
-- | `DrumKit` resolves to `String -> DrumPart`.  The `String` arg is
-- | the mvoice name — supplied at use-site (`(pat >> dest) "name"`),
-- | or applied later by a cell-template wrapper.
-- |
-- | Reads naturally in the cell-text shape from `docs/north-star.md`
-- | §3:
-- |
-- |   ```purescript
-- |   (mini "c4 e4 g4" >> bass1Inst) "bass1"
-- |   -- equivalent to:
-- |   on "bass1" bass1Inst (mini "c4 e4 g4")
-- |   ```
module Tidal.Routed
  ( class RoutedTo
  , routedTo
  , (>>)
  ) where

-- | A polymorphic infix binder.  The functional dependency
-- | `dest -> result` lets the destination type pick the result shape.
-- | Instances are declared in `Calypso.Prelude` (the destination
-- | types' home).
class RoutedTo n dest result | dest -> result where
  routedTo :: n -> dest -> result

-- | Right-associative, low-precedence — same fixity as application-
-- | style binders.  PureScript's Prelude doesn't define `>>` (the
-- | monadic sequence operator is `>>=`), so this is free.
infixl 1 routedTo as >>
