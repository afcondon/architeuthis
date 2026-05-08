-- | FFI wrapper around `application:ensure_started/1` for the
-- | `purerl_tidal` OTP application.
-- |
-- | The OTP application defines the supervision tree:
-- |   purerl_tidal_sup
-- |   ├── tidal_voice_sup
-- |   ├── tidal_dispatcher
-- |   └── tidal_clock
-- |
-- | `Main.purs` calls `startApplication` early in boot to bring up the
-- | tree. Idempotent — safe to call repeatedly. Crashes the calling
-- | process (via `error/1`) if the start fails so the failure is loud,
-- | not silent.
module Tidal.Application
  ( startApplication
  ) where

import Prelude

import Effect (Effect)

foreign import startApplication :: Effect Unit
