-module(iec60870_app).
-moduledoc "Application callback for the `iec60870` library.".
-behaviour(application).

-export([start/2, stop/1]).

-spec start(application:start_type(), term()) ->
        {ok, pid()} | {error, term()}.
start(_StartType, _StartArgs) ->
    iec60870_sup:start_link().

-spec stop(term()) -> ok.
stop(_State) ->
    ok.
