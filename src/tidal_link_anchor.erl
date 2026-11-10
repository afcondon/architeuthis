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
%% The shape, the validity rule and the two encodings are declared once for
%% the whole rig in binnacle/conformance/LINK-ANCHOR.md, and this module is
%% held to that declaration's vectors by `make test-erl`. A datagram that is
%% addressed to us and fails the rule is REFUSED and counted (`refused/0`);
%% it never becomes the held anchor.
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
         scheduler_clock/2, sync_broadcast/1, refused/0]).

%% The pure half: what an anchor is, on the wire and in use. These are what
%% test/tidal_link_anchor_tests.erl replays the conformance vectors against
%% (binnacle/conformance/LINK-ANCHOR.md is the declaration).
-export([decode/1, beat_from/2, is_fresh/1, format_anchor/4,
         decode_peers/1, format_link/2, es9_refused/1, continuo_refused/1]).

-define(DEFAULT_PORT, 57121).
-define(NAME, ?MODULE).
%% Maximum age of the latest anchor before we treat the Link source as
%% offline and fall through to free-running. link-spike publishes at
%% 10 Hz so 2 s = 20 missed packets — a safe boundary between "transient
%% drop" and "the bridge has actually died."
-define(STALE_ANCHOR_US, 2000000).

%% The validity rule (LINK-ANCHOR.md, "Validity").
-define(TEMPO_MINIMUM, 20.0).
-define(TEMPO_MAXIMUM, 999.0).
-define(QUANTUM_MINIMUM, 1.0).
-define(QUANTUM_MAXIMUM, 64.0).
-define(UNIX_MICROS_MAXIMUM, 9007199254740992).    %% 2^53

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

%% How many datagrams addressed `/link/anchor` have failed the validity
%% rule since this listener started. `no_anchor` if the listener is not
%% answering.
refused() ->
    call(refused).

%% Link's beat at a wall-clock moment, for an anchor as held. The
%% operations are in the declaration's order: subtract, multiply by tempo,
%% divide by sixty million, add.
beat_from({AnchorUs, Beat, Tempo, _Quantum}, AtUs) ->
    Beat + (AtUs - AnchorUs) * Tempo / 60000000.0.

%% Whether an anchor received AgeUs ago still drives the clock.
is_fresh(AgeUs) ->
    AgeUs =< ?STALE_ANCHOR_US.

%% Compute extrapolated cycle (cycle = beat / quantum) at the given local
%% Unix microsecond time. Returns {ok, {Cycle, Tempo, Quantum}} or no_anchor.
cycle_at(LocalUs) when is_integer(LocalUs) ->
    case info() of
        no_anchor ->
            no_anchor;
        {anchor, AnchorUs, Beat, Tempo, Quantum, _LastRecvUs} ->
            BeatNow = beat_from({AnchorUs, Beat, Tempo, Quantum}, LocalUs),
            Cycle = BeatNow / Quantum,
            {ok, {Cycle, Tempo, Quantum}}
    end.

