# License Notice

This project is licensed under the **GNU General Public License, version 3 or
any later version (GPLv3-or-later, SPDX: `GPL-3.0-or-later`)**.

The full GPLv3 text is in `LICENSE`.

## Why GPL?

`purerl-tidal` is a port of [TidalCycles](https://tidalcycles.org/) (Alex
McLean and contributors) to PureScript with an Erlang backend. TidalCycles
is GPLv3-licensed, and this port is a derivative work.

Significant portions of the code in this repository are translations of
TidalCycles' Haskell source: the mini-notation parser, the pattern algebra,
and the scheduling engine all derive directly from the upstream design.
Substantial new work (the OSC/MIDI/CV-Gate output layer, the Erlang
WebSocket server, the bundled showcase frontends in sibling repos) is
also under GPLv3 to keep the whole derivative-work chain consistent.

## Sibling repos

The `purerl-tidal` "constellation" of music-making tools is split into
several repos by license-compatibility constraints:

- `purerl-tidal` (this repo) — GPLv3, TidalCycles derivative
- `link-spike` — GPLv2-or-later, Ableton Link derivative
- `cv-router` — MIT, no derivative dependencies; talks OSC to anyone
- `es9-config` — MIT, vendored midi.js (also MIT, Expert Sleepers)

The license firewall is the network protocol boundary: cv-router receives
OSC messages from purerl-tidal but is not statically linked, so its license
is unaffected by either GPL.

Copyright (c) 2026 Andrew Condon, plus all contributors to the upstream
TidalCycles project.
