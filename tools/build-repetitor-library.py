#!/usr/bin/env python3
"""Bake a Repetitor library JSON file into an Erlang module.

Reads `priv/libraries/<bank>.json` and emits `src/repetitor_library_<bank>.erl`
exposing `patterns/0`, `pattern/1`, and `names/0`.

Each JSON entry has: {name, length, m, c1, c2, c3} where m/c1/c2/c3 are
bit-arrays of `length` cells (0 or 1).

Run from repo root:

    python3 tools/build-repetitor-library.py zr_african

The output Erlang module is named `repetitor_library_<bank>` and the bank
identifier is the json filename minus `.json`.
"""
import json
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

def slugify(name):
    """Pattern names → safe Erlang atoms: lowercase + underscores."""
    out = []
    for c in name.lower():
        if c.isalnum():
            out.append(c)
        elif c in (' ', '-'):
            out.append('_')
    return ''.join(out).strip('_')

def emit(bank):
    src = REPO / "priv" / "libraries" / f"{bank}.json"
    if not src.exists():
        sys.exit(f"no such library: {src}")
    patterns = json.loads(src.read_text())

    mod = f"repetitor_library_{bank}"
    out = REPO / "src" / f"{mod}.erl"

    lines = []
    lines.append(f"%% Auto-generated from priv/libraries/{bank}.json by")
    lines.append(f"%% tools/build-repetitor-library.py.  Do not edit by hand.")
    lines.append(f"%%")
    lines.append(f"%% {len(patterns)} patterns; each entry has the shape")
    lines.append(f"%% #{{name, length, m, c1, c2, c3}}.")
    lines.append(f"-module({mod}).")
    lines.append(f"-export([patterns/0, pattern/1, names/0]).")
    lines.append("")
    lines.append("patterns() ->")
    lines.append("    [")
    for i, p in enumerate(patterns):
        bits = lambda r: "[" + ",".join(str(b) for b in p[r]) + "]"
        comma = "," if i + 1 < len(patterns) else ""
        lines.append(f'        #{{ name => <<"{p["name"]}">>,')
        lines.append(f'           slug => {slugify(p["name"])},')
        lines.append(f'           length => {p["length"]},')
        lines.append(f'           m  => {bits("m")},')
        lines.append(f'           c1 => {bits("c1")},')
        lines.append(f'           c2 => {bits("c2")},')
        lines.append(f'           c3 => {bits("c3")} }}{comma}')
    lines.append("    ].")
    lines.append("")
    lines.append("%% Lookup by slug atom or by binary name (case-insensitive).")
    lines.append("pattern(Key) when is_atom(Key) ->")
    lines.append("    lookup_by_slug(Key, patterns());")
    lines.append("pattern(Key) when is_binary(Key) ->")
    lines.append("    Lower = string:lowercase(Key),")
    lines.append("    lookup_by_name(Lower, patterns()).")
    lines.append("")
    lines.append("lookup_by_slug(_, []) -> not_found;")
    lines.append("lookup_by_slug(K, [P = #{slug := K} | _]) -> {ok, P};")
    lines.append("lookup_by_slug(K, [_ | Rest]) -> lookup_by_slug(K, Rest).")
    lines.append("")
    lines.append("lookup_by_name(_, []) -> not_found;")
    lines.append("lookup_by_name(K, [P = #{name := N} | Rest]) ->")
    lines.append("    case string:lowercase(N) =:= K of")
    lines.append("        true  -> {ok, P};")
    lines.append("        false -> lookup_by_name(K, Rest)")
    lines.append("    end.")
    lines.append("")
    lines.append("names() ->")
    lines.append("    [maps:get(name, P) || P <- patterns()].")
    lines.append("")

    out.write_text("\n".join(lines))
    print(f"wrote {out} ({len(patterns)} patterns)")

if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: build-repetitor-library.py <bank-name>")
    emit(sys.argv[1])
