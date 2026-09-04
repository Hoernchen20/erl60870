%%% End-to-end: a library-managed server driven by a raw `gen_tcp' client
%%% playing the controlling station. Covers interrogation (C_IC_NA_1), the
%%% spontaneous `update/3' path, ASDU batching, commands (C_SC/C_DC/C_RC/C_SE,
%%% direct + select-before-operate + async) and clock sync (C_CS_NA_1).
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

-export([direct_single_command/1, direct_command_rejected/1,
         select_before_operate/1, select_rejected/1,
         operate_mismatched_select/1, select_timeout_expires/1,
         async_command_ok/1, async_command_error/1, command_unknown_coa/1,
         clock_sync_command/1, clock_sync_no_confirm/1]).

-export([counter_interrogation_station/1, counter_interrogation_group/1,
         counter_interrogation_freeze_reset/1,
         counter_interrogation_unknown_coa/1, counter_interrogation_explicit/1,
         read_command_found/1, read_command_not_found/1,
         read_command_unknown_coa/1, test_command_ok/1,
         test_command_unknown_coa/1, end_of_init_on_connect/1,
         end_of_init_disabled/1, background_scan_always_sent/1,
         parameter_set_ok/1, parameter_set_rejected/1,
         parameter_set_no_callback/1, parameter_activate_ok/1]).

%% used as the callback module by callback_explicit_dump/1, the command /
%% clock sync / counter interrogation / parameter cases; behaviour picked by
%% magic IOAs, relayed to the `test' pid stashed in the init args (see
%% with_callback/1)
-export([init/1, interrogation/3, select/2, execute/2, clock_sync/3,
         counter_interrogation/3, set_parameter/5, activate_parameter/4]).

-define(PARAMS, #{t1 => 20000, t2 => 5000, t3 => 60000}).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [station_interrogation, group_interrogation, interrogation_unknown_coa,
     spontaneous_on_change, no_frame_when_unchanged, bulk_update_batches,
     buffered_until_active, callback_explicit_dump,
     direct_single_command, direct_command_rejected, select_before_operate,
     select_rejected, operate_mismatched_select, select_timeout_expires,
     async_command_ok, async_command_error, command_unknown_coa,
     clock_sync_command, clock_sync_no_confirm,
     counter_interrogation_station, counter_interrogation_group,
     counter_interrogation_freeze_reset, counter_interrogation_unknown_coa,
     counter_interrogation_explicit,
     read_command_found, read_command_not_found, read_command_unknown_coa,
     test_command_ok, test_command_unknown_coa,
     end_of_init_on_connect, end_of_init_disabled, background_scan_always_sent,
     parameter_set_ok, parameter_set_rejected, parameter_set_no_callback,
     parameter_activate_ok].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(iec60870),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(TC, Config) ->
    Server = TC,
    {ok, _} = iec60870:start_server(Server, server_config(TC, self())),
    Port = iec60870_server:listener_port(Server),
    [{server, Server}, {port, Port} | Config].

end_per_testcase(_TC, Config) ->
    _ = iec60870:stop_server(?config(server, Config)),
    ok.

server_config(station_interrogation, _TestPid) ->
    with_points([{{1, 100}, #{type => m_sp_na_1, value => true}},
                 {{1, 101}, #{type => m_sp_na_1, value => false}},
                 {{1, 200}, #{type => m_me_nc_1, value => 3.5}}]);
server_config(group_interrogation, _TestPid) ->
    with_points([{{1, 10}, #{type => m_sp_na_1, value => true, group => 1}},
                 {{1, 11}, #{type => m_sp_na_1, value => true, group => 2}},
                 {{1, 12}, #{type => m_sp_na_1, value => true}}]);
server_config(callback_explicit_dump, _TestPid) ->
    (base_config())#{callback => {?MODULE, #{}}};
server_config(counter_interrogation_explicit, _TestPid) ->
    (base_config())#{callback => {?MODULE, #{}}};
server_config(select_timeout_expires, TestPid) ->
    (with_callback(TestPid))#{select_timeout => 200};
server_config(clock_sync_no_confirm, TestPid) ->
    (with_callback(TestPid))#{clock_sync_confirm => false};
server_config(TC, TestPid) when TC =:= direct_single_command;
                                TC =:= direct_command_rejected;
                                TC =:= select_before_operate;
                                TC =:= select_rejected;
                                TC =:= operate_mismatched_select;
                                TC =:= async_command_ok;
                                TC =:= async_command_error;
                                TC =:= command_unknown_coa;
                                TC =:= clock_sync_command;
                                TC =:= parameter_set_ok;
                                TC =:= parameter_set_rejected;
                                TC =:= parameter_activate_ok ->
    with_callback(TestPid);
server_config(TC, _TestPid) when TC =:= counter_interrogation_station;
                                 TC =:= counter_interrogation_group;
                                 TC =:= counter_interrogation_freeze_reset ->
    with_points([{{1, 50}, #{type => m_it_na_1, value => 100, group => 1}},
                 {{1, 51}, #{type => m_it_na_1, value => 200, group => 2}}]);
server_config(TC, _TestPid) when TC =:= read_command_found;
                                 TC =:= read_command_not_found;
                                 TC =:= read_command_unknown_coa ->
    with_points([{{1, 100}, #{type => m_me_nc_1, value => 3.5}}]);
server_config(end_of_init_disabled, _TestPid) ->
    (base_config())#{coi => false};
server_config(_TC, _TestPid) ->
    base_config().

base_config() ->
    #{transport => {tcp, [{ip, {127, 0, 0, 1}}, {port, 0}]},
      common_addresses => [1],
      data_model => {iec60870_dm_ets, #{}},
      params => ?PARAMS}.

with_points(Points) ->
    (base_config())#{data_model => {iec60870_dm_ets, #{points => Points}}}.

with_callback(TestPid) ->
    (base_config())#{callback => {?MODULE, #{test => TestPid}}}.

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
init(Args) -> {ok, Args}.

interrogation(Coa, _Qoi, State) ->
    {ok, [#{type => m_sp_na_1, coa => Coa, cot => interrogated_station,
            objects => [#object{ioa = 777, value = true, quality = []}]}], State}.

%%%===================================================================
%%% Commands / clock sync — behaviour picked by magic IOAs, relayed to the
%%% `test' pid in the init args (`#{}' when the callback isn't exercised)
%%%===================================================================

