%% FFI primitives for Tidal.SessionWalker — PR 1.5 of the DSL
%% naming refactor.
%%
%% Each of these helpers is intentionally *knowledge-free*: they
%% expose the bare BEAM-level operations (enumerate exports, read a
%% tagged tuple's tag, extract a tuple element, coerce a binary/int)
%% so that the PureScript classifier next door (`SessionWalker.purs`)
%% can do all the application-typed discrimination on the
%% PureScript side.
%%
%% The deliberate non-feature here: there is *no* clause in this
%% file that says "this tag means MidiDevice" or "this shape is a
%% PitchedPart".  That knowledge lives in PureScript where the type
%% definitions live.  When the PureScript types evolve (PR 2's
%% destination split, Slab B's existentials), this FFI file does
%% not change.
-module('tidal_sessionWalker@foreign').

-export([ enumerateExports/1
        , constructorTag/1
        , tupleArg/2
        , asBinary/1
        , asInt/1
        , drumKitHits/1
        , gateDrumKitHits/1
        , vPerOctFields/1
        , polyLfoConfigFields/1
        , polyClockConfigFields/1
        , polyEnvConfigFields/1
        , polyEuclidConfigFields/1
        , polyRandConfigFields/1
        , polyPresetConfigFields/1
        , polyPresetNoteConfigFields/1
        , balistesBindingFields/1
        , repetitorBindingFields/1
        , odonusBindingFields/1
        ]).

%% --------------------------------------------------------------------
%% enumerateExports/1 — Effect-wrapped.
%%
%% PureScript signature:
%%   enumerateExports :: String -> Effect (Array { name :: String, value :: Foreign })
%%
%% Walks all 0-arity exports of a loaded BEAM module (skipping
%% module_info), and returns each as { name, value } where `name`
%% is the export atom rendered as a binary (the PureScript
%% identifier — used as the user-supplied alias) and `value` is
%% the result of calling the export.
%%
%% A missing module is silently treated as empty (Studio is
%% optional — a Session can stand alone).  Per-export exceptions
%% are logged via tidal_log:debug and skipped.
%% --------------------------------------------------------------------
enumerateExports(ModuleNameBin) ->
    fun() ->
        ModuleAtom = binary_to_atom(ModuleNameBin, utf8),
        Pairs =
            case ensure_loaded(ModuleAtom) of
                true ->
                    Exports = ModuleAtom:module_info(exports),
                    Zeros = [Name
                             || {Name, 0} <- Exports,
                                Name =/= module_info],
                    [#{ name => atom_to_binary(N, utf8)
                      , value => safe_call(ModuleAtom, N)
                      }
                     || N <- Zeros];
                false ->
                    []
            end,
        %% PureScript Array a is Erlang stdlib `array` module, not a
        %% list — wrap before crossing the FFI boundary or the next
        %% `<>` on the PS side will explode with `badarg` in
        %% `array:to_list/1`.  See memory
        %% `reference_purerl_array_is_erlang_array_module`.
        array:from_list(Pairs)
    end.

ensure_loaded(Module) ->
    case erlang:module_loaded(Module) of
        true -> true;
        false ->
            case code:load_file(Module) of
                {module, _} -> true;
                {error, _}  -> false
            end
    end.

safe_call(Module, Name) ->
    try Module:Name() of
        V -> V
    catch
        Class:What ->
            tidal_log:debug(
                "sessionWalker FFI: ~p:~p/0 raised ~p:~p~n",
                [Module, Name, Class, What]),
            undefined
    end.

%% --------------------------------------------------------------------
%% constructorTag/1 — pure.
%%
%% Tagged tuples (purs-backend-erl's encoding of data-type
%% constructors) carry an atom in element 1: e.g.
%%   {midiDevice, <<"FH-2">>, 0}.  Returns `{just, <<"midiDevice">>}`
%% on tagged-tuple shape, `nothing` otherwise.
%% --------------------------------------------------------------------
constructorTag(V) when is_tuple(V), tuple_size(V) >= 1 ->
    case element(1, V) of
        Tag when is_atom(Tag) ->
            {just, atom_to_binary(Tag, utf8)};
        _ ->
            {nothing}
    end;
constructorTag(_) ->
    {nothing}.

%% --------------------------------------------------------------------
%% tupleArg/2 — pure.
%%
%% 0-indexed argument extraction.  `tupleArg(0, {tag, A, B})` is A;
%% `tupleArg(1, {tag, A, B})` is B.  Returns nothing if the index
%% is out of range or the value isn't a tuple.
%% --------------------------------------------------------------------
tupleArg(N, V) when is_tuple(V), is_integer(N), N >= 0,
                    tuple_size(V) > N + 1 ->
    {just, element(N + 2, V)};
tupleArg(_, _) ->
    {nothing}.

%% --------------------------------------------------------------------
%% asBinary/1 — pure.
%%
%% Identity on binaries (PureScript Strings are binaries on the
%% BEAM); nothing on anything else.
%% --------------------------------------------------------------------
asBinary(V) when is_binary(V) -> {just, V};
asBinary(_) -> {nothing}.

%% --------------------------------------------------------------------
%% asInt/1 — pure.
%%
%% Identity on integers; nothing on anything else.
%% --------------------------------------------------------------------
asInt(V) when is_integer(V) -> {just, V};
asInt(_) -> {nothing}.

%% --------------------------------------------------------------------
%% drumKitHits/1 — pure.
%%
%% A `DrumKit`'s hits field is an Erlang stdlib `array` of DrumHit
%% records (purs-backend-erl encodes the PureScript record as the
%% Erlang map `#{name, note, vel, durMs}`).  Walk the whole array,
%% keep well-shaped entries, and return as a PureScript `Array`
%% (BEAM stdlib `array`) — `array:from_list/1` on the way out to
%% satisfy the PureScript ↔ Erlang Array convention.  See memory
%% `reference_purerl_array_is_erlang_array_module`.
%%
%% Empty / non-array / malformed input returns an empty array.
%% PR 2b: the walker shell then iterates these to build the
%% `midi-drum-kit … name:note:vel:dur,…` binding spec.
%% --------------------------------------------------------------------
drumKitHits(HitsForeign) ->
    List = try array:to_list(HitsForeign)
           catch _:_ -> []
           end,
    Decoded = [ #{ name => N, note => Nt, vel => V, durMs => D }
              || #{name := N, note := Nt, vel := V, durMs := D} <- List,
                 is_binary(N), is_integer(Nt),
                 is_integer(V), is_integer(D) ],
    array:from_list(Decoded).

%% --------------------------------------------------------------------
%% gateDrumKitHits/1 — pure.
%%
%% Parallel to drumKitHits/1 but for GateDrumKit's Array GateHit
%% (PR 2c).  Each GateHit decodes to #{name, gateChannel, durMs}.
%% Empty / non-array / malformed input returns an empty array.  The
%% walker shell turns each hit into a `gate-drum-kit … name:ch:dur,…`
%% binding spec entry.
%% --------------------------------------------------------------------
gateDrumKitHits(HitsForeign) ->
    List = try array:to_list(HitsForeign)
           catch _:_ -> []
           end,
    Decoded = [ #{ name => N, gateChannel => G, durMs => D }
              || #{name := N, gateChannel := G, durMs := D} <- List,
                 is_binary(N), is_integer(G), is_integer(D) ],
    array:from_list(Decoded).

%% --------------------------------------------------------------------
%% vPerOctFields/1 — pure.
%%
%% Decode the inner `{ gateChannel :: Int, voctBus :: Int }` record
%% from a VPerOctInstrument value.  Records encode as Erlang maps
%% with atom keys.  Returns `{just, #{gateChannel, voctBus}}` on
%% well-shaped input, `nothing` otherwise.
%% --------------------------------------------------------------------
vPerOctFields(#{gateChannel := G, voctBus := V})
    when is_integer(G), is_integer(V) ->
    {just, #{gateChannel => G, voctBus => V}};
vPerOctFields(_) ->
    {nothing}.

%% --------------------------------------------------------------------
%% polyLfoConfigFields/1 — pure.
%%
%% Decode the inner record of a `PolyLfoConfig` constructor:
%%
%%     PolyLfoConfig { bank :: Bank
%%                   , slots :: Array LfoSlot
%%                   , range :: Maybe OutputRange
%%                   }
%%
%% purs-backend-erl encodes this as:
%%
%%     {polyLfoConfig, #{bank => BankValue, slots => SlotsArray,
%%                       range => RangeValue}}
%%
%% Because Bank, LfoSlot, LfoWave, and OutputRange are all defined in
%% Tidal.Selene, the encoding inside the record matches what the
%% PureScript types expect.  We pass the inner record through verbatim;
%% the PureScript classifier reads it as the typed record directly.
%% No mapping happens at this seam — domain semantics (wire token
%% mapping) all live in `Tidal.Selene`.
%% --------------------------------------------------------------------
polyLfoConfigFields({polyLfoConfig, #{bank := _, slots := _, range := _} = M}) ->
    {just, M};
polyLfoConfigFields(_) ->
    {nothing}.

%% --------------------------------------------------------------------
%% polyClockConfigFields/1, polyEnvConfigFields/1, polyEuclidConfigFields/1,
%% polyRandConfigFields/1, polyPresetConfigFields/1,
%% polyPresetNoteConfigFields/1 — pure.
%%
%% Same passthrough pattern as polyLfoConfigFields above.  The
%% PureScript classifier dispatches by constructor tag and calls the
%% matching FFI; each one just verifies the record map carries the
%% three expected keys and hands it through.
%% --------------------------------------------------------------------
polyClockConfigFields({polyClockConfig,
                       #{bank := _, slots := _, range := _} = M}) ->
    {just, M};
polyClockConfigFields(_) ->
    {nothing}.

polyEnvConfigFields({polyEnvConfig,
                     #{bank := _, slots := _, range := _} = M}) ->
    {just, M};
polyEnvConfigFields(_) ->
    {nothing}.

polyEuclidConfigFields({polyEuclidConfig,
                        #{bank := _, slots := _, range := _} = M}) ->
    {just, M};
polyEuclidConfigFields(_) ->
    {nothing}.

polyRandConfigFields({polyRandConfig,
                      #{bank := _, slots := _, range := _} = M}) ->
    {just, M};
polyRandConfigFields(_) ->
    {nothing}.

polyPresetConfigFields({polyPresetConfig,
                        #{bank := _, slots := _, range := _} = M}) ->
    {just, M};
polyPresetConfigFields(_) ->
    {nothing}.

polyPresetNoteConfigFields({polyPresetNoteConfig,
                            #{bank := _, slots := _, range := _} = M}) ->
    {just, M};
polyPresetNoteConfigFields(_) ->
    {nothing}.

%% --------------------------------------------------------------------
%% balistesBindingFields/1 — pure.
%%
%% Decode the inner record of a `BalistesBinding` value.  Encoding:
%%
%%   {balistesBinding, #{device => {midiDevice, <<Name>>, Latency},
%%                    channel => Ch, noteBd => N, noteSd => N,
%%                    noteHh => N, vel => V, velAccent => V,
%%                    durMs => D, config => OpaqueCfg}}
%%
%% The classifier needs the device's (name, latency) tuple to look up
%% the alias from the content-keyed device-alias map.  Returns a flat
%% record with the device's name + latencyMs lifted out; `config`
%% passes through unchanged for the voice's per-step FFI use.
%% --------------------------------------------------------------------
balistesBindingFields({balistesBinding,
                    #{device      := {midiDevice, DevName, DevLat},
                      channel     := Ch,
                      noteBd      := NBd,
                      noteSd      := NSd,
                      noteHh      := NHh,
                      vel         := V,
                      velAccent   := VA,
                      durMs       := Dur,
                      config      := Cfg}})
    when is_binary(DevName), is_integer(DevLat),
         is_integer(Ch), is_integer(NBd), is_integer(NSd), is_integer(NHh),
         is_integer(V), is_integer(VA), is_integer(Dur) ->
    {just, #{deviceName       => DevName,
             deviceLatencyMs  => DevLat,
             channel          => Ch,
             noteBd           => NBd,
             noteSd           => NSd,
             noteHh           => NHh,
             vel              => V,
             velAccent        => VA,
             durMs            => Dur,
             config           => Cfg}};
balistesBindingFields(_) ->
    {nothing}.

%% --------------------------------------------------------------------
%% repetitorBindingFields/1 — pure.
%%
%% Decode the inner record of a `RepetitorBinding` value.  Encoding:
%%
%%   {repetitorBinding,
%%      #{device => {midiDevice, <<Name>>, Latency},
%%        channel => Ch,
%%        noteM => N, noteC1 => N, noteC2 => N, noteC3 => N,
%%        vel => V, durMs => D, stepsPerCycle => Sp,
%%        library => <<Lib>>, patternSlug => <<Slug>>,
%%        config => OpaqueCfg}}
%% --------------------------------------------------------------------
repetitorBindingFields({repetitorBinding,
                        #{device        := {midiDevice, DevName, DevLat},
                          channel       := Ch,
                          noteM         := NM,
                          noteC1        := NC1,
                          noteC2        := NC2,
                          noteC3        := NC3,
                          vel           := V,
                          durMs         := Dur,
                          stepsPerCycle := Sp,
                          library       := Lib,
                          patternSlug   := Slug,
                          config        := Cfg}})
    when is_binary(DevName), is_integer(DevLat),
         is_integer(Ch),
         is_integer(NM), is_integer(NC1), is_integer(NC2), is_integer(NC3),
         is_integer(V), is_integer(Dur), is_integer(Sp),
         is_binary(Lib), is_binary(Slug) ->
    {just, #{deviceName      => DevName,
             deviceLatencyMs => DevLat,
             channel         => Ch,
             noteM           => NM,
             noteC1          => NC1,
             noteC2          => NC2,
             noteC3          => NC3,
             vel             => V,
             durMs           => Dur,
             stepsPerCycle   => Sp,
             library         => Lib,
             patternSlug     => Slug,
             config          => Cfg}};
repetitorBindingFields(_) ->
    {nothing}.

%% --------------------------------------------------------------------
%% odonusBindingFields/1 — pure.
%%
%% Encoding:
%%   {odonusBinding,
%%      #{device => {midiDevice, <<Name>>, Latency},
%%        channel => Ch, vel => V, durMs => D,
%%        stepsPerCycle => Sp,
%%        notes => Array16Int,    -- Erlang `array` module value
%%        skip => Array16Bool, gate => Array16Bool, glide => Array16Bool,
%%        navMode => {navCartesian} | {navForward} | {navReverse},
%%        config => OpaqueCfg}}
%%
%% navMode is decoded into a string ("cartesian" / "forward" /
%% "reverse") so the apply_event side can match on a plain atom
%% without re-implementing ADT-tag inspection.  Arrays stay as
%% PureScript Array (Erlang `array` module) — apply_event handler
%% does array:to_list/1 at the engine seam.
%% --------------------------------------------------------------------
odonusBindingFields({odonusBinding,
                   #{device        := {midiDevice, DevName, DevLat},
                     channel       := Ch,
                     vel           := V,
                     durMs         := Dur,
                     stepsPerCycle := Sp,
                     notes         := Notes,
                     skip          := Skip,
                     gate          := Gate,
                     glide         := Glide,
                     navMode       := NavTuple,
                     config        := Cfg}})
    when is_binary(DevName), is_integer(DevLat),
         is_integer(Ch), is_integer(V), is_integer(Dur),
         is_integer(Sp) ->
    {just, #{deviceName      => DevName,
             deviceLatencyMs => DevLat,
             channel         => Ch,
             vel             => V,
             durMs           => Dur,
             stepsPerCycle   => Sp,
             notes           => Notes,
             skip            => Skip,
             gate            => Gate,
             glide           => Glide,
             navMode         => nav_mode_to_binary(NavTuple),
             config          => Cfg}};
odonusBindingFields(_) ->
    {nothing}.

nav_mode_to_binary({navCartesian}) -> <<"cartesian">>;
nav_mode_to_binary({navForward})   -> <<"forward">>;
nav_mode_to_binary({navReverse})   -> <<"reverse">>;
nav_mode_to_binary(_)              -> <<"cartesian">>.
