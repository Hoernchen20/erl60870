%%% @doc Example `iec60870_server' callback (docs/DESIGN.md section 7) for
%%% `simple_rtu': IOA 100 is a remote-controllable switch. A C_SC_NA_1 single
%%% command (direct execute, or select-before-operate) is accepted and its
%%% value mirrored back into the data model via `iec60870_server:update/3',
%%% so a later read command / interrogation reports the new state. Every
%%% other command is rejected, and clock sync is always accepted.
-module(simple_rtu_callback).
-behaviour(iec60870_server).

-export([init/1, select/2, execute/2, clock_sync/3, connection_event/2]).

init(#{server := Server}) ->
    {ok, #{server => Server}}.

select(#{type := c_sc_na_1, ioa := 100}, State) ->
    {accept, State};
select(_Command, State) ->
    {reject, unknown_ioa, State}.

execute(#{type := c_sc_na_1, ioa := 100, coa := Coa, value := Value}, State) ->
    #{server := Server} = State,
    ok = iec60870_server:update(Server, {Coa, 100},
                                #{type    => m_sp_tb_1,
                                  value   => Value,
                                  quality => [],
                                  ts      => erlang:system_time(millisecond)}),
    {ok, State};
execute(_Command, State) ->
    {error, unknown_ioa, State}.

clock_sync(_Coa, _Time, State) ->
    {ok, State}.

connection_event(Event, State) ->
    logger:info("simple_rtu: ~p", [Event]),
    {ok, State}.
