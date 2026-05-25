%% Make-Noise-René-inspired machine — multi-playhead algorithm core.
%%
%% Third BEAM-native machine, after Balistes and Repetitor.  Per Slab 6.2,
%% Odonus walks P independent playheads through one shared 16-cell grid;
%% each playhead carries its own cursor + phase-accumulator + (live-
%% Pattern-controllable) transposition and speed.  Single-playhead
%% sessions (`heads = 1`) are the degenerate case and behave identically
%% to pre-6.2.
%%
%% State:
%%
%%   #{notes => [Int; 16],   -- MIDI note values; 60 = middle C
%%     skip  => [Bool; 16],  -- true = position is hopped over
%%     gate  => [Bool; 16],  -- false = position lands but no emit
%%     glide => [Bool; 16],  -- portamento marker (carried, no engine effect)
%%     playheads => [#{cursor :: 0..15, accumulator :: float()}],
%%     nav_mode :: cartesian | forward | reverse}
%%
%% Index into the 16-step sequence is row-major: `y * 4 + x`.  All
%% playheads share notes/skip/gate/glide arrays and the nav_mode.  Per-
%% playhead speed and transposition come from the voice's snapshot
%% each step.
%%
%% advance_all/2 — for each playhead K, accumulator += speed[K]; advance
%% cursor by floor of new accumulator; carry the fractional remainder.
%% Speed 1.0 advances one cell per master tick (default).  Speed 0.5
%% advances every other tick.  Speed 2.0 jumps two cells per tick.
%% Speed is sampled fresh per step from snap.speed so it's live-
%% controllable.
%%
%% step_y_all/1 — in NavCartesian, advance each playhead's Y by 1 (jump
%% +4 in row-major); no-op in other nav modes.  Fires when the voice's
%% stepYNow pattern resolves true at this step's cycle position.
%%
%% current_cursors/1 — read-only access to per-playhead cursor positions
%% so the voice can emit MIDI for each (with per-playhead transp).
%%
%% Skip-aware traversal walks past skipped cells without firing; if all
%% 16 are skipped, the cursor stays put.
-module(odonus_engine).

