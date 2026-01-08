# Tidal Feature Parity Plan

This document tracks progress toward matching the TidalCycles Haskell test suite.
Work can be done incrementally across multiple sessions.

**Reference**: `/Users/afc/work/afc-work/GitHub/Tidal/tidal-core/test/`

## Current Status

- **purerl-tidal tests**: 122
- **Tidal test lines**: ~2400+
- **Last updated**: 2026-01-08

---

## Phase 1: Parser Enhancements (Priority: High)

Essential parser features that expand mini-notation expressiveness.

### 1.1 Range Operator `..`
- [ ] Integer ranges: `0 .. 8`
- [ ] Decimal ranges: `0.0 .. 8.0`
- [ ] Note ranges: `c4 .. c6`
- [ ] Ranges without spaces: `0..8`
- [ ] Tests for range expansion

**Files**: `Tidal.Parse.Combinators`, `Tidal.Parse.Class`

### 1.2 Ratio/Duration Shorthand
- [ ] Half note: `3h`, `-2h`
- [ ] Quarter note: `1q`, `1.5q`
- [ ] Eighth note: `2e`
- [ ] Exponential notation: `1e3`, `400e-3`
- [ ] Combined: `4e2q`

**Files**: `Tidal.Parse.Class` (Rational instance)

### 1.3 Dot Grouping Operator
- [ ] Basic dot grouping: `bd sd . hh hh hh`
- [ ] Nested with brackets: `[bd sd] . hh`
- [ ] Multiple dots: `a . b . c . d`

**Files**: `Tidal.Parse.Combinators`

### 1.4 Dash for Silence
- [ ] `-` as alternative to `~`
- [ ] In sequences: `bd - sn`
- [ ] In groups: `[bd - -]`

**Files**: `Tidal.Parse.Combinators` (pSilence)

### 1.5 Advanced Chord Modifiers
- [ ] Inversions: `c'major'i`, `c'major'i2`, `c'major'iii`
- [ ] Open voicing: `c'major'o`
- [ ] Drop voicing: `c'major'd1`, `c'major'd2`
- [ ] Chord spread/range: `c'major'5`
- [ ] Patterned modifiers: `c'major'<i 5>`
- [ ] Patterned chord names: `c'<major minor>`
- [ ] Patterned roots: `<c e>'major`

**Files**: `Tidal.Parse.Class` (Note patternParser), `Tidal.Chords`

---

## Phase 2: Scales System (Priority: High)

Musical scales are essential for pitched pattern work.

### 2.1 Scale Infrastructure
- [ ] `Scale` type definition
- [ ] `scale` function: `scale "major" "0 2 4"`
- [ ] Scale lookup by name
- [ ] Degree-to-semitone conversion

**Files**: New `Tidal.Scales` module

### 2.2 Common Scales (7-note)
- [ ] major, minor (natural/aeolian)
- [ ] dorian, phrygian, lydian, mixolydian, locrian
- [ ] harmonicMinor, harmonicMajor
- [ ] melodicMinor, melodicMajor

### 2.3 Pentatonic Scales (5-note)
- [ ] minPent, majPent
- [ ] ritusen, egyptian
- [ ] kumai, hirajoshi, iwato
- [ ] chinese, indian, pelog

### 2.4 Other Scales
- [ ] whole (whole tone)
- [ ] chromatic (12-note)
- [ ] diminished, octatonic
- [ ] prometheus, scriabin
- [ ] messiaen modes (1-7)
- [ ] spanish, enigmatic, hungarian

### 2.5 Scale Tests
- [ ] All scale definitions verified
- [ ] Edge cases (unknown scale, negative degrees)
- [ ] Scale with transposition

---

## Phase 3: Pattern Transformations (Priority: High)

Core pattern manipulation functions.

### 3.1 Segment/Discretize
- [ ] `segment n pat` - discretize to n events per cycle
- [ ] Continuous pattern discretization
- [ ] Value holding across segments

**Files**: `Tidal.Pattern.Combinators` or new module

### 3.2 Chop/Slice (Beatslicing)
- [ ] `chop n` - chop each event into n pieces
- [ ] `slice n pat` - select slice by pattern
- [ ] `splice n pat` - beatslice with pattern
- [ ] `_chop` with begin/end params

### 3.3 Echo/Stutter Effects
- [ ] `echo n time gain` - echo with decay
- [ ] `echoWith n time f` - echo with function
- [ ] `stut n gain time` - stutter
- [ ] `stutWith n f time` - stutter with function

### 3.4 Compress/Zoom
- [ ] `compress (start, end) pat` - squash to region
- [ ] `zoom (start, end) pat` - extract and stretch
- [ ] Boundary handling

### 3.5 Offset Transformations
- [ ] `off time f pat` - apply f with offset
- [ ] `<~` rotation operator
- [ ] `~>` rotation operator

---

## Phase 4: Stepwise Operations (Priority: Medium)

Pattern operations that work step-by-step.

### 4.1 Core Stepwise Functions
- [ ] `stepcat` - stepwise concatenation
- [ ] `steptake n` - take first n steps
- [ ] `stepdrop n` - drop first n steps
- [ ] Step count preservation

### 4.2 Expansion/Iteration
- [ ] `expand` - expand with duration pattern
- [ ] `linger` - linger on pattern portion
- [ ] `iter n` - iterate through pattern
- [ ] `iter'` - reverse iteration

