%% tidal_link_anchor — UDP listener for /link/anchor messages from
%% link-spike (or any other Ableton Link bridge that publishes the same
%% affine map). Stores the latest anchor and exposes synchronous queries.
%%
%% Wire format on UDP 127.0.0.1:57121, OSC `,hddd`:
%%   address  = "/link/anchor"
%%   args     = (UnixMicrosAtAnchor :: int64,
%%               BeatAtAnchor       :: float64,
%%               Tempo              :: float64,    %% BPM
%%               Quantum            :: float64)    %% beats per Link "bar"
%%
%% Consumers compute beat-at-local-time using the affine map:
%%   beat(T) = BeatAtAnchor + (T - UnixMicrosAtAnchor) * Tempo / 60_000_000
%% and cycle = beat / Quantum (1 cycle = 1 bar in Tidal's vocabulary).
%%
%% This module is plain proc_lib + receive loop, not gen_server, to match
%% the project's lightweight style. Registered name is `tidal_link_anchor`.

-module(tidal_link_anchor).

-export([start/0, start_link/0, stop/0,
         info/0, cycle_at/1, beat_at/1, tempo/0, has_anchor/0,
         scheduler_clock/2]).

-define(DEFAULT_PORT, 57121).
-define(NAME, ?MODULE).
%% Maximum age of the latest anchor before we treat the Link source as
%% offline and fall through to free-running. link-spike publishes at
%% 10 Hz so 2 s = 20 missed packets — a safe boundary between "transient
%% drop" and "the bridge has actually died."
-define(STALE_ANCHOR_US, 2000000).

%% =========================================================================
%% Public API
%% =========================================================================

%% Start the listener as an unlinked process, registered under ?NAME.
%% Idempotent: returns ok if already running.
start() ->
    case whereis(?NAME) of
        undefined ->
            Pid = spawn(fun init/0),
            register(?NAME, Pid),
            ok;
        _ ->
            ok
    end.

%% Linked variant for callers that want supervision-by-ownership.
start_link() ->
    case whereis(?NAME) of
        undefined ->
            Pid = spawn_link(fun init/0),
            register(?NAME, Pid),
            ok;
        _ ->
            ok
    end.

stop() ->
    case whereis(?NAME) of
        undefined -> ok;
        Pid -> Pid ! stop, ok
    end.

%% Synchronous read of latest anchor.
%%   {anchor, UnixUs, Beat, Tempo, Quantum, LastRecvUs}  — current
%%   no_anchor                                            — none received yet
info() ->
    call(info).

%% Compute extrapolated cycle (cycle = beat / quantum) at the given local
%% Unix microsecond time. Returns {ok, {Cycle, Tempo, Quantum}} or no_anchor.
cycle_at(LocalUs) when is_integer(LocalUs) ->
    case info() of
        no_anchor ->
            no_anchor;
        {anchor, AnchorUs, Beat, Tempo, Quantum, _LastRecvUs} ->
            BeatNow = Beat + (LocalUs - AnchorUs) * Tempo / 60000000.0,
            Cycle = BeatNow / Quantum,
            {ok, {Cycle, Tempo, Quantum}}
    end.

%% Compute extrapolated beat at the given local Unix microsecond time.
beat_at(LocalUs) when is_integer(LocalUs) ->
    case info() of
        no_anchor ->
            no_anchor;
        {anchor, AnchorUs, Beat, Tempo, _Quantum, _LastRecvUs} ->
            BeatNow = Beat + (LocalUs - AnchorUs) * Tempo / 60000000.0,
            {ok, BeatNow}
    end.

%% Latest tempo, or no_anchor.
tempo() ->
    case info() of
        no_anchor -> no_anchor;
        {anchor, _, _, Tempo, _, _} -> {ok, Tempo}
    end.

has_anchor() ->
    info() =/= no_anchor.

%% Single source of truth for "what cycle/time is it now?" used by the
%% MIDI scheduler's Tick handler. The scheduler treats time in two
%% coupled values: `cycleDurationMs` (60s × 4 / BPM, 1 cycle = 1 bar) and
%% `elapsedMs` (a notional "ms since cycle 0"). Any (elapsedMs,
%% cycleDurationMs) pair satisfying `elapsedMs / cycleDurationMs =
%% currentCycle` is valid — the scheduler only uses these to derive
%% currentCycle and per-event delays.
%%
%% Policy:
%%   - Fresh Link anchor available → synthesize values from it so
%%     `currentCycle` matches Link's beat-position and `cycleDurationMs`
%%     matches Link's live tempo. Tempo changes from Live, Patterning,
%%     etc. flow through automatically.
%%   - No anchor or stale anchor → free-running fallback using the
%%     scheduler's start time and config-time BPM. The scheduler keeps
%%     ticking at its config BPM; transitioning back into Link mode
%%     (when an anchor arrives) will phase-jump, which is intentional.
%%
%% StartTimeMs: the scheduler's start time as ms since BEAM VM start
%% (same time base as the original currentTimeMs).
%% FreeRunBpm: config BPM used as fallback.
%%
%% Returns #{synced => Bool, elapsedMs => Float, cycleDurationMs => Float}
scheduler_clock(StartTimeMs, FreeRunBpm) ->
    NowUs = erlang:system_time(microsecond),
    case info() of
        {anchor, AnchorUs, BeatAtAnchor, Tempo, Quantum, LastRecvUs}
                when (NowUs - LastRecvUs) =< ?STALE_ANCHOR_US,
                     Tempo > 0, Quantum > 0 ->
            BeatNow = BeatAtAnchor + (NowUs - AnchorUs) * Tempo / 60000000.0,
            CycleNow = BeatNow / Quantum,
            CycleDur = 60000.0 * Quantum / Tempo,
            #{ synced => true,
               elapsedMs => CycleNow * CycleDur,
               cycleDurationMs => CycleDur };
        _ ->
            NowMs = erlang:convert_time_unit(
                      erlang:monotonic_time() - erlang:system_info(start_time),
                      native, millisecond),
            #{ synced => false,
               elapsedMs => float(NowMs - StartTimeMs),
               cycleDurationMs => 240000.0 / FreeRunBpm }
    end.

