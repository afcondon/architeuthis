%% Make-Noise-René-inspired machine — algorithm core.
%%
%% Third BEAM-native machine, after Grids and Repetitor.  Unlike
%% those two, René takes user-supplied note content (16 notes the
%% user writes) + user-supplied modal arrays (skip, gate, glide) +
%% autonomous traversal driven by external clock pulses (X-clock and
%% optionally Y-clock).  See `project_machines_naming` for the
%% "user-content × external-clock" hybrid position in the spectrum.
%%
%% State:
%%
%%   #{notes => [Int; 16],   -- MIDI note values; 60 = middle C
%%     skip  => [Bool; 16],  -- true = position is hopped over
%%     gate  => [Bool; 16],  -- false = position lands but no emit
%%     glide => [Bool; 16],  -- portamento marker (carried to MIDI, no engine effect yet)
%%     x     :: 0..3,        -- column index
%%     y     :: 0..3,        -- row index
%%     nav_mode :: cartesian | forward | reverse}
%%
%% Index into the 16-step sequence is `y * 4 + x` (row-major).
%%
%% step_x/1 — advance one cell in the current nav_mode along X.  In
%% cartesian mode only X moves; in forward/reverse the (x,y) pair
%% advances as a single linear cursor.
%%
%% step_y/1 — advance Y (cartesian only; no-op in others).
%%
%% current_event/1 — read the cell at (x,y) and decide what to emit.
%% Returns:
%%
%%   {emit, Note, Idx}      -- fire MIDI note Note from cell Idx
%%   {silent_step, Idx}     -- cell exists, gate is closed, no fire
%%   skipped                -- skipped cells are never returned;
%%                             step_x/step_y skip past them already
%%
%% Skip-aware traversal walks at most 16 cells looking for a non-skip
%% landing; if all 16 are skipped, the position stays put.
-module(rene_engine).

-export([
    new/1,
    step_x/1,
    step_y/1,
    current_event/1,
    nav_modes/0,
    set_field/3
]).

%% --------------------------------------------------------------------
%% nav_modes/0 — supported navigation modes.
%% --------------------------------------------------------------------
nav_modes() -> [cartesian, forward, reverse].

%% --------------------------------------------------------------------
%% new(Config) — fresh engine state with sane defaults.
%% --------------------------------------------------------------------
new(Config) when is_map(Config) ->
    Sixteen = fun(K, Def) ->
        case maps:get(K, Config, undefined) of
            undefined -> lists:duplicate(16, Def);
            L when length(L) =:= 16 -> L;
            L -> normalise_16(L, Def)
        end
    end,
    #{
      notes    => Sixteen(notes,    60),
      skip     => Sixteen(skip,     false),
      gate     => Sixteen(gate,     true),
      glide    => Sixteen(glide,    false),
      x        => 0,
      y        => 0,
      nav_mode => maps:get(nav_mode, Config, cartesian)
     }.

%% Pad / truncate a user-supplied list to exactly 16.  Anything
%% shorter is right-padded with the default; longer is truncated.
normalise_16(L, Def) when is_list(L) ->
    case length(L) of
        N when N >= 16 -> lists:sublist(L, 16);
        N -> L ++ lists:duplicate(16 - N, Def)
    end.

%% --------------------------------------------------------------------
%% set_field(State, Field, Value) — replace one of the 16-element
%% arrays.  Used by live-mutation paths (Twister bank, cell re-fire).
%% --------------------------------------------------------------------
set_field(State, Field, Value) when Field =:= notes;
                                     Field =:= skip;
                                     Field =:= gate;
                                     Field =:= glide ->
    State#{Field := normalise_16(Value,
                                  default_for(Field))};
set_field(State, nav_mode, Mode) ->
    case lists:member(Mode, nav_modes()) of
        true  -> State#{nav_mode := Mode};
        false -> State
    end.

default_for(notes) -> 60;
default_for(_)     -> false.

