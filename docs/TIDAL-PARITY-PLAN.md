# Tidal Feature Parity Plan

This document tracks progress toward matching the TidalCycles Haskell test suite.
Work can be done incrementally across multiple sessions.

> **See also**: [`live-coding-feasibility.md`](live-coding-feasibility.md)
> — broader design exploration of how purerl-tidal might evolve
> toward GHCI-flavoured live coding. Compares our architecture to
> TidalCycles' GHCI+SuperDirt split, measures compile-latency, and
> sketches the per-track BEAM decomposition. Not parity-test
> material but useful design context.

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
- [x] `steptake n` - take first n steps
- [x] `stepdrop n` - drop first n steps

### 4.2 Expansion/Iteration
- [x] `linger` - linger on pattern portion (stretch first part)
- [x] `trunc` - truncate pattern (zoom to first part)
- [x] `iter n` - iterate through pattern
- [x] `iter'` - reverse iteration

---

## Phase 5: Control Parameters (Priority: Medium)

Named control patterns for synthesis parameters.

### 5.1 Core Controls
- [x] `sound` / `s` - sample name
- [x] `note` / `n` - note/pitch
- [x] `gain` - volume
- [x] `pan` - stereo position
- [x] `speed` - playback speed
- [x] `begin`, `end`, `loop` - sample position controls
- [x] `cut` - cut groups
- [x] `delay`, `delaytime`, `delayfeedback` - delay FX controls

### 5.2 Pattern Merging
- [x] `#` operator for combining controls
- [x] `|>|` structure merge (both)
- [x] `|+`, `|*`, `|-`, `|/` arithmetic merge
- [x] `|>` directional merge (right structure)

### 5.3 Oscillator Patterns
- [x] `sine` - sine wave 0-1
- [x] `cosine` - cosine wave
- [x] `saw` - sawtooth (rising)
- [x] `isaw` - inverse sawtooth (falling)
- [x] `tri` - triangle wave
- [x] `square` - square wave
- [x] `rand` - pseudorandom values (deterministic)
- [x] `irand n` - random integers 0 to n-1

---

## Phase 6: Pattern Laws & Properties (Priority: Medium)

Verify algebraic correctness.

### 6.1 Monoid Laws
- [x] Stack associativity: `stack [stack [a, b], c] = stack [a, stack [b, c]]`
- [x] Stack with silence: `stack [pat, silence] = pat`
- [x] Silence produces no events

### 6.2 Functor Laws
- [x] `fmap id = id`
- [x] `fmap (f . g) = fmap f . fmap g`

### 6.3 Transformation Properties
- [x] `fast n . slow n = id`
- [x] `slow n . fast n = id`
- [x] `rotL t . rotR t = id`
- [x] `rev . rev = id`

### 6.4 Query Boundary Conditions
- [x] Empty arc returns no events
- [x] Single cycle returns correct events
- [x] Cross-cycle queries return all events
- [x] Fractional arc correctly slices events

---

## Phase 7: Advanced Parser Tests (Priority: Low)

Edge cases and complex pattern handling.

### 7.1 Complex Nesting
- [x] Deeply nested groups: `[[[bd]]]`
- [x] Mixed group types: `<[bd sn] [hh cp]>`
- [x] Stacks in sequence: `[bd, sn] [hh, cp]`

### 7.2 Mixed Operators
- [x] Fast and slow in sequence: `bd*2 sn/2`
- [x] Nested fast: `[bd*2]*2`
- [x] Multiple degrades: `bd? sn? hh?`

### 7.3 Edge Cases
- [x] Long sequences: 5+ elements
- [x] Single element groups: `[bd]`, `<bd>`
- [x] Euclidean edge cases: `bd(1,1)`, `bd(8,8)`

---

## Phase 8: Utility Functions (Priority: Low)

Helper functions for pattern manipulation.

### 8.1 Tuple Utilities
- [x] `delta` - difference between tuple elements
- [x] `mid` - midpoint between tuple elements
- [x] `mapBoth`, `mapFst`, `mapSnd` - tuple mapping

### 8.2 List Utilities
- [x] `nth` - safe indexing
- [x] `accumulate` - running accumulation
- [x] `enumerate` - with indices
- [x] `removeCommon` - set difference

---

## Progress Tracking

| Phase | Description | Status | Tests Added |
|-------|-------------|--------|-------------|
| 1.1 | Range operator | ✓ Complete | +3 |
| 1.2 | Ratio shorthand | ✓ Complete | 0 |
| 1.3 | Dot grouping | ✓ Complete | +3 |
| 1.4 | Dash silence | ✓ Complete | +4 |
| 1.5 | Chord modifiers | ✓ Complete | +7 |
| 2.x | Scales system | ✓ Complete | +11 |
| 3.x | Transformations | ✓ Complete | +6 |
| 4.x | Stepwise ops | ✓ Complete | +2 |
| 5.x | Control params | ✓ Complete | +14 |
| 5.3 | Oscillators | ✓ Complete | +16 |
| 6.x | Pattern laws | ✓ Complete | +13 |
| 7.x | Advanced parser | ✓ Complete | +16 |
| 8.x | Utilities | ✓ Complete | +14 |

**Total**: 230 tests (baseline 122 + 108 new)

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