%% =========================================================================
%% Process loop
%% =========================================================================

init() ->
    %% Bind to any-interface — link-spike sends to 127.0.0.1, but binding
    %% specifically to {127,0,0,1} can miss loopback packets in some
    %% configurations (observed with the Python listener). Any-interface
    %% accepts loopback unconditionally and listening on UDP doesn't trip
    %% macOS Local Network TCC.
    %% Retry the bind across a restart race: when Bosun/DeepStar SIGTERMs
    %% the old beam and immediately starts a new one, the old process can
    %% still hold UDP 57121 for a moment. A single open() then fails and we
    %% used to give up permanently (silently no-anchor forever). Retry for
    %% ~2s so the new listener reclaims the port once the old beam exits.
    case open_socket(10) of
        undefined ->
            tidal_log:err("link-anchor: could not bind UDP ~B after retries~n",
                          [?DEFAULT_PORT]),
            %% Stay alive answering no_anchor rather than crashing callers.
            loop(#{socket => undefined, anchor => undefined, last_recv_us => 0,
                   subscribers => sets:new()});
        Socket ->
            tidal_log:info("link-anchor listening on UDP *:~B~n", [?DEFAULT_PORT]),
            loop(#{socket => Socket, anchor => undefined, last_recv_us => 0,
                   subscribers => sets:new()})
    end.

%% Try to bind ?DEFAULT_PORT, retrying every 200ms up to N times. Returns
%% the socket or `undefined` if it never came free.
open_socket(0) -> undefined;
open_socket(N) ->
    case gen_udp:open(?DEFAULT_PORT, [binary, {active, true}, {reuseaddr, true}]) of
        {ok, Socket} ->
            Socket;
        {error, _Reason} ->
            timer:sleep(200),
            open_socket(N - 1)
    end.