%% --------------------------------------------------------------------
%% step_x(State) -> State'
%%
%% Advance along X.  In cartesian mode only X moves (with skip-aware
%% wrap).  In forward/reverse the (x,y) pair is treated as a single
%% linear cursor `Idx = y*4 + x` that advances ±1 with skip-aware
%% wrap.
%% --------------------------------------------------------------------
step_x(#{nav_mode := cartesian, x := X, y := Y, skip := Sk} = S) ->
    NewX = find_non_skipped_x(X, Y, Sk),
    S#{x := NewX};
step_x(#{nav_mode := forward, x := X, y := Y, skip := Sk} = S) ->
    Idx = Y * 4 + X,
    NewIdx = find_non_skipped_idx(Idx, +1, Sk),
    S#{x := NewIdx rem 4, y := NewIdx div 4};
step_x(#{nav_mode := reverse, x := X, y := Y, skip := Sk} = S) ->
    Idx = Y * 4 + X,
    NewIdx = find_non_skipped_idx(Idx, -1, Sk),
    S#{x := NewIdx rem 4, y := NewIdx div 4}.

%% step_y is only meaningful in cartesian mode; no-op otherwise.
step_y(#{nav_mode := cartesian, y := Y, x := X, skip := Sk} = S) ->
    NewY = find_non_skipped_y(X, Y, Sk),
    S#{y := NewY};
step_y(S) -> S.

%% find_non_skipped_x — starting from (X+1) mod 4 at row Y, walk
%% column-by-column until we hit a non-skipped cell or come back
%% around to the starting X.
find_non_skipped_x(StartX, Y, Sk) ->
    walk_x(StartX, (StartX + 1) rem 4, Y, Sk, 0).

walk_x(StartX, _, _, _, 4) -> StartX;  % wrapped — all 4 skipped
walk_x(StartX, X, Y, Sk, Steps) ->
    case lists:nth(Y * 4 + X + 1, Sk) of
        false -> X;
        true  -> walk_x(StartX, (X + 1) rem 4, Y, Sk, Steps + 1)
    end.

find_non_skipped_y(X, StartY, Sk) ->
    walk_y(X, StartY, (StartY + 1) rem 4, Sk, 0).

walk_y(_, StartY, _, _, 4) -> StartY;
walk_y(X, StartY, Y, Sk, Steps) ->
    case lists:nth(Y * 4 + X + 1, Sk) of
        false -> Y;
        true  -> walk_y(X, StartY, (Y + 1) rem 4, Sk, Steps + 1)
    end.

%% find_non_skipped_idx — linear-cursor variant for forward/reverse.
find_non_skipped_idx(StartIdx, Dir, Sk) ->
    Next = mod(StartIdx + Dir, 16),
    walk_idx(StartIdx, Next, Dir, Sk, 0).

walk_idx(StartIdx, _, _, _, 16) -> StartIdx;
walk_idx(StartIdx, Idx, Dir, Sk, Steps) ->
    case lists:nth(Idx + 1, Sk) of
        false -> Idx;
        true  -> walk_idx(StartIdx, mod(Idx + Dir, 16), Dir, Sk, Steps + 1)
    end.

%% --------------------------------------------------------------------
%% current_event(State) -> {emit, Note, Idx} | {silent_step, Idx}
%%
%% Caller already knows the cursor is on a non-skipped cell (step_*
%% guarantee).  We just check the gate to decide between emit and
%% silent-step.
%% --------------------------------------------------------------------
current_event(#{x := X, y := Y, notes := N, gate := G}) ->
    Idx = Y * 4 + X,
    case lists:nth(Idx + 1, G) of
        false -> {silent_step, Idx};
        true  -> {emit, lists:nth(Idx + 1, N), Idx}
    end.

%% --------------------------------------------------------------------
%% Helper: mathematical modulo (Erlang's rem returns the dividend's
%% sign; we need the divisor's sign for proper wrap of negative -1
%% offsets in reverse mode).
%% --------------------------------------------------------------------
mod(A, B) when B > 0 ->
    ((A rem B) + B) rem B.
