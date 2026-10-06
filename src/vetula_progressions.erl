%% @doc Vetula's saved progressions as the rig reads them (step 4b,
%% docs/kb/plans/vetula-visibility-audit.md).
%%
%% Vetula writes each saved progression to the stage as
%% `vetula/progression/<name>`, its chords as one quoted line. A card may name
%% one instead of writing its chords in (`v1 $ vetula "bolt-tractor-horse"`),
%% so the processes that read cards (vetula_cards, odonus_feeds) keep these
%% beside them and read a card through `parse/3`; when a progression changes
%% they read their cards again, and every voice naming it follows.
-module(vetula_progressions).

-export([take/3, parse/3]).

-define(PREFIX, "vetula/progression/").

%% A stage object written (or, with null, deleted): `{changed, Progs1}` when
%% it is a progression, else `same`.
take(<<?PREFIX, Name/binary>>, null, Progs) when Name =/= <<>> ->
    {changed, maps:remove(Name, Progs)};
take(<<?PREFIX, Name/binary>>, Text, Progs) when Name =/= <<>> ->
    {changed, Progs#{Name => 'reef_vetula_lepidoptera@ps':readProgression(Text)}};
take(_, _, _) ->
    same.

%% Card N's text, its named progression looked up.
parse(Progs, N, Text) ->
    Lookup = fun(Name) ->
                     case maps:find(Name, Progs) of
                         {ok, Chords} -> {just, Chords};
                         error -> {nothing}
                     end
             end,
    'reef_vetula_lepidoptera@ps':parseCardIn(Lookup, N, Text).
