# purescript-psd3-tidal

TidalCycles mini-notation parser for PureScript.

## Overview

A pure PureScript parser for TidalCycles mini-notation, the domain-specific language used in live coding music. This enables visualization and manipulation of Tidal patterns in PureScript applications.

## Installation

```bash
spago install psd3-tidal
```

## Features

- **Tidal.Parse.Parser** - Main parser entry point
- **Tidal.Parse.Combinators** - Parser combinators for mini-notation syntax
- **Tidal.AST.Types** - Abstract syntax tree types
- **Tidal.AST.Pretty** - Pretty printing for patterns
- **Tidal.Core.Types** - Core pattern types

## Supported Mini-Notation

- Sequences: `bd sn cp hh`
- Rests: `bd ~ sn ~`
- Parallel/polyrhythm: `[bd, sn, hh]`
- Fast/slow: `bd*4`, `sn/2`
- Euclidean rhythms: `bd(3,8)`
- Alternation: `<bd sn cp>`
- Elongation: `bd@2`
- Replication: `bd!3`
- Probability: `bd?0.5`

## Example

```purescript
import Tidal.Parse.Parser (parseMiniNotation)

main = case parseMiniNotation "bd [sn, cp*2] hh" of
  Right pattern -> log $ show pattern
  Left err -> log $ "Parse error: " <> err
```

## License

GPL-3.0-or-later (matching TidalCycles licensing)