loop(State) ->
    receive
        {udp, _Sock, _Ip, _Port, Packet} ->
            case decode_link_anchor(Packet) of
                {ok, {UnixUs, Beat, Tempo, Quantum}} ->
                    NowUs = erlang:system_time(microsecond),
                    PrevRecvUs = maps:get(last_recv_us, State, 0),
                    AgeUs = case PrevRecvUs of
                                0 -> 0;
                                _ -> NowUs - PrevRecvUs
                            end,
                    %% Anchor-log ghost trap: record every receive so we
                    %% have a forensic record next time clock dropouts
                    %% recur.  Cost: ~µs per packet at 10 Hz.
                    tidal_anchor_log:record(
                      {anchor_rx, Beat, Tempo, Quantum, AgeUs}),
                    NewState = State#{anchor => {UnixUs, Beat, Tempo, Quantum},
                                      last_recv_us => NowUs},
                    %% Fan the fresh anchor out to subscribed WS clients
                    %% (Atlantis Sync Protocol — Binnacle apps in the
                    %% browser). Plain message-passing, no pg/ETS.
                    broadcast_anchor(UnixUs, Beat, Tempo, Quantum,
                                     maps:get(subscribers, State, sets:new())),
                    loop(NewState);
                error ->
                    %% Unknown packet — log once at debug, ignore.
                    loop(State)
            end;

        {From, Ref, info} when is_reference(Ref) ->
            Reply = case maps:get(anchor, State) of
                undefined ->
                    no_anchor;
                {UnixUs, Beat, Tempo, Quantum} ->
                    {anchor, UnixUs, Beat, Tempo, Quantum,
                     maps:get(last_recv_us, State)}
            end,
            From ! {Ref, Reply},
            loop(State);

        {subscribe, Pid} when is_pid(Pid) ->
            %% A WS handler wants the anchor stream. Monitor it so we
            %% prune the subscriber set when the connection dies, and
            %% send the current anchor immediately (don't wait up to
            %% 100ms for the next publish).
            erlang:monitor(process, Pid),
            Subs = sets:add_element(
                     Pid, maps:get(subscribers, State, sets:new())),
            case maps:get(anchor, State) of
                undefined -> ok;
                {U, B, T, Q} ->
                    Pid ! {anchor_broadcast, format_anchor(U, B, T, Q)}
            end,
            loop(State#{subscribers => Subs});

        {'DOWN', _Ref, process, Pid, _Reason} ->
            Subs = sets:del_element(
                     Pid, maps:get(subscribers, State, sets:new())),
            loop(State#{subscribers => Subs});

        stop ->
            case maps:get(socket, State) of
                undefined -> ok;
                Sock -> gen_udp:close(Sock)
            end,
            tidal_log:info("link-anchor stopped~n", []),
            ok;

        _Other ->
            loop(State)
    end.

%% Fan an anchor out to every subscribed WS handler pid.
broadcast_anchor(UnixUs, Beat, Tempo, Quantum, Subscribers) ->
    Bin = format_anchor(UnixUs, Beat, Tempo, Quantum),
    lists:foreach(fun(Pid) -> Pid ! {anchor_broadcast, Bin} end,
                  sets:to_list(Subscribers)).

%% Atlantis Sync Protocol anchor frame: `anchor <unixMicros> <beat>
%% <tempo> <quantum>`. unixMicros is the int64 wall-clock timestamp;
%% the browser maps it via Date.now() (same machine) and extrapolates
%% beat(t) = beat + (t - unixMicros) * tempo / 60e6.
format_anchor(UnixUs, Beat, Tempo, Quantum) ->
    iolist_to_binary(
      io_lib:format("anchor ~B ~f ~f ~f", [UnixUs, Beat, Tempo, Quantum])).

%% Synchronous request/reply against the registered process.
%%
%% Uses a per-call `make_ref/0` as the response tag (rather than the
%% registered name) so that late replies — when the listener is slow
%% and we time out at 100ms — don't leak into the caller's mailbox as
%% messages that something else might mishandle.  Caused a real bug:
%% the clock's gen_statem received late `{tidal_link_anchor, …}` info
%% events and crashed with function_clause, taking the whole
%% supervisor tree down (`one_for_all` at the time; since 2026-05-20
%% the top-level supervisor is `rest_for_one`, which would have
%% confined the cascade to clock + downstream).  With per-call refs,
%% late replies are flushed before this function returns.
call(Msg) ->
    case whereis(?NAME) of
        undefined ->
            no_anchor;
        Pid ->
            Ref = make_ref(),
            Pid ! {self(), Ref, Msg},
            receive
                {Ref, Reply} -> Reply
            after 100 ->
                %% Drain any late reply that arrived after the timeout
                %% but before we returned, so it can't pollute future
                %% receives or the parent's mailbox.
                receive
                    {Ref, _Late} -> ok
                after 0 -> ok
                end,
                no_anchor
            end
    end.

%% =========================================================================
%% OSC decoding for /link/anchor
%% =========================================================================

%% Returns {ok, {UnixUs, Beat, Tempo, Quantum}} on success, error otherwise.
decode_link_anchor(Packet) ->
    case decode_string(Packet) of
        {ok, <<"/link/anchor">>, Rest1} ->
            case decode_string(Rest1) of
                {ok, <<",hddd">>, Rest2} when byte_size(Rest2) >= 32 ->
                    <<UnixUs:64/big-signed-integer,
                      Beat:64/big-float,
                      Tempo:64/big-float,
                      Quantum:64/big-float,
                      _Trailer/binary>> = Rest2,
                    {ok, {UnixUs, Beat, Tempo, Quantum}};
                _ ->
                    error
            end;
        _ ->
            error
    end.

%% Read a null-terminated string padded to a 4-byte boundary, return
%% {ok, Bin, RestAfterPadding} or error.
decode_string(Bin) ->
    case binary:match(Bin, <<0>>) of
        nomatch ->
            error;
        {Pos, _} ->
            Str = binary:part(Bin, 0, Pos),
            %% Padding: total bytes consumed (string + null) rounded up to 4.
            Total = ((Pos + 4) div 4) * 4,
            case byte_size(Bin) >= Total of
                true ->
                    Rest = binary:part(Bin, Total, byte_size(Bin) - Total),
                    {ok, Str, Rest};
                false ->
                    error
            end
    end.