-export([
    new/1,
    advance_all/3,
    step_y_all/1,
    current_cursors/1,
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
    Heads = max(1, maps:get(heads, Config, 1)),
    %% pend_step :: 1 | -1.  Tracks pendulum direction-state per
    %% playhead so a pend-mode head can flip at boundaries without
    %% needing global state.  Mode 0/1 (fwd/back) ignore this; mode 2
    %% (pend) reads + updates it on advance.
    Playheads = [#{cursor => 0, accumulator => 0.0, pend_step => 1} ||
                 _ <- lists:seq(1, Heads)],
    #{
      notes     => Sixteen(notes,    60),
      skip      => Sixteen(skip,     false),
      gate      => Sixteen(gate,     true),
      glide     => Sixteen(glide,    false),
      playheads => Playheads,
      nav_mode  => maps:get(nav_mode, Config, cartesian)
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
%% arrays.  Used by live-mutation paths (Twister bank, cell re-fire,
%% per-tick refresh_from_snapshot in the voice).
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
%% advance_all(State, SpeedList, DirectionList) -> State'
%%
%% Per master tick, for each playhead K: accumulator += speed[K]; the
%% integer portion of the new accumulator is how many cells to advance
%% (skip-aware) in the direction encoded by direction[K]; the fractional
%% remainder rolls over to the next tick.  Direction encoding:
%%   0 = forward  (+1 each step)
%%   1 = backward (-1 each step)
%%   2 = pendulum (alternates +1 / -1, flipping at boundaries; per-
%%       playhead pend_step state tracks current sign)
%% Out-of-range values floor-clamp to 0 (forward).
%%
%% Both lists are zipped with the playhead list under the spec §5.3
%% forgiving rules — shortfall fills with defaults (speed 1.0,
%% direction 0=fwd), surplus dropped.  The voice's `nav_mode` is still
%% read for `step_y_all` (NavCartesian Y-clock); each playhead's
%% direction is independent of nav_mode for X-advance.
%% --------------------------------------------------------------------
advance_all(#{playheads := Playheads,
              skip      := Skip,
              nav_mode  := NavMode} = State, SpeedList, DirectionList) ->
    N = length(Playheads),
    Speeds = zip_with_default(SpeedList, N, 1.0),
    Dirs   = zip_with_default(DirectionList, N, 0),
    NewPlayheads = lists:zipwith3(
                     fun(Ph, Spd, Dir) ->
                             advance_one(Ph, Spd, Dir, NavMode, Skip)
                     end,
                     Playheads, Speeds, Dirs),
    State#{playheads := NewPlayheads}.

advance_one(#{cursor := Cursor, accumulator := Acc} = Ph,
            Speed, Dir, NavMode, Skip) ->
    NewAcc = Acc + ensure_float(Speed),
    Steps  = trunc(NewAcc),
    Remain = NewAcc - Steps,
    PendStep0 = maps:get(pend_step, Ph, 1),
    {NewCursor, NewPendStep} =
        advance_n(Cursor, Steps, decode_dir(Dir), PendStep0, NavMode, Skip),
    #{cursor => NewCursor, accumulator => Remain, pend_step => NewPendStep}.

decode_dir(N) when N =< 0 -> fwd;
decode_dir(1) -> back;
decode_dir(N) when N >= 2 -> pend;
decode_dir(_) -> fwd.

advance_n(Cursor, N, _, PendStep, _, _) when N =< 0 ->
    {Cursor, PendStep};
advance_n(Cursor, N, Dir, PendStep, NavMode, Skip) ->
    {NextCursor, NextPendStep} =
        next_cursor(Cursor, Dir, PendStep, NavMode, Skip),
    advance_n(NextCursor, N - 1, Dir, NextPendStep, NavMode, Skip).

next_cursor(Cursor, fwd, PendStep, cartesian, Skip) ->
    %% In Cartesian, forward walks X within the row.
    {cartesian_step(Cursor, Skip), PendStep};
next_cursor(Cursor, fwd, PendStep, _, Skip) ->
    {find_non_skipped_idx(Cursor, +1, Skip), PendStep};
next_cursor(Cursor, back, PendStep, _, Skip) ->
    {find_non_skipped_idx(Cursor, -1, Skip), PendStep};
next_cursor(Cursor, pend, PendStep, _, Skip) ->
    %% Pendulum.  Step in the current direction; at the boundaries
    %% (cursor 0 with step -1, or cursor 15 with step +1), flip first
    %% and step back into range.
    NewStep = case {Cursor, PendStep} of
                  {0,  -1} -> +1;
                  {15, +1} -> -1;
                  _        -> PendStep
              end,
    {find_non_skipped_idx(Cursor, NewStep, Skip), NewStep}.

cartesian_step(Cursor, Skip) ->
    Y = Cursor div 4,
    X = Cursor rem 4,
    NewX = find_non_skipped_x(X, Y, Skip),
    Y * 4 + NewX.

ensure_float(N) when is_integer(N) -> N + 0.0;
ensure_float(N) when is_float(N)   -> N;
ensure_float(_)                    -> 1.0.

%% --------------------------------------------------------------------
%% step_y_all(State) -> State'
%%
%% NavCartesian only: advance each playhead's Y by 1 (next row,
%% skip-aware).  No-op in forward/reverse — those modes don't
%% distinguish X and Y axes.
%% --------------------------------------------------------------------
step_y_all(#{playheads := Playheads,
             skip      := Skip,
             nav_mode  := cartesian} = State) ->
    NewPlayheads = [step_y_one(Ph, Skip) || Ph <- Playheads],
    State#{playheads := NewPlayheads};
step_y_all(State) -> State.

step_y_one(#{cursor := Cursor} = Ph, Skip) ->
    X = Cursor rem 4,
    Y = Cursor div 4,
    NewY = find_non_skipped_y(X, Y, Skip),
    Ph#{cursor := NewY * 4 + X}.

%% --------------------------------------------------------------------
%% current_cursors(State) -> [0..15]
%%
%% Per-playhead cursor positions, in playhead order.  The voice uses
%% these to read notes/gate/vel/etc. from the snapshot and emit MIDI.
%% --------------------------------------------------------------------
current_cursors(#{playheads := Playheads}) ->
    [maps:get(cursor, Ph) || Ph <- Playheads].

%% --------------------------------------------------------------------
%% Skip-aware traversal helpers (lifted unchanged from the pre-6.2
%% engine).  They walk at most 16 cells looking for a non-skipped
%% landing; if all are skipped, return the starting position.
%% --------------------------------------------------------------------

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
%% Helper: mathematical modulo (Erlang's rem returns the dividend's
%% sign; we need the divisor's sign for proper wrap of negative -1
%% offsets in reverse mode).
%% --------------------------------------------------------------------
mod(A, B) when B > 0 ->
    ((A rem B) + B) rem B.

%% --------------------------------------------------------------------
%% zip_with_default(List, N, Default) — pad/truncate List to length N,
%% filling shortfall with Default.  Implements the spec §5.3 forgiving
%% array semantics: per-playhead arrays zip against the playhead list
%% with surplus dropped and shortfall defaulted.
%% --------------------------------------------------------------------
zip_with_default(List, N, Default) ->
    Padded = List ++ lists:duplicate(max(0, N - length(List)), Default),
    lists:sublist(Padded, N).
