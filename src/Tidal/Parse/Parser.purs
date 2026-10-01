-- | Main parser module with entry points
-- |
-- | This module provides the top-level parsing functions.
-- | The actual parser implementation is in Tidal.Parse.Combinators.
module Tidal.Parse.Parser
  ( -- * Entry points
    parse
  , parseTPat
  , parseMini
    -- * Chord parsing
  , parseChord
    -- * Re-exports for convenience
  , module Tidal.Parse.Class
  ) where

import Prelude

import Data.Either (Either)
import Haskell.Parsec (ParseError, eof, runParser)
import Tidal.AST.Types (TPat)
import Tidal.Parse.Class (class AtomParseable, TidalParser)
import Tidal.Parse.Combinators (pTidal, pNoteChord)
import Tidal.Parse.State (initialState)
import Tidal.Pattern.Types (Note)

-- | Parse a mini-notation string to TPat AST
-- |
-- | This is the main entry point for parsing. Returns either a parse error
-- | or the parsed AST.
-- |
-- | ```purescript
-- | parseTPat "bd sn" :: Either ParseError (TPat String)
-- | parseTPat "c4 e4 g4" :: Either ParseError (TPat Note)
-- | ```
parseTPat :: forall a. AtomParseable a => String -> Either ParseError (TPat a)
parseTPat input = runParser parser (initialState "<input>") "" input
  where
    parser :: TidalParser (TPat a)
    parser = pTidal <* eof

-- | Alias for parseTPat with a friendlier name
parseMini :: forall a. AtomParseable a => String -> Either ParseError (TPat a)
parseMini = parseTPat

-- | Short alias for String patterns (most common use case)
parse :: String -> Either ParseError (TPat String)
parse = parseTPat

-- | Parse a single chord expression
-- |
-- | This parses chord notation like:
-- | - `c'major` - C major chord
-- | - `e'minor` - E minor chord
-- | - `'major` - Major chord (root defaults to C)
-- |
-- | Returns a TPat_Stack of notes for the chord.
parseChord :: String -> Either ParseError (TPat Note)
parseChord input = runParser parser (initialState "<input>") "" input
  where
    parser :: TidalParser (TPat Note)
    parser = pNoteChord <* eof
