%% @doc Conductor — section-firing gen_server (MVP-2).
%%
%% Holds an optional "current piece" (a `Pattern AnyCue` retrieved from
%% calypso_generated_session@ps) and, on each `{compute_until, Window}`
%% cast from the clock, queries the piece via
%% `tidal_conductor@ps:conductorTick/3` to find arm events that fall
%% in the new look-ahead window.  Each ArmCommand is dispatched along
%% the same code path as the `play-armed` WS verb:
%%   tidal_dispatcher:lookup_binding(Mvoice) → set_voice_pat
%%   on `nothing` → lookup_continuous_binding → set_voice_cont_pat
%%
%% Today arms fire as the conductor sees them; the wallTimeUs field
%% on each ArmCommand is preserved for a future cycle-accurate
%% scheduler that would `erlang:send_after` based on it.
%%
%% Lifecycle:
%%   * `play_piece(<<"intro">>)` — resolve the named pattern, install
%%     as current piece, reset state to start firing from the next
%%     integer cycle.
%%   * `stop_piece()` — clear current piece; voices keep their last
%%     armed pattern (deliberate: a stop only halts the section
%%     conductor, not the music).
%%
%% `compute_until` arrives at ~20Hz (tickIntervalMs=50ms).  When no
%% piece is active the cast is a tight no-op.
-module(tidal_conductor).
-behaviour(gen_server).

-export([start_link/0,
         play_piece/1,
         stop_piece/0,
         compute_until/1,
         status/0]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SESSION_MODULE, 'calypso_generated_session@ps').

%% =========================================================================
%% Public API
%% =========================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Resolve the named pattern in calypso_generated_session@ps:<Name>/0
%% and install as current piece.  Returns {ok, fired_first_arm_count}
%% on success, {error, Reason} otherwise.
play_piece(Name) when is_binary(Name) ->
    gen_server:call(?MODULE, {play_piece, Name}).

stop_piece() ->
    gen_server:call(?MODULE, stop_piece).

%% Clock-side entrypoint.  Cast so the clock tick stays non-blocking
%% even if the conductor is mid-dispatch.
compute_until(Window) ->
    gen_server:cast(?MODULE, {compute_until, Window}).

status() ->
    gen_server:call(?MODULE, status).

%% =========================================================================
%% gen_server callbacks
%% =========================================================================

init([]) ->
    PsState = 'tidal_conductor@ps':initialState(),
    {ok, #{piece => undefined, piece_name => undefined, ps_state => PsState}}.

handle_call({play_piece, Name}, _From, State) ->
    PieceAtom = binary_to_atom(Name, utf8),
    case erlang:function_exported(?SESSION_MODULE, PieceAtom, 0) of
        false ->
            case code:is_loaded(?SESSION_MODULE) of
                false ->
                    {reply,
                     {error, <<"Session module not loaded.  Fire the "
                               "composition first (▶ run).">>},
                     State};
                _ ->
                    {reply,
                     {error, iolist_to_binary(["piece '", Name, "' not "
                       "found in current Session"])},
                     State}
            end;
        true ->
            try erlang:apply(?SESSION_MODULE, PieceAtom, []) of
                Piece when is_function(Piece, 1) ->
                    %% Reset state; the section's events fire against
                    %% absolute cycle, so play-piece doesn't reset the
                    %% clock — arms land at their pattern's natural
                    %% modulo-cycle offsets.
                    PsState = 'tidal_conductor@ps':initialState(),
                    NewState = State#{
                        piece => Piece,
                        piece_name => Name,
                        ps_state => PsState
                    },
                    {reply, {ok, Name}, NewState};
                Other ->
                    OtherBin = list_to_binary(io_lib:format("~p", [Other])),
                    {reply,
                     {error,
                      <<"piece '", Name/binary, "' has unexpected shape: ",
                        OtherBin/binary>>},
                     State}
            catch
                Class:What ->
                    ClassBin = atom_to_binary(Class, utf8),
                    WhatBin = list_to_binary(io_lib:format("~p", [What])),
                    {reply,
                     {error,
                      <<"piece '", Name/binary, "' raised ",
                        ClassBin/binary, ": ", WhatBin/binary>>},
                     State}
            end
    end;
handle_call(stop_piece, _From, State) ->
    PsState = 'tidal_conductor@ps':initialState(),
    {reply, ok, State#{piece => undefined, piece_name => undefined,
                       ps_state => PsState}};
handle_call(status, _From, State) ->
    Reply = #{piece_name => maps:get(piece_name, State)},
    {reply, Reply, State}.

handle_cast({compute_until, _Window}, State = #{piece := undefined}) ->
    %% Fast path: no piece, nothing to do.
    {noreply, State};
handle_cast({compute_until, Window},
            State = #{piece := Piece, ps_state := PsState}) ->
    Result = ((('tidal_conductor@ps':conductorTick())(Window))(Piece))(PsState),
    Arms = maps:get(arms, Result),
    NewPsState = maps:get(newState, Result),
    %% Arms is a purs-backend-erl `Array a` — the stdlib `array` module
    %% representation, not a plain list.  Iterate with array:foldl/3.
    array:foldl(
        fun(_Idx, Arm, _Acc) ->
            fire_arm(Arm),
            ok
        end,
        ok,
        Arms),
    {noreply, State#{ps_state => NewPsState}};
handle_cast(_Other, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% =========================================================================
%% Internal
%% =========================================================================

%% Dispatch one arm.  Mirror of the play-armed WS handler arm:
%%   - lookup_binding (discrete) → set_voice_pat
%%   - else lookup_continuous_binding → set_voice_cont_pat (Pattern
%%     Pitch coerced to Pattern Number via patternPitchToNumber).
%% Errors are logged at debug level; the conductor doesn't crash on
%% individual arm failures so a missing-binding for one voice doesn't
%% take down the whole section.
fire_arm(#{mvoice := Mvoice, body := Body}) ->
    case tidal_dispatcher:lookup_binding(Mvoice) of
        {just, Binding} ->
            case tidal_voice_sup:set_voice_pat(Mvoice, Binding, Body) of
                ok -> ok;
                {error, Err} ->
                    tidal_log:debug(
                        "conductor: install (discrete) for '~s' failed: ~p~n",
                        [Mvoice, Err]),
                    ok
            end;
        {nothing} ->
            case tidal_dispatcher:lookup_continuous_binding(Mvoice) of
                {just, Dest} ->
                    NumPat =
                        ('tidal_pitch@ps':patternPitchToNumber())(Body),
                    case tidal_voice_sup:set_voice_cont_pat(
                           Mvoice, Dest, NumPat) of
                        ok -> ok;
                        {error, Err} ->
                            tidal_log:debug(
                                "conductor: install (cont) for '~s' "
                                "failed: ~p~n",
                                [Mvoice, Err]),
                            ok
                    end;
                {nothing} ->
                    tidal_log:debug(
                        "conductor: no binding for mvoice '~s' — "
                        "skipping arm~n",
                        [Mvoice]),
                    ok
            end
    end.

