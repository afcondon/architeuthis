%% @doc Virtual polysignal voice — runs a polysignal entirely in BEAM,
%% no FH-2 round-trip.  Per clock tick, calls into
%% `Tidal.VirtualPolySignal.evaluateAt` with the captured PolySignal
%% value and the current cycle position; writes each returned
%% `{index, value}` to the live-control bus at
%% `<bus_prefix>.<index>`.
%%
%% Architecture mirrors balistes_voice / rene_voice:
%%   * subscribes to the clock's `{compute_until, Window}` broadcast;
%%   * holds the opaque PureScript PolySignal value (Foreign) as state;
%%   * `set_config` swaps the value on a same-alias re-fire (live
%%     mutation: cycle phase is preserved across edits);
%%   * temporary restart strategy under
%%     `virtual_polysignal_voice_sup`.
%%
%% The PureScript evaluator returns an Erlang `array` of records
%% (PureScript Array convention).  Walk to a list at the boundary
%% before iterating.
-module(virtual_polysignal_voice).
-behaviour(gen_server).

-export([start_link/2,
         compute_until/2,
         set_config/2,
         get_state/1,
         registered_name/1]).

-export([init/1, handle_call/3, handle_cast/2, terminate/2]).

-record(st, {
    name        :: atom(),
    bus_prefix  :: binary(),        %% e.g. <<"lfoBank">>
    family      :: binary(),        %% e.g. <<"polylfo">>
    polysig     :: term(),          %% opaque PolySignal value (Foreign)
    last_pos    :: number() | undefined
}).

%% =========================================================================
%% Public API
%% =========================================================================

%% Config keys (all required):
%%   bus_prefix :: binary()
%%   family     :: binary()
%%   polysig    :: term()  (opaque, from Tidal.SessionWalker)
start_link(Name, Config) when is_atom(Name); is_binary(Name) ->
    Atom = to_atom(Name),
    gen_server:start_link({local, registered_name(Atom)}, ?MODULE,
                          {Atom, Config}, []).

compute_until(Name, Window) ->
    gen_server:cast(registered_name(Name), {compute_until, Window}).

%% @doc Swap the underlying PolySignal value.  Live-mutation path —
%% the cycle phase counter is preserved so the LFO doesn't reset
%% mid-cycle on a cell re-fire.
set_config(Name, Cfg) ->
    gen_server:cast(registered_name(Name), {set_config, Cfg}).

get_state(Name) ->
    gen_server:call(registered_name(Name), get_state).

registered_name(Name) when is_atom(Name) ->
    binary_to_atom(<<"vpoly_voice_", (atom_to_binary(Name, utf8))/binary>>, utf8);
registered_name(Name) when is_binary(Name) ->
    registered_name(binary_to_atom(Name, utf8)).

%% =========================================================================
%% gen_server callbacks
%% =========================================================================

init({Name, Config}) ->
    State = #st{
        name       = Name,
        bus_prefix = ensure_binary(maps:get(bus_prefix, Config)),
        family     = ensure_binary(maps:get(family,     Config)),
        polysig    = maps:get(polysig, Config),
        last_pos   = undefined
    },
    tidal_log:info(
      "virtual_polysignal_voice ~p started: family=~s prefix=~s~n",
      [Name, State#st.family, State#st.bus_prefix]),
    {ok, State}.

handle_call(get_state, _From, State) ->
    Snap = #{
        name        => State#st.name,
        bus_prefix  => State#st.bus_prefix,
        family      => State#st.family,
        last_pos    => State#st.last_pos
    },
    {reply, Snap, State}.

handle_cast({compute_until, Window}, State) ->
    NewState = process_window(Window, State),
    {noreply, NewState};
handle_cast({set_config, Cfg}, State) ->
    NewState = case maps:get(polysig, Cfg, undefined) of
        undefined -> State;
        P -> State#st{polysig = P}
    end,
    {noreply, NewState}.

terminate(_Reason, _State) ->
    ok.

%% =========================================================================
%% Tick handling
%% =========================================================================

%% Sample the polysignal at the window's `currentCycle` and write
%% each output to the bus.  We sample at the *start* of the window —
%% control rate (≈50 Hz, one sample per tick) is plenty for LFO /
%% clock / euclid bus writes.  No catch-up needed: late writes only
%% affect downstream reads in the same tick.
process_window(Window, State) ->
    CurrentCycle = maps:get(currentCycle, Window, 0.0),
    Outputs = evaluate(State#st.polysig, CurrentCycle),
    OutputList = try array:to_list(Outputs) catch _:_ -> [] end,
    lists:foreach(
      fun(#{index := I, value := V}) ->
              Key = iolist_to_binary([State#st.bus_prefix,
                                      <<".">>,
                                      integer_to_binary(I)]),
              tidal_control_bus:set(Key, V)
      end, OutputList),
    State#st{last_pos = CurrentCycle}.

%% Call into the PureScript evaluator.  The walker passed the
%% polysignal as Foreign (an opaque purs-backend-erl-encoded tagged
%% tuple); we hand it back to PureScript unchanged.  Returns an
%% Erlang `array` of records (the PureScript Array a convention).
evaluate(PolySig, CyclePos) ->
    'tidal_virtualPolySignal@ps':evaluateAt(PolySig, float(CyclePos)).

%% =========================================================================
%% Helpers
%% =========================================================================

to_atom(N) when is_atom(N) -> N;
to_atom(N) when is_binary(N) -> binary_to_atom(N, utf8);
to_atom(N) when is_list(N) -> list_to_atom(N).

ensure_binary(B) when is_binary(B) -> B;
ensure_binary(L) when is_list(L)   -> list_to_binary(L);
ensure_binary(A) when is_atom(A)   -> atom_to_binary(A, utf8).