%% ioa 5001: reject the select.
select(#{ioa := 5001} = Cmd, State) ->
    relay(State, {select, Cmd}),
    {reject, unknown_ioa, State};
select(Cmd, State) ->
    relay(State, {select, Cmd}),
    {accept, State}.

%% ioa 6001: reject the execute. ioa 7001: accept asynchronously.
execute(#{ioa := 6001} = Cmd, State) ->
    relay(State, {execute, Cmd}),
    {error, unknown_type_id, State};
execute(#{ioa := 7001} = Cmd, State) ->
    Ref = make_ref(),
    relay(State, {execute_async, Cmd, Ref}),
    {async, Ref, State};
execute(Cmd, State) ->
    relay(State, {execute, Cmd}),
    {ok, State}.

clock_sync(Coa, Time, State) ->
    relay(State, {clock_sync, Coa, Time}),
    {ok, State}.

%% Explicit counter dump for counter_interrogation_explicit/1.
counter_interrogation(Coa, _Qcc, State) ->
    {ok, [#{type => m_it_na_1, coa => Coa, cot => interrogated_counter,
            objects => [#object{ioa = 888, value = 42}]}], State}.

%% ioa 8001: reject the parameter write.
set_parameter(_Coa, 8001, _Value, _Qpm, State) ->
    relay(State, {set_parameter, 8001}),
    {error, unknown_ioa, State};
set_parameter(Coa, Ioa, Value, Qpm, State) ->
    relay(State, {set_parameter, Coa, Ioa, Value, Qpm}),
    {ok, State}.

activate_parameter(Coa, Ioa, Qpa, State) ->
    relay(State, {activate_parameter, Coa, Ioa, Qpa}),
    {ok, State}.

relay(#{test := TestPid}, Msg) when is_pid(TestPid) ->
    TestPid ! {cb, Msg},
    ok;
relay(_State, _Msg) ->
    ok.

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
    ?assertMatch(#asdu{type = m_ei_na_1}, recv_asdu(S)),
    ?assertMatch(#asdu{type = m_sp_na_1, cot = spontaneous,
                       objects = [#object{ioa = 100, value = true}]},
                 recv_asdu(S)).

%%%===================================================================
%%% Commands (C_SC/C_DC/C_RC/C_SE) — direct execute, select-before-operate,
%%% async execute
%%%===================================================================

direct_single_command(Config) ->
    S = active(Config),
    Obj = iec60870_asdu:single_command(100, true, #{}),
    send_i(S, 0, 0, cmd_asdu(c_sc_na_1, 1, Obj)),
    ?assertMatch({execute, #{type := c_sc_na_1, ioa := 100, value := true,
                             select := false}},
                 recv_cb()),
    ?assertMatch(#asdu{type = c_sc_na_1, cot = act_con, negative = false},
                 recv_asdu(S)),
    ?assertMatch(#asdu{type = c_sc_na_1, cot = act_term, negative = false},
                 recv_asdu(S)).

direct_command_rejected(Config) ->
    S = active(Config),
    Obj = iec60870_asdu:single_command(6001, true, #{}),
    send_i(S, 0, 0, cmd_asdu(c_sc_na_1, 1, Obj)),
    ?assertMatch({execute, #{ioa := 6001}}, recv_cb()),
    ?assertMatch(#asdu{type = c_sc_na_1, cot = unknown_type_id, negative = true},
                 recv_asdu(S)),
    ok = expect_no_data(S, 300).

select_before_operate(Config) ->
    S = active(Config),
    SelObj = iec60870_asdu:single_command(100, true, #{select => true}),
    send_i(S, 0, 0, cmd_asdu(c_sc_na_1, 1, SelObj)),
    ?assertMatch({select, #{ioa := 100, select := true}}, recv_cb()),
    ?assertMatch(#asdu{type = c_sc_na_1, cot = act_con, negative = false},
                 recv_asdu(S)),
    OpObj = iec60870_asdu:single_command(100, true, #{select => false}),
    send_i(S, 1, 0, cmd_asdu(c_sc_na_1, 1, OpObj)),
    ?assertMatch({execute, #{ioa := 100, select := false}}, recv_cb()),
    ?assertMatch(#asdu{type = c_sc_na_1, cot = act_con, negative = false},
                 recv_asdu(S)),
    ?assertMatch(#asdu{type = c_sc_na_1, cot = act_term, negative = false},
                 recv_asdu(S)).

select_rejected(Config) ->
    S = active(Config),
    Obj = iec60870_asdu:single_command(5001, true, #{select => true}),
    send_i(S, 0, 0, cmd_asdu(c_sc_na_1, 1, Obj)),
    ?assertMatch({select, #{ioa := 5001}}, recv_cb()),
    ?assertMatch(#asdu{type = c_sc_na_1, cot = unknown_ioa, negative = true},
                 recv_asdu(S)).

operate_mismatched_select(Config) ->
    S = active(Config),
    SelObj = iec60870_asdu:single_command(100, true, #{select => true}),
    send_i(S, 0, 0, cmd_asdu(c_sc_na_1, 1, SelObj)),
    ?assertMatch({select, _}, recv_cb()),
    ?assertMatch(#asdu{cot = act_con, negative = false}, recv_asdu(S)),
    %% same object, different value — not identical to what was selected
    OpObj = iec60870_asdu:single_command(100, false, #{select => false}),
    send_i(S, 1, 0, cmd_asdu(c_sc_na_1, 1, OpObj)),
    ?assertMatch(#asdu{type = c_sc_na_1, cot = act_con, negative = true},
                 recv_asdu(S)),
    ok = expect_no_data(S, 300),
    ok = expect_no_cb(300).

select_timeout_expires(Config) ->
    S = active(Config),
    SelObj = iec60870_asdu:single_command(100, true, #{select => true}),
    send_i(S, 0, 0, cmd_asdu(c_sc_na_1, 1, SelObj)),
    ?assertMatch({select, _}, recv_cb()),
    ?assertMatch(#asdu{cot = act_con, negative = false}, recv_asdu(S)),
    ct:sleep(400),
    %% the select timed out — the same operate now runs as a direct execute
    OpObj = iec60870_asdu:single_command(100, true, #{select => false}),
    send_i(S, 1, 0, cmd_asdu(c_sc_na_1, 1, OpObj)),
    ?assertMatch({execute, #{ioa := 100}}, recv_cb()),
    ?assertMatch(#asdu{cot = act_con, negative = false}, recv_asdu(S)),
    ?assertMatch(#asdu{cot = act_term, negative = false}, recv_asdu(S)).

async_command_ok(Config) ->
    S = active(Config),
    Obj = iec60870_asdu:single_command(7001, true, #{}),
    send_i(S, 0, 0, cmd_asdu(c_sc_na_1, 1, Obj)),
    {execute_async, _Cmd, Ref} = recv_cb(),
    ?assertMatch(#asdu{type = c_sc_na_1, cot = act_con, negative = false},
                 recv_asdu(S)),
    ok = iec60870_server:command_result(Ref, ok),
    ?assertMatch(#asdu{type = c_sc_na_1, cot = act_term, negative = false},
                 recv_asdu(S)).

async_command_error(Config) ->
    S = active(Config),
    Obj = iec60870_asdu:single_command(7001, true, #{}),
    send_i(S, 0, 0, cmd_asdu(c_sc_na_1, 1, Obj)),
    {execute_async, _Cmd, Ref} = recv_cb(),
    ?assertMatch(#asdu{type = c_sc_na_1, cot = act_con, negative = false},
                 recv_asdu(S)),
    ok = iec60870_server:command_result(Ref, {error, unknown_type_id}),
    ?assertMatch(#asdu{type = c_sc_na_1, cot = act_term, negative = true},
                 recv_asdu(S)).

command_unknown_coa(Config) ->
    S = active(Config),
    Obj = iec60870_asdu:single_command(100, true, #{}),
    send_i(S, 0, 0, cmd_asdu(c_sc_na_1, 99, Obj)),
    ?assertMatch(#asdu{type = c_sc_na_1, cot = act_con, negative = true},
                 recv_asdu(S)),
    ok = expect_no_cb(300).

%%%===================================================================
%%% Clock sync (C_CS_NA_1)
%%%===================================================================

clock_sync_command(Config) ->
    S = active(Config),
    Time = iec60870_cp56:from_timestamp(erlang:system_time(millisecond)),
    Obj = iec60870_asdu:clock_sync(Time),
    send_i(S, 0, 0, cmd_asdu(c_cs_na_1, 1, Obj)),
    ?assertMatch({clock_sync, 1, #cp56{}}, recv_cb()),
    ?assertMatch(#asdu{type = c_cs_na_1, cot = act_con, negative = false},
                 recv_asdu(S)).

clock_sync_no_confirm(Config) ->
    S = active(Config),
    Time = iec60870_cp56:from_timestamp(erlang:system_time(millisecond)),
    Obj = iec60870_asdu:clock_sync(Time),
    send_i(S, 0, 0, cmd_asdu(c_cs_na_1, 1, Obj)),
    ?assertMatch({clock_sync, 1, #cp56{}}, recv_cb()),
    ok = expect_no_data(S, 300).

%%%===================================================================
%%% Counter interrogation (C_CI_NA_1)
%%%===================================================================

counter_interrogation_station(Config) ->
    S = active(Config),
    send_i(S, 0, 0, c_ci(1, 5, read)),
    ?assertMatch(#asdu{type = c_ci_na_1, cot = act_con, negative = false},
                 recv_asdu(S)),
    {Dump, Term} = recv_counter_dump(S, []),
    ?assertMatch(#asdu{type = c_ci_na_1, cot = act_term}, Term),
    ?assertEqual(lists:sort([{50, 100}, {51, 200}]), dump_points(Dump)),
    ?assert(lists:all(fun(A) -> A#asdu.cot =:= interrogated_counter end, Dump)).

counter_interrogation_group(Config) ->
    S = active(Config),
    send_i(S, 0, 0, c_ci(1, 1, read)),
    ?assertMatch(#asdu{cot = act_con, negative = false}, recv_asdu(S)),
    {Dump, _Term} = recv_counter_dump(S, []),
    ?assertEqual([{50, 100}], dump_points(Dump)),
    ?assert(lists:all(fun(A) -> A#asdu.cot =:= {interrogated_counter_group, 1} end, Dump)).

counter_interrogation_freeze_reset(Config) ->
    S = active(Config),
    send_i(S, 0, 0, c_ci(1, 5, reset)),
    ?assertMatch(#asdu{cot = act_con, negative = false}, recv_asdu(S)),
    {Dump, _Term} = recv_counter_dump(S, []),
    %% the dump reports the value at the moment of the command...
    ?assertEqual(lists:sort([{50, 100}, {51, 200}]), dump_points(Dump)),
    %% ...and the reset applies after, so a second read comes back zero.
    send_i(S, 1, 0, c_ci(1, 5, read)),
    ?assertMatch(#asdu{cot = act_con, negative = false}, recv_asdu(S)),
    {Dump2, _Term2} = recv_counter_dump(S, []),
    ?assertEqual(lists:sort([{50, 0}, {51, 0}]), dump_points(Dump2)).

counter_interrogation_unknown_coa(Config) ->
    S = active(Config),
    send_i(S, 0, 0, c_ci(99, 5, read)),
    ?assertMatch(#asdu{type = c_ci_na_1, cot = act_con, negative = true},
                 recv_asdu(S)),
    ok = expect_no_data(S, 300).

counter_interrogation_explicit(Config) ->
    S = active(Config),
    send_i(S, 0, 0, c_ci(1, 5, read)),
    ?assertMatch(#asdu{cot = act_con, negative = false}, recv_asdu(S)),
    {Dump, Term} = recv_counter_dump(S, []),
    ?assertMatch(#asdu{type = c_ci_na_1, cot = act_term}, Term),
    ?assertEqual([{888, 42}], dump_points(Dump)).

%%%===================================================================
%%% Read command (C_RD_NA_1)
%%%===================================================================

read_command_found(Config) ->
    S = active(Config),
    send_i(S, 0, 0, c_rd(1, 100)),
    ?assertMatch(#asdu{type = m_me_nc_1, cot = request,
                       objects = [#object{ioa = 100, value = 3.5}]},
                 recv_asdu(S)).

read_command_not_found(Config) ->
    S = active(Config),
    send_i(S, 0, 0, c_rd(1, 999)),
    ?assertMatch(#asdu{type = c_rd_na_1, cot = unknown_ioa, negative = true},
                 recv_asdu(S)).

read_command_unknown_coa(Config) ->
    S = active(Config),
    send_i(S, 0, 0, c_rd(99, 100)),
    ?assertMatch(#asdu{type = c_rd_na_1, cot = unknown_coa, negative = true},
                 recv_asdu(S)).

%%%===================================================================
%%% Test command (C_TS_TA_1)
%%%===================================================================

test_command_ok(Config) ->
    S = active(Config),
    Time = iec60870_cp56:from_timestamp(erlang:system_time(millisecond)),
    Obj = iec60870_asdu:test_command(16#AA55, Time),
    send_i(S, 0, 0, cmd_asdu(c_ts_ta_1, 1, Obj)),
    ?assertMatch(#asdu{type = c_ts_ta_1, cot = act_con, negative = false,
                       objects = [#object{value = 16#AA55}]},
                 recv_asdu(S)).

test_command_unknown_coa(Config) ->
    S = active(Config),
    Time = iec60870_cp56:from_timestamp(erlang:system_time(millisecond)),
    Obj = iec60870_asdu:test_command(16#AA55, Time),
    send_i(S, 0, 0, cmd_asdu(c_ts_ta_1, 99, Obj)),
    ?assertMatch(#asdu{type = c_ts_ta_1, cot = act_con, negative = true},
                 recv_asdu(S)).

%%%===================================================================
%%% End of initialization (M_EI_NA_1) — connects by hand, not via active/1,
%%% since that helper already relies on / drains this frame.
%%%===================================================================

end_of_init_on_connect(Config) ->
    S = connect(Config),
    ok = do_startdt(S),
    ?assertMatch(#asdu{type = m_ei_na_1, cot = initialized,
                       objects = [#object{ioa = 0, value = 0,
                                          qualifier = #{local_change := false}}]},
                 recv_asdu(S)).

end_of_init_disabled(Config) ->
    S = connect(Config),
    ok = do_startdt(S),
    ok = expect_no_data(S, 300).

%%%===================================================================
%%% Background scan (update/3 with cot => background)
%%%===================================================================

background_scan_always_sent(Config) ->
    Server = ?config(server, Config),
    S = active(Config),
    ok = iec60870_server:update(Server, {1, 100},
           #{type => m_sp_na_1, value => true, cot => background}),
    ?assertMatch(#asdu{type = m_sp_na_1, cot = background,
                       objects = [#object{ioa = 100, value = true}]},
                 recv_asdu(S)),
    %% unlike a plain spontaneous update, an unchanged value is sent again.
    ok = iec60870_server:update(Server, {1, 100},
           #{type => m_sp_na_1, value => true, cot => background}),
    ?assertMatch(#asdu{cot = background}, recv_asdu(S)).

%%%===================================================================
%%% Parameter of measured value / activation (P_ME_*/P_AC)
%%%===================================================================

parameter_set_ok(Config) ->
    S = active(Config),
    Obj = iec60870_asdu:parameter_scaled(100, -50, low_limit),
    send_i(S, 0, 0, cmd_asdu(p_me_nb_1, 1, Obj)),
    ?assertMatch({set_parameter, 1, 100, -50, #{kind := low_limit}}, recv_cb()),
    ?assertMatch(#asdu{type = p_me_nb_1, cot = act_con, negative = false},
                 recv_asdu(S)),
    ?assertMatch(#asdu{type = p_me_nb_1, cot = act_term, negative = false},
                 recv_asdu(S)).

parameter_set_rejected(Config) ->
    S = active(Config),
    Obj = iec60870_asdu:parameter_scaled(8001, -50, low_limit),
    send_i(S, 0, 0, cmd_asdu(p_me_nb_1, 1, Obj)),
    ?assertMatch({set_parameter, 8001}, recv_cb()),
    ?assertMatch(#asdu{type = p_me_nb_1, cot = unknown_ioa, negative = true},
                 recv_asdu(S)),
    ok = expect_no_data(S, 300).

parameter_set_no_callback(Config) ->
    S = active(Config),
    Obj = iec60870_asdu:parameter_scaled(100, -50, low_limit),
    send_i(S, 0, 0, cmd_asdu(p_me_nb_1, 1, Obj)),
    ?assertMatch(#asdu{type = p_me_nb_1, cot = act_con, negative = true},
                 recv_asdu(S)),
    ok = expect_no_data(S, 300).

parameter_activate_ok(Config) ->
    S = active(Config),
    Obj = iec60870_asdu:parameter_activation(100, act_deact_parameter),
    send_i(S, 0, 0, cmd_asdu(p_ac_na_1, 1, Obj)),
    ?assertMatch({activate_parameter, 1, 100, act_deact_parameter}, recv_cb()),
    ?assertMatch(#asdu{type = p_ac_na_1, cot = act_con, negative = false},
                 recv_asdu(S)),
    ?assertMatch(#asdu{type = p_ac_na_1, cot = act_term, negative = false},
                 recv_asdu(S)).

%%%===================================================================
%%% Client helpers
%%%===================================================================

connect(Config) ->
    {ok, S} = gen_tcp:connect({127, 0, 0, 1}, ?config(port, Config),
                              [binary, {active, false}, {packet, 0}], 1000),
    S.

%% Every server config in this suite leaves `coi' at its library default
%% (enabled), so activation always delivers one automatic end-of-init ASDU
%% first (see end_of_init_on_connect/1 and end_of_init_disabled/1, which
%% connect by hand instead since they care about that frame / its absence).
active(Config) ->
    S = connect(Config),
    ok = do_startdt(S),
    ?assertMatch(#asdu{type = m_ei_na_1, cot = initialized}, recv_asdu(S)),
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

%% Read dump ASDUs until the C_CI act_term arrives.
recv_counter_dump(S, Acc) ->
    case recv_asdu(S) of
        #asdu{type = c_ci_na_1, cot = act_term} = Term ->
            {lists:reverse(Acc), Term};
        Asdu ->
            recv_counter_dump(S, [Asdu | Acc])
    end.

dump_points(Asdus) ->
    lists:sort([{O#object.ioa, O#object.value}
                || A <- Asdus, O <- A#asdu.objects]).

expect_no_data(S, Timeout) ->
    case gen_tcp:recv(S, 0, Timeout) of
        {error, timeout} -> ok;
        {ok, Data} -> ct:fail({unexpected_data, Data})
    end.

%% The callback module relays its `select/2' / `execute/2' / `clock_sync/3'
%% calls here as `{cb, Msg}' (see with_callback/1 and relay/2 above).
recv_cb() ->
    receive
        {cb, Msg} -> Msg
    after 2000 ->
        ct:fail(cb_timeout)
    end.

expect_no_cb(Timeout) ->
    receive
        {cb, Msg} -> ct:fail({unexpected_cb, Msg})
    after Timeout ->
        ok
    end.

c_ic(Coa, Qoi) ->
    iec60870_asdu:encode(
      #asdu{type = c_ic_na_1, cot = act, coa = Coa,
            objects = [#object{ioa = 0, value = Qoi}]}).

c_ci(Coa, Rqt, Freeze) ->
    iec60870_asdu:encode(
      #asdu{type = c_ci_na_1, cot = act, coa = Coa,
            objects = [#object{ioa = 0, value = #{request => Rqt, freeze => Freeze}}]}).

c_rd(Coa, Ioa) ->
    iec60870_asdu:encode(
      #asdu{type = c_rd_na_1, cot = request, coa = Coa, objects = [#object{ioa = Ioa}]}).

cmd_asdu(Type, Coa, Obj) ->
    iec60870_asdu:encode(#asdu{type = Type, cot = act, coa = Coa, objects = [Obj]}).
