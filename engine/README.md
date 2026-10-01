# The engine

Tidal's patterns, mini-notation and line language, as one PureScript source
that compiles to both the BEAM (purerl-tidal) and JS (Triggerfish), laid out
as a [polyglot-template](../../../../polyglot/polyglot-template) program:

```
core/                  the engine; the only place its logic lives
  src/Haskell/*        reference-semantics types: Int, Integer, Rational,
                       Double, Parsec, each specified as "what GHC does"
  src/Haskell/Double.{js,erl}   the one seam (libm, and floor)
  src/Tidal/*          patterns, parser, interpreter, controls, line language
  src/Tidal/Conformance*        the suite, pure, with its goldens
  oracle/              how the goldens are made: GHC, Text.Parsec and
                       GHCi running Tidal 1.10.1 (via Limulus's GHC)
columns/node/          the registry package set, the JS backend
columns/erlang/        the purerl package set, purs-backend-erl
```

`poly run all` (from here, with polyglot-template's `bin/poly`), or
`make conformance` in purerl-tidal, runs the suite in every column: the claim
is that GHC, the BEAM and JS give the same answers, case for case.

**What core may depend on:** only packages whose API is the same in both
package sets. That is why the engine has its own Parsec rather than the
`parsing` library (6 in the purerl set, 11 in the registry), its own
`Rational` rather than `Data.Rational` (an alias over `Int` in one, a newtype
over `BigInt` in the other), and `Haskell.Double` rather than `Math`.
`js-bigints` is the registry's on JS and the purerl port in
`../vendor/js-bigints` on the BEAM.

**Divergence is flagged:** where the engine means something other than
PureScript's standard libraries, it imports a module named for the reference
(`Haskell.*`), and each one is held to GHC by `oracle/haskell-prim.txt`.
`src/Haskell` imports nothing from `Tidal.*` (`make haskell-is-standalone`).

Regenerate the goldens with `make oracle-prim` (GHC) and `make oracle-tidal`
(GHCi Tidal behind Limulus on :3036), from purerl-tidal.
