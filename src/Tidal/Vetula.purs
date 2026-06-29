-- | `Tidal.Vetula` — re-export shim.
-- |
-- | The harmonic-recipe layer (Numeral/Quality/Tension/Mode/Key/DegreeChord →
-- | `realize`) now lives in the published `harmonia` package as
-- | `Harmonia.Chord`. This module re-exports it under the historical
-- | `Tidal.Vetula` name so `Tidal.Vetula.Pattern` (the BEAM/Notation glue) and
-- | the sessions keep their imports unchanged. The theory is no longer vendored
-- | here — edit it in `harmonia` and every consumer (this repo, Vetula,
-- | Triggerfish) picks it up.
module Tidal.Vetula (module Harmonia.Chord) where

import Harmonia.Chord
