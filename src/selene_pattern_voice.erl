%% @doc Selene pattern voice — holds a `Pattern (Selene s)` value
%% across ticks and installs the active Selene on each cycle
%% boundary.  Slab C step 2 (2026-05-23).
%%
%% Unlike `virtual_selene_voice` (which samples on every clock tick
%% and writes to the live-control bus at ~50 Hz), this voice only
%% acts when the *cycle floor* changes — typically once per second
%% at default cps, or however often the user's `slow N` factor
%% causes integer-cycle boundaries to cross.  Per cycle:
%%
%%   1. Compute `floor(currentCycle)` from the tick window.
%%   2. If the floor matches the previously-installed cycle, skip.
%%   3. Otherwise query the pattern at the new cycle position via
%%      `Tidal.SelenePattern.patternEnvelopeAt`, which returns a
%%      JSON envelope (or `nothing` for rests).
%%   4. If the envelope binary differs from the previously-installed
%%      one, send `apply-polysignal <json>` to fh2-daemon.  Otherwise
%%      skip the SysEx round-trip entirely.
%%
%% The dedup step matters: each `apply-polysignal` is ~10ms of SysEx
%% pacing across the FH-2's USB MIDI, and visible as a brief LED
%% flicker on the panel.  When `cat [a, b, c, d]` cycles through
%% four banks, we want exactly 4 writes per N cycles, not one per
%% tick.
%%
%% Crashes are not auto-restarted (`temporary` under
%% `selene_pattern_voice_sup`).  The next reload-baseline re-spawns
%% whatever bindings the session declares.
-module(selene_pattern_voice).
-behaviour(gen_server).

-export([start_link/2,
         compute_until/2,
         set_pattern/2,
         get_state/1,
         registered_name/1]).

-export([init/1, handle_call/3, handle_cast/2, terminate/2]).

-record(st, {
    name           :: atom(),
    alias          :: binary(),    %% binding name; sent as JSON `alias`
    pattern_value  :: term(),      %% opaque Pattern (Selene s) — Foreign
    device         :: binary(),    %% "fh2" | "es9" — routing for daemon call
    last_cycle     :: integer() | undefined,
    prev_envelope  :: binary() | undefined
}).

%% =========================================================================
%% Public API
%% =========================================================================

%% Config keys (all required):
%%   alias          :: binary()  — binding name, embedded in JSON envelope
%%   pattern_value  :: term()    — opaque Foreign from Tidal.SessionWalker
start_link(Name, Config) when is_atom(Name); is_binary(Name) ->
    Atom = to_atom(Name),
    gen_server:start_link({local, registered_name(Atom)}, ?MODULE,
                          {Atom, Config}, []).

compute_until(Name, Window) ->
    gen_server:cast(registered_name(Name), {compute_until, Window}).

%% @doc Swap the underlying Pattern value.  Live-mutation path —
%% the cycle counter is preserved so a rotation in flight doesn't
%% reset to cycle 0 on a re-fire.  The next cycle boundary will
%% query the new pattern.
set_pattern(Name, Cfg) ->
    gen_server:cast(registered_name(Name), {set_pattern, Cfg}).

get_state(Name) ->
    gen_server:call(registered_name(Name), get_state).

registered_name(Name) when is_atom(Name) ->
    binary_to_atom(<<"selene_pattern_voice_",
                     (atom_to_binary(Name, utf8))/binary>>, utf8);
registered_name(Name) when is_binary(Name) ->
    registered_name(binary_to_atom(Name, utf8)).

%% =========================================================================
%% gen_server callbacks
%% =========================================================================