%% Compute extrapolated beat at the given local Unix microsecond time.
beat_at(LocalUs) when is_integer(LocalUs) ->
    case info() of
        no_anchor ->
            no_anchor;
        {anchor, AnchorUs, Beat, Tempo, Quantum, _LastRecvUs} ->
            {ok, beat_from({AnchorUs, Beat, Tempo, Quantum}, LocalUs)}
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
            BeatNow = beat_from({AnchorUs, BeatAtAnchor, Tempo, Quantum}, NowUs),
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
            case decode(Packet) of
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
                refuse ->
                    %% Addressed to us and not usable. Counted, so that a
                    %% listener hearing bad anchors does not look like one
                    %% hearing none; said once, so the log names the cause.
                    Refused = maps:get(refused, State, 0),
                    case Refused of
                        0 ->
                            tidal_log:err("link-anchor: refusing a /link/anchor "
                                          "that fails the validity rule; further "
                                          "ones are counted (tidal_link_anchor:refused/0)~n",
                                          []);
                        _ ->
                            ok
                    end,
                    loop(State#{refused => Refused + 1});
                other ->
                    %% Never an anchor: not counted. The one other message
                    %% we listen for is Diaphus's peer count (diaphus
                    %% src/main.rs, item 8), passed on to the pages.
                    case decode_peers(Packet) of
                        {ok, Peers} ->
                            State1 = ask_daemons(State#{peers => Peers}),
                            broadcast_link(State1),
                            loop(State1);
                        other ->
                            loop(State)
                    end
            end;

        {daemons_refused, Daemons} ->
            loop(State#{daemons => Daemons, asking => false});

        {From, Ref, refused} when is_reference(Ref) ->
            From ! {Ref, maps:get(refused, State, 0)},
            loop(State);

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

        {sync_broadcast, Bin} ->
            lists:foreach(fun(Pid) -> Pid ! {sync_broadcast, Bin} end,
                          sets:to_list(maps:get(subscribers, State, sets:new()))),
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
            case maps:get(peers, State, undefined) of
                undefined -> ok;
                _ -> Pid ! {sync_broadcast, link_frame(State)}
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

%% The Link session's health, for the Dashboard: how many other peers
%% share the session (Diaphus's count, re-sent once a second), and how many
%% anchors each receiver the rig can ask has refused (binnacle/conformance/
%% LINK-ANCHOR.md: every one should read zero). Its own frame, never an
%% `anchor ...` one, so Binnacle hands it to the page untouched.
broadcast_link(State) ->
    Bin = link_frame(State),
    lists:foreach(fun(Pid) -> Pid ! {sync_broadcast, Bin} end,
                  sets:to_list(maps:get(subscribers, State, sets:new()))).

link_frame(State) ->
    format_link(maps:get(peers, State, 0),
                [{architeuthis, maps:get(refused, State, 0)}
                 | maps:get(daemons, State, [])]).

%% `link <peers> <receiver>=<refused> ...`; a receiver that did not answer
%% reads `-`.
format_link(Peers, Counts) ->
    iolist_to_binary(
      [io_lib:format("link ~B", [Peers])
       | [io_lib:format(" ~s=~s", [Name, case N of
                                              N when is_integer(N) -> integer_to_list(N);
                                              _ -> "-"
                                          end])
          || {Name, N} <- Counts]]).

%% es9-daemon's and Continuo's refusal counts, asked of their control
%% sockets at most every five seconds, from a process of its own so the
%% anchor loop never waits on a socket.
-define(DAEMON_ASK_US, 5000000).
ask_daemons(State) ->
    NowUs = erlang:system_time(microsecond),
    Last = maps:get(asked_us, State, 0),
    case maps:get(asking, State, false) orelse NowUs - Last < ?DAEMON_ASK_US of
        true ->
            State;
        false ->
            Self = self(),
            spawn(fun() ->
                Self ! {daemons_refused,
                        [{'es9-daemon', es9_refused(ask(".es9/control.sock", "link"))},
                         {continuo, continuo_refused(ask(".continuo/control.sock", "status"))}]}
            end),
            State#{asking => true, asked_us => NowUs}
    end.

ask(Rel, Verb) ->
    Path = filename:join(os:getenv("HOME", "/tmp"), Rel),
    case gen_tcp:connect({local, Path}, 0, [{active, false}, binary, {packet, line}], 500) of
        {ok, Sock} ->
            try
                ok = gen_tcp:send(Sock, [Verb, $\n]),
                case gen_tcp:recv(Sock, 0, 1000) of
                    {ok, Reply} -> {ok, Reply};
                    E -> E
                end
            after gen_tcp:close(Sock)
            end;
        E -> E
    end.

%% es9-daemon's `link` verb ends `refused N`.
es9_refused({ok, Reply}) ->
    case re:run(Reply, "refused ([0-9]+)", [{capture, all_but_first, binary}]) of
        {match, [N]} -> binary_to_integer(N);
        _ -> unknown
    end;
es9_refused(_) -> unknown.

%% Continuo's `status` is JSON with `"anchorsRefused": N`.
continuo_refused({ok, Reply}) ->
    case re:run(Reply, "\"anchorsRefused\": *([0-9]+)", [{capture, all_but_first, binary}]) of
        {match, [N]} -> binary_to_integer(N);
        _ -> unknown
    end;
continuo_refused(_) -> unknown.

%% Diaphus's `/link/peers ,i n`; anything else is `other`.
decode_peers(<<"/link/peers", 0, ",i", 0, 0, Peers:32/big-signed>>) when Peers >= 0 ->
    {ok, Peers};
decode_peers(_) ->
    other.

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

%% One datagram, to one of three verdicts (LINK-ANCHOR.md, "Encoding 1"):
%%
%%   {ok, {UnixUs, Beat, Tempo, Quantum}}   a valid anchor
%%   refuse                                 addressed to us, not usable
%%   other                                  never an anchor
%%
%% The layout is fixed at 56 bytes, so this is three matches rather than an
%% OSC parse: sixteen bytes of address, eight of type tags, then an int64
%% and three float64s. The tags are matched exactly; an `i` for the time or
%% an `f` for a value is refused, not converted.
decode(<<"/link/anchor", 0, 0, 0, 0, Rest/binary>>) ->
    case Rest of
        <<",hddd", 0, 0, 0,
          UnixUs:64/big-signed-integer,
          BeatBits:8/binary, TempoBits:8/binary, QuantumBits:8/binary>> ->
            validate(UnixUs, finite(BeatBits), finite(TempoBits),
                     finite(QuantumBits));
        _ ->
            refuse
    end;
decode(_) ->
    other.

%% Eight bytes as a float, or `not_finite`. The BEAM has no NaN and no
%% infinity, so matching either as a float fails rather than yielding one:
%% the bits are matched here, where the failure is an answer, and not in
%% the caller, where it would be a crash.
finite(<<Value:64/big-float>>) -> Value;
finite(_) -> not_finite.

%% The validity rule. Finiteness has been settled by finite/1.
validate(UnixUs, Beat, Tempo, Quantum)
  when is_float(Beat), is_float(Tempo), is_float(Quantum),
       UnixUs >= 0, UnixUs < ?UNIX_MICROS_MAXIMUM,
       Tempo >= ?TEMPO_MINIMUM, Tempo =< ?TEMPO_MAXIMUM,
       Quantum >= ?QUANTUM_MINIMUM, Quantum =< ?QUANTUM_MAXIMUM ->
    {ok, {UnixUs, Beat, Tempo, Quantum}};
validate(_, _, _, _) ->
    refuse.

%% Send a frame to every page subscribed to the Atlantis sync channel (the
%% pages that took the anchor stream: Binnacle apps). For changes the rig makes
%% that the pages must follow in lockstep, such as an `odonus` move's tagged
%% gestures. Fire-and-forget; a no-op if the listener isn't running.
sync_broadcast(Bin) when is_binary(Bin) ->
    case whereis(?NAME) of
        undefined -> ok;
        Pid -> Pid ! {sync_broadcast, Bin}, ok
    end.
