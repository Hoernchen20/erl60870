%%% @doc Unit tests for the pure command helpers (docs/DESIGN.md section 7).
-module(iec60870_command_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("iec60870/include/iec60870_asdu.hrl").

%%%===================================================================
%%% is_command/1
%%%===================================================================

is_command_test_() ->
    Commands = [c_sc_na_1, c_dc_na_1, c_rc_na_1, c_se_na_1, c_se_nb_1, c_se_nc_1],
    [?_assert(iec60870_command:is_command(T)) || T <- Commands] ++
    [?_assertNot(iec60870_command:is_command(T))
     || T <- [m_sp_na_1, c_ic_na_1, c_cs_na_1]].

%%%===================================================================
%%% to_map/1
%%%===================================================================

to_map_single_command_direct_test() ->
    Obj = iec60870_asdu:single_command(5000, true, #{qu => 1}),
    Asdu = #asdu{type = c_sc_na_1, cot = act, coa = 1, orig_addr = 7,
                 test = true, objects = [Obj]},
    ?assertEqual(#{type => c_sc_na_1, coa => 1, ioa => 5000, value => true,
                   select => false, qualifier => #{select => false, qu => 1},
                   orig_addr => 7, test => true},
                 iec60870_command:to_map(Asdu)).

to_map_selects_test() ->
    Obj = iec60870_asdu:double_command(200, 1, #{select => true}),
    Asdu = #asdu{type = c_dc_na_1, cot = act, coa = 1, objects = [Obj]},
    Cmd = iec60870_command:to_map(Asdu),
    ?assertEqual(true, maps:get(select, Cmd)),
    ?assertEqual(1, maps:get(value, Cmd)).

to_map_setpoint_test() ->
    Obj = iec60870_asdu:setpoint_short(300, 3.5, #{ql => 2}),
    Asdu = #asdu{type = c_se_nc_1, cot = act, coa = 1, objects = [Obj]},
    Cmd = iec60870_command:to_map(Asdu),
    ?assertEqual(3.5, maps:get(value, Cmd)),
    ?assertEqual(#{select => false, ql => 2}, maps:get(qualifier, Cmd)).

%%%===================================================================
%%% matches/2
%%%===================================================================

matches_ignores_select_bit_test() ->
    Selected = cmd(c_sc_na_1, 1, 100, true, #{select => true, qu => 0}),
    Operate = cmd(c_sc_na_1, 1, 100, true, #{select => false, qu => 0}),
    ?assert(iec60870_command:matches(Selected, Operate)).

matches_false_on_value_mismatch_test() ->
    Selected = cmd(c_sc_na_1, 1, 100, true, #{select => true, qu => 0}),
    Operate = cmd(c_sc_na_1, 1, 100, false, #{select => false, qu => 0}),
    ?assertNot(iec60870_command:matches(Selected, Operate)).

matches_false_on_ioa_mismatch_test() ->
    Selected = cmd(c_sc_na_1, 1, 100, true, #{select => true, qu => 0}),
    Operate = cmd(c_sc_na_1, 1, 101, true, #{select => false, qu => 0}),
    ?assertNot(iec60870_command:matches(Selected, Operate)).

matches_false_on_qualifier_mismatch_test() ->
    Selected = cmd(c_sc_na_1, 1, 100, true, #{select => true, qu => 0}),
    Operate = cmd(c_sc_na_1, 1, 100, true, #{select => false, qu => 3}),
    ?assertNot(iec60870_command:matches(Selected, Operate)).

%%%===================================================================
%%% mirror/3
%%%===================================================================

mirror_test() ->
    Obj = iec60870_asdu:single_command(5000, true, #{qu => 1}),
    Asdu = #asdu{type = c_sc_na_1, cot = act, coa = 1, orig_addr = 7,
                 test = true, objects = [Obj]},
    Mirrored = iec60870_command:mirror(Asdu, act_con, true),
    ?assertEqual(act_con, Mirrored#asdu.cot),
    ?assertEqual(true, Mirrored#asdu.negative),
    ?assertEqual(1, Mirrored#asdu.coa),
    ?assertEqual(7, Mirrored#asdu.orig_addr),
    ?assertEqual(true, Mirrored#asdu.test),
    ?assertEqual([Obj], Mirrored#asdu.objects).

%%%===================================================================
%%% Helpers
%%%===================================================================

cmd(Type, Coa, Ioa, Value, Qualifier) ->
    #{type => Type, coa => Coa, ioa => Ioa, value => Value,
      select => maps:get(select, Qualifier), qualifier => Qualifier,
      orig_addr => 0, test => false}.
