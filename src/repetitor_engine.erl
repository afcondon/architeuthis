%% Zularic-Repetitor-inspired virtual module — algorithm core.
%%
%% Engine model (per 2026-05-19 rig measurement, captured in memory
%% project_zr_offset_semantics_hypothesis): each named pattern is FOUR
%% independent bit-arrays of equal length (M, C1, C2, C3).  Knob
%% "offset" phase-shifts each row's own pattern.  Children do NOT
%% derive from Mother.  No cycle-shortening / polyrhythm-via-knob.
%%
%%     output_row(Pattern, Row, Step, Offset)
%%         = (row_bits(Pattern, Row))[(Step - Offset) mod len]
%%
%% Pure functions; per-instance state lives in repetitor_voice.
%% Mirror of balistes_engine.erl shape.
%%
%% References:
%%   docs/zr-virtual-module-plan.md
%%   memory/project_zr_offset_semantics_hypothesis.md
-module(repetitor_engine).

-export([
    rows/0,
    row_bits/2,
    output_row/4,
    evaluate_step/3,
    pattern_length/1
]).

%% --------------------------------------------------------------------
%% Public types
%% --------------------------------------------------------------------
%%
%% Pattern :: #{ name :: binary(), slug :: atom(), length :: pos_integer(),
%%               m, c1, c2, c3 :: [0|1] }
%% Row :: m | c1 | c2 | c3
%% Step :: non_neg_integer()
%% Offset :: integer() — any integer; modulo applied internally
%% Offsets :: #{ m, c1, c2, c3 => Offset }

%% --------------------------------------------------------------------
%% rows/0 — canonical row order.  Walkers + voices iterate this list.
%% --------------------------------------------------------------------
rows() -> [m, c1, c2, c3].

%% --------------------------------------------------------------------
%% row_bits/2 — pull a row's bit array out of a pattern map.
%% --------------------------------------------------------------------
row_bits(#{m  := B}, m)  -> B;
row_bits(#{c1 := B}, c1) -> B;
row_bits(#{c2 := B}, c2) -> B;
row_bits(#{c3 := B}, c3) -> B.

%% --------------------------------------------------------------------
%% pattern_length/1 — pattern cycle length in steps.
%% --------------------------------------------------------------------
pattern_length(#{length := L}) -> L.

%% --------------------------------------------------------------------
%% output_row(Pattern, Row, Step, Offset) -> 0 | 1
%%
%% Reads bit at position (Step - Offset) mod length from the row's
%% bit array.  Negative results wrap (Erlang's `rem` doesn't wrap
%% negatives correctly for our purposes — use the explicit form).
%% --------------------------------------------------------------------
output_row(Pattern, Row, Step, Offset) ->
    L = pattern_length(Pattern),
    Bits = row_bits(Pattern, Row),
    Idx = mod(Step - Offset, L),
    lists:nth(Idx + 1, Bits).

%% --------------------------------------------------------------------
%% evaluate_step(Pattern, Step, Offsets) -> [{Row, Bit}, ...]
%%
%% Convenience wrapper: returns one element per Row in canonical
%% order, with that row's output for this step.  The voice gen_server
%% filters to bits == 1 and emits MIDI for those rows.
%% --------------------------------------------------------------------
evaluate_step(Pattern, Step, Offsets) when is_map(Offsets) ->
    [{Row, output_row(Pattern, Row, Step, maps:get(Row, Offsets, 0))}
     || Row <- rows()].

%% --------------------------------------------------------------------
%% Helper: mathematical modulo that always returns a non-negative
%% result (Erlang's `rem` returns a value with the sign of the
%% dividend, which breaks negative-offset wrap-around).
%% --------------------------------------------------------------------
mod(A, B) when B > 0 ->
    ((A rem B) + B) rem B.
