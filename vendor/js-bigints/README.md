# js-bigints, for purerl

A port of [`js-bigints`](https://github.com/purescript-contrib/purescript-js-bigints)
2.2.1 to the Erlang backend: upstream's `JS/BigInt.purs` with a `BigInt.erl`
beside it, so code written against the registry's `JS.BigInt` compiles
unchanged on the BEAM. purerl-tidal's engine core is written against it, and
builds on JS with the registry package and on the BEAM with this one.

- **Same API, less two.** `fromTLInt` and `parity` are left out: the purerl
  package set (erl-0.15.3, the newest there is) has neither `Data.Reflectable`
  nor `Data.Int.Parity`.
- **Same semantics, as implemented.** The reference is upstream's `BigInt.js`,
  not its doc comments, where they disagree: `fromString "5e1"` and
  `fromNumber 1.5` are both `Nothing`, as `BigInt()` makes them.
- **Upstream bug noted, not copied:** `biDegree` returns a JS BigInt where its
  type promises an `Int`. Here it returns an integer, which is both.

Upstream licence: MIT (`LICENSE`). A candidate for the purerl organisation's
`-erl` forks.