init({Name, Config}) ->
    State = #st{
        name          = Name,
        alias         = ensure_binary(maps:get(alias, Config)),
        pattern_value = maps:get(pattern_value, Config),
        device        = ensure_binary(maps:get(device, Config, <<"fh2">>)),
        last_cycle    = undefined,
        prev_envelope = undefined
    },
    tidal_log:info(
      "selene_pattern_voice ~p started: alias=~s device=~s~n",
      [Name, State#st.alias, State#st.device]),
    {ok, State}.

handle_call(get_state, _From, State) ->
    Snap = #{
        name          => State#st.name,
        alias         => State#st.alias,
        last_cycle    => State#st.last_cycle,
        prev_envelope => State#st.prev_envelope
    },
    {reply, Snap, State}.

handle_cast({compute_until, Window}, State) ->
    NewState = process_window(Window, State),
    {noreply, NewState};
handle_cast({set_pattern, Cfg}, State) ->
    NewState = case maps:get(pattern_value, Cfg, undefined) of
        undefined -> State;
        P -> State#st{pattern_value = P}
    end,
    {noreply, NewState}.

terminate(_Reason, _State) ->
    ok.

%% =========================================================================
%% Cycle-boundary install
%% =========================================================================

%% Sample the cycle position from the tick window; if the integer
%% floor has changed since the previous install, query the pattern
%% and (possibly) install the active Selene.
process_window(Window, State) ->
    CurrentCycle = maps:get(currentCycle, Window, 0.0),
    CycleFloor = floor_cycle(CurrentCycle),
    case CycleFloor =:= State#st.last_cycle of
        true ->
            State;
        false ->
            maybe_install_for_cycle(CycleFloor, CurrentCycle, State)
    end.

maybe_install_for_cycle(CycleFloor, CurrentCycle, State) ->
    Envelope = query_pattern(State#st.alias,
                             State#st.pattern_value,
                             float(CurrentCycle)),
    NewState = State#st{last_cycle = CycleFloor},
    case Envelope of
        {nothing} ->
            %% Pattern produced no event at this cycle position
            %% (rest in `cat` or out-of-range arc).  Skip install.
            NewState;
        {just, Env} ->
            EnvBin = ensure_binary(Env),
            case EnvBin =:= State#st.prev_envelope of
                true ->
                    %% Identical envelope — skip the SysEx round-trip.
                    NewState;
                false ->
                    apply_envelope(State#st.alias, EnvBin, State#st.device),
                    NewState#st{prev_envelope = EnvBin}
            end
    end.

%% Call into Tidal.SelenePattern.patternEnvelopeAt with the opaque
%% Pattern value.  Returns `{just, Binary}` or `{nothing}` matching
%% the purs-backend-erl encoding of Maybe.
query_pattern(Alias, PatternForeign, CyclePos) ->
    'tidal_selenePattern@ps':patternEnvelopeAt(
      Alias, PatternForeign, CyclePos).

%% Push the envelope to fh2-daemon via the same path the static
%% Selene walker uses.  Duplicated here to avoid a cross-module call
%% into tidal_session_walker (which would create a circular dep);
%% extract to src/tidal_fh2.erl when the third caller emerges
%% (memory: task #71).
apply_envelope(Alias, EnvBin, Device) ->
    Cmd = <<"apply-polysignal ", EnvBin/binary>>,
    Result = case Device of
        <<"fh2">> -> fh2_daemon_call(Cmd);
        <<"es9">> -> es9_daemon_call(Cmd);
        Other    -> {error, {unknown_device, Other}}
    end,
    case Result of
        {ok, <<"OK", _/binary>> = Reply} ->
            tidal_log:debug(
              "selene_pattern_voice: ~s -> ~s~n",
              [Alias, Reply]);
        {ok, ErrReply} ->
            tidal_log:err(
              "selene_pattern_voice: ~s refused: ~s~n",
              [Alias, ErrReply]);
        {error, Reason} ->
            tidal_log:err(
              "selene_pattern_voice: ~s daemon error: ~p~n",
              [Alias, Reason])
    end.

%% Synchronous request/reply over the fh2-daemon Unix socket.
%% Mirrors the implementation in tidal_session_walker.erl (Slab C
%% step 1).  Both copies will collapse into tidal_fh2.erl per task
%% #71 — kept inline here to avoid a new dependency until that
%% extraction lands.
fh2_daemon_call(Command) ->
    daemon_call(filename:join(os:getenv("HOME", "/tmp"), ".fh2/control.sock"),
                Command).

%% Sibling of fh2_daemon_call targeting es9-daemon's ES-9 control
%% socket.  Same wire shape (apply-polysignal <json> + OK/ERR reply).
%% Will collapse into one shared transport when task #71 lands.
es9_daemon_call(Command) ->
    daemon_call(filename:join(os:getenv("HOME", "/tmp"), ".es9/control.sock"),
                Command).

daemon_call(Path, Command) ->
    case gen_tcp:connect({local, Path}, 0,
                         [local, binary, {active, false},
                          {packet, 0}], 500) of
        {error, R} -> {error, R};
        {ok, Sock} ->
            Reply = try
                ok = gen_tcp:send(Sock, <<Command/binary, "\n">>),
                recv_line(Sock, <<>>)
            after
                gen_tcp:close(Sock)
            end,
            Reply
    end.

recv_line(Sock, Acc) ->
    case gen_tcp:recv(Sock, 0, 1000) of
        {ok, Data} ->
            case binary:match(Data, <<"\n">>) of
                nomatch ->
                    recv_line(Sock, <<Acc/binary, Data/binary>>);
                {Pos, _} ->
                    <<Line:Pos/binary, _/binary>> = <<Acc/binary, Data/binary>>,
                    {ok, Line}
            end;
        {error, R} ->
            {error, R}
    end.

%% =========================================================================
%% Helpers
%% =========================================================================

floor_cycle(N) when is_float(N) ->
    %% Erlang's `floor/1` floors toward negative infinity; for
    %% positive cycles this matches the user-visible cycle number.
    %% Negative cycle positions don't currently arise (Tidal time
    %% starts at 0) so the standard library behaviour is fine.
    erlang:trunc(N);
floor_cycle(N) when is_integer(N) ->
    N.

to_atom(N) when is_atom(N) -> N;
to_atom(N) when is_binary(N) -> binary_to_atom(N, utf8);
to_atom(N) when is_list(N) -> list_to_atom(N).

ensure_binary(B) when is_binary(B) -> B;
ensure_binary(L) when is_list(L)   -> list_to_binary(L);
ensure_binary(A) when is_atom(A)   -> atom_to_binary(A, utf8).
