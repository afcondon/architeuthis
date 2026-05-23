-- | Tidal.Voices — Symbol-kinded voice names for compile-time safety.
-- |
-- | The voice name is the dispatcher key for arms: a Conductor tick fires
-- | an `ArmCommand` carrying `mvoice :: String`, and the runtime routes
-- | by that string.  Pre-Voices, voice names were String literals at
-- | every `on` call site — a typo like `on "fuge" bass1 …` typechecked
-- | and silently misrouted.  With `VoiceName s`, the name is reified
-- | into a type-level Symbol declared once in this module; a typo
-- | becomes a name-resolution error at compile time.
-- |
-- | The friction is intentional: adding a new voice requires adding a
-- | declaration here.  That forces the voice vocabulary to live in one
-- | place rather than appearing implicitly via string literals scattered
-- | across sessions.
-- |
-- | Naming: the `v` prefix avoids collisions with instrument
-- | destinations (`bass1`), Part value names (`held1`), and pre-existing
-- | combinators (`Tidal.Fugue.fugueVoice`).  Easily bikeshed-able.
module Tidal.Voices
  ( VoiceName(..)
  , voiceNameString
  , vBass
  , vDrums
  , vFugue
  , vHeld1
  , vUpper
  ) where

import Data.Symbol (class IsSymbol, reflectSymbol)
import Type.Proxy (Proxy(..))

-- | A voice name, indexed by its type-level Symbol.
-- |
-- |     vBass :: VoiceName "bass"
-- |     vBass = VoiceName
data VoiceName (s :: Symbol) = VoiceName

-- | Reflect the symbol to a runtime String for the dispatcher /
-- | conductor — where `mvoice` is still a String today.  The String
-- | leaves the type system at this boundary and travels into the
-- | Erlang side via the ArmCommand wire format.
voiceNameString :: forall s. IsSymbol s => VoiceName s -> String
voiceNameString _ = reflectSymbol (Proxy :: Proxy s)

-- ---------------------------------------------------------------------------
-- The voice vocabulary — declared once, imported everywhere.
-- Adding a new voice: add a binding here, then `on newVoice …` works.
-- ---------------------------------------------------------------------------

-- | Generic pitched bass voice — used by tintinnabuli, mini/d patterns,
-- | bass parts.  Appears across most pitched sessions.
vBass :: VoiceName "bass"
vBass = VoiceName

-- | Drum-kit voice — fires through `qd1`, `qd2`, `gateKit` etc.
vDrums :: VoiceName "drums"
vDrums = VoiceName

-- | Fugue Machine voice — the four playheads (fugue1..fugue4) share
-- | a single voice name; they're distinguished by their instrument
-- | (bass1..bass4) not by voice.
vFugue :: VoiceName "fugue"
vFugue = VoiceName

-- | Vetula held-chord voice — long-sustained chord parts driven by
-- | `vetulaHeld` and friends.
vHeld1 :: VoiceName "held1"
vHeld1 = VoiceName

-- | Upper-voices voice — the treble pair of a bass/upper split (see
-- | `vetulaSplit` and Vetula Experiment 1).
vUpper :: VoiceName "upper"
vUpper = VoiceName
