-module(iec60870_point_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("iec60870/include/iec60870_asdu.hrl").

%%%===================================================================
%%% spec_to_point
%%%===================================================================

spec_defaults_test() ->
    ?assertEqual(#{type => m_sp_na_1, value => true, quality => [],
                   ts => undefined, group => undefined},
                 iec60870_point:spec_to_point(#{type => m_sp_na_1, value => true})).

spec_sorts_quality_test() ->
    P = iec60870_point:spec_to_point(
          #{type => m_me_nc_1, value => 1.0, quality => [invalid, blocked]}),
    ?assertEqual([blocked, invalid], maps:get(quality, P)).

spec_step_position_default_qualifier_test() ->
    P = iec60870_point:spec_to_point(#{type => m_st_na_1, value => 3, transient => true}),
    ?assertEqual(#{transient => true}, maps:get(qualifier, P)).

spec_explicit_qualifier_wins_test() ->
    P = iec60870_point:spec_to_point(
          #{type => m_st_na_1, value => 3, transient => true,
            qualifier => #{transient => false}}),
    ?assertEqual(#{transient => false}, maps:get(qualifier, P)).

%%%===================================================================
%%% to_object
%%%===================================================================

to_object_plain_test() ->
    P = iec60870_point:spec_to_point(#{type => m_sp_na_1, value => true,
                                       quality => [invalid]}),
    ?assertEqual(#object{ioa = 7, value = true, quality = [invalid]},
                 iec60870_point:to_object(m_sp_na_1, 7, P)).

to_object_timestamped_from_ts_test() ->
    Ts = 1_700_000_000_123,
    P = iec60870_point:spec_to_point(#{type => m_sp_tb_1, value => false, ts => Ts}),
    Obj = iec60870_point:to_object(m_sp_tb_1, 9, P),
    ?assertMatch(#object{ioa = 9, value = false, timestamp = #cp56{}}, Obj),
    ?assertEqual(Ts, iec60870_cp56:to_timestamp(Obj#object.timestamp)).

to_object_timestamped_without_ts_uses_now_test() ->
    Before = erlang:system_time(millisecond),
    P = iec60870_point:spec_to_point(#{type => m_me_tf_1, value => 1.5}),
    #object{timestamp = T} = iec60870_point:to_object(m_me_tf_1, 1, P),
    After = erlang:system_time(millisecond),
    Got = iec60870_cp56:to_timestamp(T),
    ?assert(Got >= Before - 1000 andalso Got =< After + 1000).

to_object_step_position_carries_transient_test() ->
    P = iec60870_point:spec_to_point(#{type => m_st_na_1, value => -5, transient => true}),
    ?assertEqual(#object{ioa = 2, value = -5, quality = [],
                         qualifier = #{transient => true}},
                 iec60870_point:to_object(m_st_na_1, 2, P)).

%%%===================================================================
%%% predicates
%%%===================================================================

is_timestamped_test() ->
    ?assert(iec60870_point:is_timestamped(m_me_td_1)),
    ?assertNot(iec60870_point:is_timestamped(m_me_na_1)).

interrogable_excludes_counters_and_commands_test() ->
    ?assert(iec60870_point:interrogable(m_sp_na_1)),
    ?assert(iec60870_point:interrogable(m_me_tf_1)),
    ?assertNot(iec60870_point:interrogable(m_it_na_1)),
    ?assertNot(iec60870_point:interrogable(c_sc_na_1)).

is_counter_test() ->
    ?assert(iec60870_point:is_counter(m_it_na_1)),
    ?assert(iec60870_point:is_counter(m_it_tb_1)),
    ?assertNot(iec60870_point:is_counter(m_sp_na_1)).
