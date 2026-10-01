-- | Parser state for mini-notation parsing: Parsec's user state, as in
-- | Tidal's `Parser = Parsec String Int`, as a record (the seed counter,
-- | plus the file name). Like Parsec's, it rolls back on backtracking.
module Tidal.Parse.State
  ( ParseState
  , initialState
  , newSeed
  , currentPos
  , mkSourceSpan
  ) where

import Prelude

import Haskell.Parsec (Parsec, getPosition, getState, modifyState, sourceColumn, sourceLine)
import Tidal.Core.Types (Seed(..), SourcePos, SourceSpan)

-- | Parser state
-- |
-- | - `nextSeed`: Counter for generating deterministic random seeds
-- | - `fileName`: Source file name for error messages
type ParseState =
  { nextSeed :: Int
  , fileName :: String
  }

-- | Create initial parser state
initialState :: String -> ParseState
initialState fileName =
  { nextSeed: 0
  , fileName
  }

-- | Generate a new seed for randomization
-- |
-- | Each `?` and `|` operator needs a unique seed for deterministic
-- | pseudo-randomness. Seeds increment monotonically.
newSeed :: Parsec ParseState Seed
newSeed = do
  st <- getState
  modifyState \s -> s { nextSeed = s.nextSeed + 1 }
  pure $ Seed st.nextSeed

-- | The current source position, as Parsec counts it (from 1, 1).
currentPos :: forall u. Parsec u SourcePos
currentPos = (\p -> { line: sourceLine p, column: sourceColumn p }) <$> getPosition

-- | Create a SourceSpan from start and end positions
mkSourceSpan :: SourcePos -> SourcePos -> SourceSpan
mkSourceSpan start end = { start, end }
