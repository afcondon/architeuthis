%% Per-yarns-cell voice allocator state.
%%
%% Each `yarns <name> [N] mode <m> alloc <a>` cell installs a row in
%% this ETS table. On each dispatch event the dispatcher's
%% YarnsDispatch arm calls `allocate_voice/2` to pick the voice index
%% for the new note (or, for unison mode, the full broadcast set).
%%
%% The table is created lazily on first install — no supervisor
%% changes needed. ETS gives us atomic read-update-write per call,
%% which matches the per-event allocation pattern.
%%
%% Mode semantics:
%%   <<"poly">>    — voice picked via `alloc` strategy
%%   <<"mono">>    — always voice 0; mostly useful for a fat
%%                   monophonic lead through the FH-2's MCV pipeline
%%   <<"unison">>  — every note fires all voices simultaneously
%%                   (caller broadcasts; we return {unison, [0..N-1]})
%%
%% Alloc semantics (only meaningful for poly):
%%   <<"round-robin">> — cycle voices 0,1,2,…,N-1,0,…
%%
%% v1 ships round-robin only. steal-oldest / steal-newest deferred —
%% they require tracking per-voice last-used timestamps and decision
%% logic; the table's `voice_states` array is laid out to hold that
%% data when those modes land.
-module(tidal_yarns_state).
-export([install/4, remove/1, allocate_voice/2, list/0]).

-define(TABLE, tidal_yarns_state).

%% Ensure the named table exists. Idempotent — repeat calls after the
%% first one no-op. `public` access so the dispatcher process (which
%% holds the table) and any caller can read/write.
ensure_table() ->
    case ets:info(?TABLE) of
        undefined ->
            ets:new(?TABLE, [named_table, public, set]);
        _ ->
            ?TABLE
    end.

%% Install or replace per-cell allocator state. Re-firing a yarns
%% cell with the same name overwrites the previous state — last
%% write wins, same semantics as the dispatcher's binding registry.
install(YarnsName, Mode, Alloc, VoiceCount) ->
    ensure_table(),
    State = #{mode             => Mode,
              alloc            => Alloc,
              voice_count      => VoiceCount,
              round_robin_ptr  => 0,
              voice_states     => array:new(VoiceCount,
                                            [{default, 0}])},
    ets:insert(?TABLE, {YarnsName, State}),
    ok.

remove(YarnsName) ->
    ensure_table(),
    ets:delete(?TABLE, YarnsName),
    ok.

%% Allocate a voice for a new note. NowUs is the dispatch wall time
%% (microseconds) — currently unused by round-robin, but threaded
%% through so steal-oldest can use it without a signature change.
%%
%% Returns:
%%   {ok, VoiceIdx}              — single-voice allocation (poly/mono)
%%   {unison, [Idx, Idx, ...]}   — fire all voices in parallel
%%   {error, not_found}          — yarns name not installed
%%   {error, unknown_mode}       — defensive; shouldn't happen if
%%                                  parser validates mode
allocate_voice(YarnsName, NowUs) ->
    ensure_table(),
    case ets:lookup(?TABLE, YarnsName) of
        [] ->
            {error, not_found};
        [{_, S}] ->
            case maps:get(mode, S) of
                <<"mono">> ->
                    {ok, 0};
                <<"unison">> ->
                    N = maps:get(voice_count, S),
                    {unison, lists:seq(0, N - 1)};
                <<"poly">> ->
                    {VoiceIdx, S2} = allocate_poly(S, NowUs),
                    ets:insert(?TABLE, {YarnsName, S2}),
                    {ok, VoiceIdx};
                _ ->
                    {error, unknown_mode}
            end
    end.

%% Poly-mode voice picker. v1: round-robin only. Other strategies
%% are rejected by the parser before they reach us, but we keep a
%% defensive default-to-round-robin behaviour so an unrecognised
%% alloc value can't silently break dispatch.
allocate_poly(S, NowUs) ->
    case maps:get(alloc, S) of
        <<"round-robin">> ->
            allocate_round_robin(S, NowUs);
        _ ->
            allocate_round_robin(S, NowUs)
    end.

allocate_round_robin(S, NowUs) ->
    Ptr = maps:get(round_robin_ptr, S),
    N = maps:get(voice_count, S),
    Voices = maps:get(voice_states, S),
    Next = (Ptr + 1) rem N,
    S2 = S#{round_robin_ptr := Next,
            voice_states    := array:set(Ptr, NowUs, Voices)},
    {Ptr, S2}.

%% Debug helper — list installed yarns with their allocator state.
%% Useful for the WS `state` snapshot when we wire that up.
list() ->
    ensure_table(),
    ets:tab2list(?TABLE).
