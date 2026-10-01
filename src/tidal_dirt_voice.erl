%% @doc A Tidal stream to SuperDirt: one process per `d1`..`d16`.
%%
%% Holds a `Tidal.DirtVoice.State` (opaque here) and a UDP socket. On each
%% `{compute_until, Window}` from tidal_clock it asks the PureScript side for
%% the `/dirt/play` messages that window holds and sends each as a bundle
%% timetagged at its onset (dirt_osc). The timing rules (arc from where the
%% last one ended, onsets only, snap on a clock jump) are in DirtVoice.purs.
%%
%% Registered as `tidal_dirt_d<N>`: a namespace of its own, so a `bind d1 …`
%% for the binding voices cannot redirect a Tidal stream.
-module(tidal_dirt_voice).
-behaviour(gen_server).

-export([start_link/1, set_pattern/2, registered_name/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

start_link(Stream) ->
    gen_server:start_link({local, registered_name(Stream)}, ?MODULE, Stream, []).

%% Install a ControlPattern on the stream; heard from the next arc.
set_pattern(Stream, Pattern) ->
    gen_server:call(registered_name(Stream), {set_pattern, Pattern}).

registered_name(Stream) when is_integer(Stream) ->
    list_to_atom("tidal_dirt_d" ++ integer_to_list(Stream)).

init(Stream) ->
    {ok, Sock} = gen_udp:open(0, [binary]),
    {ok, {Stream, 'tidal_dirtVoice@ps':initialState(Stream), Sock}}.

handle_call({set_pattern, Pattern}, _From, {Stream, Ps, Sock}) ->
    {reply, ok, {Stream, 'tidal_dirtVoice@ps':setPattern(Pattern, Ps), Sock}}.

handle_cast({compute_until, Window}, {Stream, Ps, Sock}) ->
    #{newState := Ps1, messages := Messages} =
        'tidal_dirtVoice@ps':computeUntil(Window, Ps),
    %% PureScript arrays are Erlang `array`s; the args inside one too.
    array:foldl(
      fun(_, #{atUnixUs := At, args := Args}, _) ->
              Msg = dirt_osc:encode_msg(<<"/dirt/play">>, array:to_list(Args)),
              dirt_osc:send_at(Sock, round(At), Msg)
      end, ok, Messages),
    {noreply, {Stream, Ps1, Sock}};
handle_cast(_, State) ->
    {noreply, State}.

handle_info(_, State) ->
    {noreply, State}.

terminate(_Reason, {_, _, Sock}) ->
    gen_udp:close(Sock),
    ok.
