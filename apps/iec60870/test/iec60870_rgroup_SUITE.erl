%%% @doc Redundancy groups (docs/DESIGN.md section 5) driven end to end: a
%%% library-managed server, one or more raw `gen_tcp' clients per test playing
%%% controlling stations, exercising all three `redundancy.mode's, the
%%% per-group event buffer and switchover replay.
%%%
%%% The `multiple' mode case binds clients to distinct 127.0.0.0/8 source
%%% addresses (Linux loopback) so the server can tell the groups apart by peer
%%% address.
-module(iec60870_rgroup_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("iec60870/include/iec60870_asdu.hrl").

-export([suite/0, all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).

-export([connection_mode_broadcasts/1, connection_mode_independent_groups/1,
         single_mode_one_active/1, single_mode_switchover_replay/1,
         single_mode_released_shrinks_buffer/1,
         single_mode_buffers_until_active/1,
         multiple_mode_by_peer_ip/1]).

-define(PARAMS, #{t1 => 20000, t2 => 5000, t3 => 60000}).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [connection_mode_broadcasts, connection_mode_independent_groups,
     single_mode_one_active, single_mode_switchover_replay,
     single_mode_released_shrinks_buffer, single_mode_buffers_until_active,
     multiple_mode_by_peer_ip].

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

server_config(single_mode_one_active) -> redundancy(#{mode => single});
server_config(single_mode_switchover_replay) -> redundancy(#{mode => single});
server_config(single_mode_released_shrinks_buffer) -> redundancy(#{mode => single});
server_config(single_mode_buffers_until_active) -> redundancy(#{mode => single});
server_config(multiple_mode_by_peer_ip) ->
    redundancy(#{mode => multiple,
                 groups => [#{name => scada_a,
                              match => [{ip, {127, 0, 0, 2}, 32}]}],
                 default => #{}});
server_config(_TC) ->
    base_config().

base_config() ->
    #{transport => {tcp, [{ip, {127, 0, 0, 1}}, {port, 0}]},
      common_addresses => [1],
      data_model => {iec60870_dm_ets, #{}},
      params => ?PARAMS}.

redundancy(Red) ->
    (base_config())#{redundancy => Red}.

%%%===================================================================
%%% connection mode (default) — every connection is its own group
%%%===================================================================

connection_mode_broadcasts(Config) ->
    A = active(Config),
    B = active(Config),
    update(Config, 100, true),
    ?assertEqual({100, true}, sp(recv_asdu(A))),
    ?assertEqual({100, true}, sp(recv_asdu(B))).

connection_mode_independent_groups(Config) ->
    A = active(Config),
    B = active(Config),
    ?assertEqual(2, length(groups(Config))),
    update(Config, 100, true),
    ?assertEqual({100, true}, sp(recv_asdu(A))),
    ?assertEqual({100, true}, sp(recv_asdu(B))),
    ok = gen_tcp:close(A),
    wait_until(fun() -> length(groups(Config)) =:= 1 end),
    update(Config, 101, false),
    ?assertEqual({101, false}, sp(recv_asdu(B))).

%%%===================================================================
%%% single mode — one shared group, one active connection
%%%===================================================================

single_mode_one_active(Config) ->
    A = active(Config),
    update(Config, 100, true),
    ?assertEqual({100, true}, sp(recv_asdu(A))),
    %% N(R)=2: the automatic end-of-init I-frame (drained by active/1) and
    %% the update above are sequence 0 and 1 respectively.
    ack(A, 2),
    wait_until(fun() -> buffer_len(Config) =:= 0 end),

    B = active(Config),
    ok = expect_no_data(B, 200),

    update(Config, 101, false),
    ?assertEqual({101, false}, sp(recv_asdu(B))),
    ok = expect_no_data(A, 200).

single_mode_switchover_replay(Config) ->
    A = active(Config),
    update(Config, 100, true),
    ?assertEqual({100, true}, sp(recv_asdu(A))),
    update(Config, 101, true),
    ?assertEqual({101, true}, sp(recv_asdu(A))),

    %% A never acknowledged — both events are replayed on B.
    B = active(Config),
    ?assertEqual({100, true}, sp(recv_asdu(B))),
    ?assertEqual({101, true}, sp(recv_asdu(B))),

    update(Config, 102, true),
    ?assertEqual({102, true}, sp(recv_asdu(B))),
    ok = expect_no_data(A, 200).

single_mode_released_shrinks_buffer(Config) ->
    A = active(Config),
    update(Config, 100, true),
    update(Config, 101, true),
    update(Config, 102, true),
    [_, _, _] = [recv_asdu(A) || _ <- [1, 2, 3]],

    ?assertEqual(3, buffer_len(Config)),
    %% N(R)=4: the automatic end-of-init I-frame (drained by active/1) plus
    %% the three updates above are sequence 0 through 3.
    ack(A, 4),
    wait_until(fun() -> buffer_len(Config) =:= 0 end),
    ?assertEqual(3, maps:get(released, group_info(Config))).

single_mode_buffers_until_active(Config) ->
    S = connect(Config),
    update(Config, 100, true),
    ok = expect_no_data(S, 300),
    ?assertEqual(1, buffer_len(Config)),
    ok = do_startdt(S),
    ?assertMatch(#asdu{type = m_ei_na_1}, recv_asdu(S)),
    ?assertEqual({100, true}, sp(recv_asdu(S))).

%%%===================================================================
%%% multiple mode — groups matched by peer address
%%%===================================================================

multiple_mode_by_peer_ip(Config) ->
    A = active_from(Config, {127, 0, 0, 2}),
    D = active(Config),

    update(Config, 100, true),
    ?assertEqual({100, true}, sp(recv_asdu(A))),
    ?assertEqual({100, true}, sp(recv_asdu(D))),

    Sup = rgroup_sup(Config),
    ScadaA = iec60870_rgroup_sup:group_pid(Sup, scada_a),
    Default = iec60870_rgroup_sup:group_pid(Sup, default),
    ?assert(is_pid(ScadaA)),
    ?assert(is_pid(Default)),
    ?assertMatch(#{members := [_], state := {active, _}}, iec60870_rgroup:info(ScadaA)),
    ?assertMatch(#{members := [_], state := {active, _}}, iec60870_rgroup:info(Default)).

%%%===================================================================
%%% group introspection
%%%===================================================================

rgroup_sup(Config) ->
    iec60870_registry:whereis_name({rgroup_sup, ?config(server, Config)}).

groups(Config) ->
    iec60870_rgroup_sup:which_groups(rgroup_sup(Config)).

%% The single shared group (single mode).
group_info(Config) ->
    [G] = groups(Config),
    iec60870_rgroup:info(G).

buffer_len(Config) ->
    maps:get(buffer_len, group_info(Config)).

wait_until(Pred) -> wait_until(Pred, 100).
wait_until(Pred, 0) -> ?assert(Pred());
wait_until(Pred, N) ->
    case Pred() of
        true -> ok;
        false -> timer:sleep(20), wait_until(Pred, N - 1)
    end.

%%%===================================================================
%%% Client helpers
%%%===================================================================

connect(Config) ->
    connect_opts(Config, []).

connect_from(Config, SrcIp) ->
    connect_opts(Config, [{ip, SrcIp}]).

connect_opts(Config, Extra) ->
    {ok, S} = gen_tcp:connect({127, 0, 0, 1}, ?config(port, Config),
                              [binary, {active, false}, {packet, 0} | Extra], 1000),
    S.

%% Every server config in this suite leaves `coi' at its library default
%% (enabled), so activation always delivers one automatic end-of-init ASDU
%% (M_EI_NA_1) first — drained here so the rest of each test only sees the
%% frames it triggers itself (see docs/DESIGN.md section 7).
active(Config) ->
    S = connect(Config),
    ok = do_startdt(S),
    ?assertMatch(#asdu{type = m_ei_na_1}, recv_asdu(S)),
    S.

active_from(Config, SrcIp) ->
    S = connect_from(Config, SrcIp),
    ok = do_startdt(S),
    ?assertMatch(#asdu{type = m_ei_na_1}, recv_asdu(S)),
    S.

do_startdt(S) ->
    ok = send_frame(S, {u, startdt_act}),
    {u, startdt_con} = recv_frame(S, 2000),
    ok.

update(Config, Ioa, Value) ->
    ok = iec60870_server:update(?config(server, Config), {1, Ioa},
                                #{type => m_sp_na_1, value => Value}).

ack(S, NR) ->
    send_frame(S, {s, NR}).

send_frame(S, Frame) ->
    gen_tcp:send(S, iec60870_104_apci:encode(Frame)).

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

sp(#asdu{type = m_sp_na_1, cot = spontaneous, objects = [#object{ioa = Ioa, value = V}]}) ->
    {Ioa, V}.

expect_no_data(S, Timeout) ->
    case gen_tcp:recv(S, 0, Timeout) of
        {error, timeout} -> ok;
        {ok, Data} -> ct:fail({unexpected_data, Data})
    end.
