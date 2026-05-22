%% @doc Anchor-log ring buffer — diagnostic trap for clock/dropout events.
%%
%% Always-on, low-cost instrumentation that records:
%%   * `{anchor_rx, Beat, Tempo, Quantum, AgeUsSinceLast}` — every
%%     /link/anchor packet receipt in tidal_link_anchor
%%   * `{clock_transition, FromSynced, ToSynced}` — every transition
%%     between anchored and free-running mode in tidal_clock
%%   * `{voice_dropout, VoiceName, LastStep, CurrentCycle, EndStepExcl,
%%     StepsPerCycle}` — every time a vmod's process_window silently
%%     skips a cast because the clock retreated relative to LastStep
%%
%% Writers are all single-process-per-event-kind, so a `set` ETS table
%% with an `update_counter`-generated monotonic key is safe.  Capped at
%% ?MAX_ENTRIES; older entries pruned on insert when the table grows
%% past the cap.  Reads via `dump/0` return all current entries sorted
%% by sequence number.
%%
%% Cost per write: one `update_counter` + one `insert` + occasional
%% `select_delete` for pruning — totaling a few microseconds.  At
%% anchor-rx rate of 10 Hz + occasional transitions/dropouts, total
%% steady-state cost is well under 100 us/sec.
%%
%% See `tools/timing-data/phase-4-diagnostic-f1-f2/README.md` for the
%% open question on multi-voice scaling that motivated this trap.
-module(tidal_anchor_log).

-export([init/0,
         record/1,
         dump/0,
         clear/0]).

-define(TABLE, tidal_anchor_log).
-define(SEQ_KEY, '$seq').
-define(MAX_ENTRIES, 2048).

%% =========================================================================
%% Public API
%% =========================================================================

%% Idempotent table creation.  Safe to call from any process.
init() ->
    case ets:info(?TABLE) of
        undefined ->
            ets:new(?TABLE, [named_table, public, ordered_set,
                             {read_concurrency, true},
                             {write_concurrency, true}]),
            ok;
        _ ->
            ok
    end.

%% Record one diagnostic event.  Event is any term; convention is a
%% tagged tuple as described in the module doc.  Returns ok.
record(Event) ->
    init(),
    Seq = ets:update_counter(?TABLE, ?SEQ_KEY, 1, {?SEQ_KEY, 0}),
    NowUs = erlang:system_time(microsecond),
    ets:insert(?TABLE, {Seq, NowUs, Event}),
    %% Prune entries below the cap.  Run only every ~100 inserts to
    %% keep the per-call cost amortised; the table may briefly exceed
    %% ?MAX_ENTRIES by ~100 entries between prunes.
    case Seq rem 100 of
        0 ->
            Threshold = Seq - ?MAX_ENTRIES,
            if Threshold > 0 ->
                ets:select_delete(
                  ?TABLE,
                  [{{'$1', '_', '_'},
                    [{'andalso',
                       {'=/=', '$1', ?SEQ_KEY},
                       {'<',   '$1', {const, Threshold}}}],
                    [true]}]);
               true -> 0
            end;
        _ ->
            ok
    end,
    ok.

%% Dump all current entries (newest last), excluding the sequence
%% counter row.  Returns a list of {Seq, NowUs, Event} tuples.
dump() ->
    init(),
    ets:foldr(
      fun({Key, _, _}, Acc) when Key =:= ?SEQ_KEY -> Acc;
         (Row, Acc) -> [Row | Acc]
      end, [], ?TABLE).

%% Wipe all entries (including the sequence counter — next `record/1`
%% restarts from 1).
clear() ->
    init(),
    ets:delete_all_objects(?TABLE),
    ok.
