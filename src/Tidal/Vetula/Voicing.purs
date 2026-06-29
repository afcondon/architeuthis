-- | `Tidal.Vetula.Voicing` — re-export shim.
-- |
-- | The voicing / voice-leading layer now lives in the published `harmonia`
-- | package as `Harmonia.Voicing`. This module re-exports it under the
-- | historical `Tidal.Vetula.Voicing` name so `Tidal.Vetula.Pattern` keeps its
-- | imports unchanged. No logic here — edit it in `harmonia`.
module Tidal.Vetula.Voicing (module Harmonia.Voicing) where

import Harmonia.Voicing