---

## Phase 5: Control Parameters (Priority: Medium)

Named control patterns for synthesis parameters.

### 5.1 Core Controls
- [ ] `sound` / `s` - sample name
- [ ] `note` / `n` - note/pitch
- [ ] `gain` - volume
- [ ] `pan` - stereo position
- [ ] `speed` - playback speed

### 5.2 Pattern Merging
- [ ] `#` operator for combining controls
- [ ] `|>|` structure merge
- [ ] `|+|`, `|*|`, `|-|` arithmetic merge
- [ ] `|>`, `|<` directional merge

### 5.3 Oscillator Patterns
- [ ] `sine` - sine wave 0-1
- [ ] `cosine` - cosine wave
- [ ] `saw` - sawtooth
- [ ] `tri` - triangle
- [ ] `square` - square wave
- [ ] `rand` - random values
- [ ] `irand n` - random integers

---

## Phase 6: Pattern Laws & Properties (Priority: Medium)

Verify algebraic correctness.

### 6.1 Monoid Laws
- [ ] Identity: `mempty <> x = x`
- [ ] Associativity: `(x <> y) <> z = x <> (y <> z)`
- [ ] Silence behavior with operators

### 6.2 Functor Laws
- [ ] `fmap id = id`
- [ ] `fmap (f . g) = fmap f . fmap g`

### 6.3 Applicative Laws
- [ ] `<*>` operator properties
- [ ] `*>` and `<*` behavior
- [ ] Structure preservation

### 6.4 Pattern-Specific Properties
- [ ] Query boundary conditions
- [ ] Cross-cycle queries
- [ ] Zero-length arc handling

---

## Phase 7: Advanced Parser Tests (Priority: Low)

Edge cases and error handling.

### 7.1 Comment Support
- [ ] Single-line comments: `-- comment`
- [ ] Multi-line comments: `{- comment -}`
- [ ] Comments in patterns

### 7.2 Error Cases
- [ ] Invalid syntax errors
- [ ] Type mismatches (float in int pattern)
- [ ] Unknown chord/scale names
- [ ] Malformed ratios

### 7.3 Complex Nesting
- [ ] Deeply nested groups
- [ ] Mixed operators
- [ ] Operator precedence

---

## Phase 8: Utility Functions (Priority: Low)

Helper functions for pattern manipulation.

### 8.1 Tuple Utilities
- [ ] `delta` - difference
- [ ] `mid` - midpoint
- [ ] `mapBoth`, `mapFst`, `mapSnd`

### 8.2 List Utilities
- [ ] `nth` - safe indexing
- [ ] `accumulate` - accumulation
- [ ] `enumerate` - with indices
- [ ] `wordsBy` - split by predicate
- [ ] `removeCommon` - set difference

---

## Progress Tracking

| Phase | Description | Status | Tests Added |
|-------|-------------|--------|-------------|
| 1.1 | Range operator | Not started | 0 |
| 1.2 | Ratio shorthand | Not started | 0 |
| 1.3 | Dot grouping | Not started | 0 |
| 1.4 | Dash silence | Not started | 0 |
| 1.5 | Chord modifiers | Not started | 0 |
| 2.x | Scales system | Not started | 0 |
| 3.x | Transformations | Not started | 0 |
| 4.x | Stepwise ops | Not started | 0 |
| 5.x | Control params | Not started | 0 |
| 6.x | Pattern laws | Not started | 0 |
| 7.x | Advanced parser | Not started | 0 |
| 8.x | Utilities | Not started | 0 |

**Total**: 122 tests (baseline)

---

## Implementation Notes

### Module Structure
```
src/Tidal/
  Scales.purs          -- NEW: Scale definitions
  Pattern/
    Combinators.purs   -- Pattern transformations
    Controls.purs      -- NEW: Control parameters
    Oscillators.purs   -- NEW: Continuous patterns
```

### Test Organization
```
test/Test/
  PatternSpec.purs     -- Existing (expand)
  ScalesSpec.purs      -- NEW
  TransformSpec.purs   -- NEW
  ControlSpec.purs     -- NEW
  ParserSpec.purs      -- NEW (dedicated parser tests)
```

### Dependencies
- Some features may need additional FFI for Erlang
- Oscillators need continuous signal support
- Controls need ControlPattern infrastructure

---

## Session Log

Track work done in each session:

### Session 1 (2026-01-08)
- Created initial test suite (77 tests)
- Fixed Bjorklund edge case
- Added Note parsing (17 tests)
- Added chord parsing (23 tests)
- Added chord sequence integration (5 tests)
- **Final count**: 122 tests

### Session 2
- (Next session work goes here)

---

## References

- Tidal source: `/Users/afc/work/afc-work/GitHub/Tidal`
- Test files:
  - `tidal-core/test/Sound/Tidal/ParseTest.hs` (368 tests)
  - `tidal-core/test/Sound/Tidal/CoreTest.hs`
  - `tidal-core/test/Sound/Tidal/ScalesTest.hs`
  - `tidal-core/test/Sound/Tidal/UITest.hs`
  - `tidal-core/test/Sound/Tidal/StepwiseTest.hs`
  - `tidal-core/test/Sound/Tidal/ControlTest.hs`
