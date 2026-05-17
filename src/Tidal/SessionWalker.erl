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
        , firstHitDefaults/1
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
%% firstHitDefaults/1 — pure.
%%
%% A `DrumKit`'s hits field is an Erlang stdlib `array` of DrumHit
%% records.  Read element 0 (the first hit) and pull its
%% (note, vel, durMs) fields out.  Returns a record where each field
%% is Maybe Int — `{nothing}` for an empty array, missing field, or
%% non-array input.
%%
%% PR 2a uses this to derive the kit's binding-level defaults from
%% the first hit; PR 2b iterates the whole array.
%% --------------------------------------------------------------------
firstHitDefaults(HitsForeign) ->
    Hit = try array:get(0, HitsForeign)
          catch _:_ -> undefined
          end,
    case Hit of
        #{note := N, vel := V, durMs := D}
          when is_integer(N), is_integer(V), is_integer(D) ->
            #{ note   => {just, N}
             , vel    => {just, V}
             , durMs  => {just, D}
             };
        _ ->
            #{ note   => {nothing}
             , vel    => {nothing}
             , durMs  => {nothing}
             }
    end.
