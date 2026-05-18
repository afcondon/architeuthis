#!/usr/bin/env python3
"""Bake the Mutable Instruments Grids drum-map tables into Erlang.

Reads `nodes = [...]` from the upstream firmware's lookup_tables.py and
emits a `grids_tables.erl` module that returns each of the 25 nodes as
a 96-byte binary plus the 5x5 index table from pattern_generator.cc.

Run from purerl-tidal repo root:

    python3 tools/extract-grids-tables.py > src/grids_tables.erl

Source: stages-firmware/grids/resources/lookup_tables.py
        stages-firmware/grids/pattern_generator.cc lines 69-75

Re-generate whenever the upstream tables change (which is rare — they
haven't moved since 2012).
"""
import os
import re
import sys
import textwrap

SRC = os.path.expanduser(
    "~/work/afc-work/music/stages-firmware/grids/resources/lookup_tables.py"
)


def parse_nodes(path):
    text = open(path).read()
    m = re.search(r"nodes\s*=\s*(\[\s*\[.*?\]\s*\])\s*\n\nfor", text, re.DOTALL)
    if not m:
        sys.exit(f"could not find `nodes = [...]` block in {path}")
    nodes = eval(m.group(1))  # safe: known data file
    assert len(nodes) == 25, f"expected 25 nodes, got {len(nodes)}"
    for i, n in enumerate(nodes):
        assert len(n) == 96, f"node {i} has {len(n)} bytes, not 96"
        assert all(0 <= b <= 255 for b in n), f"node {i} has out-of-range bytes"
    return nodes


# Index table from pattern_generator.cc:69-75.  Each (i, j) cell of the
# 5x5 maps to one of the 25 nodes.
DRUM_MAP = [
    [10, 8, 0, 9, 11],
    [15, 7, 13, 12, 6],
    [18, 14, 4, 5, 3],
    [23, 16, 21, 1, 2],
    [24, 19, 17, 20, 22],
]


def emit():
    nodes = parse_nodes(SRC)
    out = []
    p = out.append
    p("%% Auto-generated from stages-firmware/grids/resources/lookup_tables.py")
    p("%% by tools/extract-grids-tables.py.  Do not edit by hand.")
    p("%%")
    p("%% 25 drum-map nodes, each 96 bytes = 3 instruments x 32 steps.")
    p("%% Layout per node: byte at offset (instrument * 32 + step) is the")
    p("%% intensity (0..255) for that instrument at that step.")
    p("%%")
    p("%% drum_map(I, J) for I,J in 0..4 returns the binary for node[I][J]")
    p("%% in the 5x5 grid (per pattern_generator.cc:69-75).")
    p("-module(grids_tables).")
    p("-compile({no_auto_import, [node/1]}).")
    p("-export([node/1, drum_map/2, num_nodes/0]).")
    p("")
    p("num_nodes() -> 25.")
    p("")
    for i, n in enumerate(nodes):
        # Wrap on whole-byte boundaries (16 bytes per line) — Erlang
        # binary literals can't tolerate newlines mid-number.
        parts = [str(b) for b in n]
        lines = []
        for k in range(0, len(parts), 16):
            chunk = parts[k:k + 16]
            lines.append("    " + ",".join(chunk))
        body = ",\n".join(lines)
        p(f"node({i}) ->")
        p(f"    <<\n{body}>>;")
    p("node(_) -> erlang:error(badarg).")
    p("")
    p("%% Index table from pattern_generator.cc:69-75: drum_map[5][5].")
    for i, row in enumerate(DRUM_MAP):
        for j, idx in enumerate(row):
            terminator = "." if (i == 4 and j == 4) else ";"
            p(f"drum_map({i}, {j}) -> node({idx}){terminator}")
    print("\n".join(out))


if __name__ == "__main__":
    emit()
