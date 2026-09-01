%%% @doc End-to-end: a library-managed server driven by a raw `gen_tcp' client
%%% playing the controlling station. Covers interrogation (C_IC_NA_1), the
%%% spontaneous `update/3' path and ASDU batching.
-module(iec60870_server_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("iec60870/include/iec60870_asdu.hrl").

-export([suite/0, all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).

-export([station_interrogation/1, group_interrogation/1,
         interrogation_unknown_coa/1, spontaneous_on_change/1,
         no_frame_when_unchanged/1, bulk_update_batches/1,
         buffered_until_active/1, callback_explicit_dump/1]).

%% used as the callback module by callback_explicit_dump/1
-export([init/1, interrogation/3]).

-define(PARAMS, #{t1 => 20000, t2 => 5000, t3 => 60000}).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [station_interrogation, group_interrogation, interrogation_unknown_coa,
     spontaneous_on_change, no_frame_when_unchanged, bulk_update_batches,
     buffered_until_active, callback_explicit_dump].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(iec60870),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(TC, Config) ->
    Server = TC,
    {ok, _} = iec60870:start_server(Server, server_config(TC)),
    Port = iec60870_server:listener_port(Server),
    [{server, Server}, {port, Port} | Config].

end_per_testcase(_TC, Config) ->
    _ = iec60870:stop_server(?config(server, Config)),
    ok.

server_config(station_interrogation) ->
    with_points([{{1, 100}, #{type => m_sp_na_1, value => true}},
                 {{1, 101}, #{type => m_sp_na_1, value => false}},
                 {{1, 200}, #{type => m_me_nc_1, value => 3.5}}]);
server_config(group_interrogation) ->
    with_points([{{1, 10}, #{type => m_sp_na_1, value => true, group => 1}},
                 {{1, 11}, #{type => m_sp_na_1, value => true, group => 2}},
                 {{1, 12}, #{type => m_sp_na_1, value => true}}]);
server_config(callback_explicit_dump) ->
    (base_config())#{callback => {?MODULE, #{}}};
server_config(_TC) ->
    base_config().

base_config() ->
    #{transport => {tcp, [{ip, {127, 0, 0, 1}}, {port, 0}]},
      common_addresses => [1],
      data_model => {iec60870_dm_ets, #{}},
      params => ?PARAMS}.

with_points(Points) ->
    (base_config())#{data_model => {iec60870_dm_ets, #{points => Points}}}.

%%%===================================================================
%%% Interrogation
%%%===================================================================

station_interrogation(Config) ->
    S = active(Config),
    send_i(S, 0, 0, c_ic(1, 20)),
    ?assertMatch(#asdu{type = c_ic_na_1, cot = act_con, negative = false},
                 recv_asdu(S)),
    {Dump, Term} = recv_dump(S, []),
    ?assertMatch(#asdu{type = c_ic_na_1, cot = act_term}, Term),
    ?assertEqual(lists:sort([{100, true}, {101, false}, {200, 3.5}]),
                 dump_points(Dump)),
    %% the two contiguous single points are packed as one SQ=1 ASDU
    [SpAsdu] = [A || A <- Dump, A#asdu.type =:= m_sp_na_1],
    ?assertEqual(true, SpAsdu#asdu.sequence),
    ?assert(lists:all(fun(A) -> A#asdu.cot =:= interrogated_station end, Dump)).

group_interrogation(Config) ->
    S = active(Config),
    send_i(S, 0, 0, c_ic(1, 21)),
    ?assertMatch(#asdu{cot = act_con, negative = false}, recv_asdu(S)),
    {Dump, _Term} = recv_dump(S, []),
    ?assertEqual([{10, true}], dump_points(Dump)),
    ?assert(lists:all(fun(A) -> A#asdu.cot =:= {interrogated_group, 1} end, Dump)).

interrogation_unknown_coa(Config) ->
    S = active(Config),
    send_i(S, 0, 0, c_ic(99, 20)),
    ?assertMatch(#asdu{type = c_ic_na_1, cot = act_con, negative = true},
                 recv_asdu(S)),
    ok = expect_no_data(S, 300).

callback_explicit_dump(Config) ->
    S = active(Config),
    send_i(S, 0, 0, c_ic(1, 20)),
    ?assertMatch(#asdu{cot = act_con, negative = false}, recv_asdu(S)),
    {Dump, Term} = recv_dump(S, []),
    ?assertMatch(#asdu{type = c_ic_na_1, cot = act_term}, Term),
    ?assertEqual([{777, true}], dump_points(Dump)).

%% callback: replace the automatic dump with a single hand-built ASDU
init(_Args) -> {ok, []}.

interrogation(Coa, _Qoi, State) ->
    {ok, [#{type => m_sp_na_1, coa => Coa, cot => interrogated_station,
            objects => [#object{ioa = 777, value = true, quality = []}]}], State}.

%%%===================================================================
%%% Spontaneous path
%%%===================================================================

spontaneous_on_change(Config) ->
    Server = ?config(server, Config),
    S = active(Config),
    ok = iec60870_server:update(Server, {1, 100}, #{type => m_sp_na_1, value => true}),
    ?assertMatch(#asdu{type = m_sp_na_1, cot = spontaneous,
                       objects = [#object{ioa = 100, value = true}]},
                 recv_asdu(S)).

no_frame_when_unchanged(Config) ->
    Server = ?config(server, Config),
    S = active(Config),
    ok = iec60870_server:update(Server, {1, 100}, #{type => m_sp_na_1, value => true}),
    ?assertMatch(#asdu{cot = spontaneous}, recv_asdu(S)),
    ok = iec60870_server:update(Server, {1, 100}, #{type => m_sp_na_1, value => true}),
    ok = expect_no_data(S, 400).

bulk_update_batches(Config) ->
    Server = ?config(server, Config),
    S = active(Config),
    ok = iec60870_server:update(Server,
           [{{1, 10}, #{type => m_sp_na_1, value => true}},
            {{1, 11}, #{type => m_sp_na_1, value => false}},
            {{1, 12}, #{type => m_sp_na_1, value => true}}]),
    Asdu = recv_asdu(S),
    ?assertMatch(#asdu{type = m_sp_na_1, cot = spontaneous, sequence = true}, Asdu),
    ?assertEqual([10, 11, 12], [O#object.ioa || O <- Asdu#asdu.objects]),
    ok = expect_no_data(S, 200).

buffered_until_active(Config) ->
    Server = ?config(server, Config),
    S = connect(Config),
    ok = iec60870_server:update(Server, {1, 100}, #{type => m_sp_na_1, value => true}),
    ok = expect_no_data(S, 300),
    ok = do_startdt(S),
    ?assertMatch(#asdu{type = m_sp_na_1, cot = spontaneous,
                       objects = [#object{ioa = 100, value = true}]},
                 recv_asdu(S)).

%%%===================================================================
%%% Client helpers
%%%===================================================================

connect(Config) ->
    {ok, S} = gen_tcp:connect({127, 0, 0, 1}, ?config(port, Config),
                              [binary, {active, false}, {packet, 0}], 1000),
    S.

active(Config) ->
    S = connect(Config),
    ok = do_startdt(S),
    S.

do_startdt(S) ->
    ok = send_frame(S, {u, startdt_act}),
    {u, startdt_con} = recv_frame(S, 2000),
    ok.

send_frame(S, Frame) ->
    gen_tcp:send(S, iec60870_104_apci:encode(Frame)).

send_i(S, NS, NR, AsduBin) ->
    send_frame(S, {i, NS, NR, AsduBin}).

recv_frame(S, Timeout) ->
    {ok, <<16#68, Len>>} = gen_tcp:recv(S, 2, Timeout),
    {ok, Body} = gen_tcp:recv(S, Len, Timeout),
    {ok, Frame, <<>>} = iec60870_104_apci:decode(<<16#68, Len, Body/binary>>),
    Frame.

recv_asdu(S) ->
    case recv_frame(S, 2000) of
        {i, _NS, _NR, Bin} ->
            {ok, Asdu, <<>>} = iec60870_asdu:decode(Bin),
            Asdu;
        Other ->
            ct:fail({expected_i_frame, Other})
    end.

%% Read dump ASDUs until the C_IC act_term arrives.
recv_dump(S, Acc) ->
    case recv_asdu(S) of
        #asdu{type = c_ic_na_1, cot = act_term} = Term ->
            {lists:reverse(Acc), Term};
        Asdu ->
            recv_dump(S, [Asdu | Acc])
    end.

dump_points(Asdus) ->
    lists:sort([{O#object.ioa, O#object.value}
                || A <- Asdus, O <- A#asdu.objects]).

expect_no_data(S, Timeout) ->
    case gen_tcp:recv(S, 0, Timeout) of
        {error, timeout} -> ok;
        {ok, Data} -> ct:fail({unexpected_data, Data})
    end.

c_ic(Coa, Qoi) ->
    iec60870_asdu:encode(
      #asdu{type = c_ic_na_1, cot = act, coa = Coa,
            objects = [#object{ioa = 0, value = Qoi}]}).
