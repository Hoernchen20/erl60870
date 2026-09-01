-module(iec60870_dm_ets_tests).

-include_lib("eunit/include/eunit.hrl").

%%%===================================================================
%%% write / read
%%%===================================================================

write_reports_change_test() ->
    S = new(),
    P0 = point(m_sp_na_1, false),
    ?assertMatch({ok, _, true}, iec60870_dm_ets:write(S, 1, 100, P0)),
    %% same value -> not a change
    ?assertMatch({ok, _, false}, iec60870_dm_ets:write(S, 1, 100, point(m_sp_na_1, false))),
    %% new value -> change
    ?assertMatch({ok, _, true}, iec60870_dm_ets:write(S, 1, 100, point(m_sp_na_1, true))),
    %% new quality -> change
    P2 = (point(m_sp_na_1, true))#{quality => [invalid]},
    ?assertMatch({ok, _, true}, iec60870_dm_ets:write(S, 1, 100, P2)),
    ok = iec60870_dm_ets:terminate(S).

read_hit_and_miss_test() ->
    S = new(),
    ?assertEqual(not_found, iec60870_dm_ets:read(S, 1, 1)),
    {ok, _, _} = iec60870_dm_ets:write(S, 1, 1, point(m_me_nc_1, 3.5)),
    ?assertMatch({ok, #{type := m_me_nc_1, value := 3.5}}, iec60870_dm_ets:read(S, 1, 1)),
    ok = iec60870_dm_ets:terminate(S).

%%%===================================================================
%%% fold / coas
%%%===================================================================

fold_station_vs_group_test() ->
    S = new(),
    put_point(S, 1, 10, m_sp_na_1, true, 1),
    put_point(S, 1, 11, m_sp_na_1, false, 2),
    put_point(S, 1, 12, m_sp_na_1, true, undefined),
    ?assertEqual([10, 11, 12], fold_ioas(S, 1, station)),
    ?assertEqual([10], fold_ioas(S, 1, 1)),
    ?assertEqual([11], fold_ioas(S, 1, 2)),
    ok = iec60870_dm_ets:terminate(S).

fold_skips_non_interrogable_test() ->
    S = new(),
    put_point(S, 1, 10, m_sp_na_1, true, undefined),
    put_point(S, 1, 11, m_it_na_1, 42, undefined),
    ?assertEqual([10], fold_ioas(S, 1, station)),
    ok = iec60870_dm_ets:terminate(S).

fold_is_coa_scoped_test() ->
    S = new(),
    put_point(S, 1, 10, m_sp_na_1, true, undefined),
    put_point(S, 2, 20, m_sp_na_1, true, undefined),
    ?assertEqual([10], fold_ioas(S, 1, station)),
    ?assertEqual([20], fold_ioas(S, 2, station)),
    ?assertEqual([1, 2], iec60870_dm_ets:coas(S)),
    ok = iec60870_dm_ets:terminate(S).

%%%===================================================================
%%% preload
%%%===================================================================

preload_inline_test() ->
    {ok, S} = iec60870_dm_ets:init(
                #{points => [{{1, 100}, #{type => m_sp_na_1, value => true}},
                             {{1, 101}, #{type => m_me_nc_1, value => 1.25}}]}),
    ?assertMatch({ok, #{value := true}}, iec60870_dm_ets:read(S, 1, 100)),
    ?assertMatch({ok, #{value := 1.25}}, iec60870_dm_ets:read(S, 1, 101)),
    ok = iec60870_dm_ets:terminate(S).

%%%===================================================================
%%% helpers
%%%===================================================================

new() ->
    {ok, S} = iec60870_dm_ets:init(#{}),
    S.

point(Type, Value) ->
    iec60870_point:spec_to_point(#{type => Type, value => Value}).

put_point(S, Coa, Ioa, Type, Value, Group) ->
    P = iec60870_point:spec_to_point(#{type => Type, value => Value, group => Group}),
    {ok, _, _} = iec60870_dm_ets:write(S, Coa, Ioa, P).

fold_ioas(S, Coa, Group) ->
    lists:sort(iec60870_dm_ets:fold(S, Coa, Group,
                                    fun(Ioa, _P, Acc) -> [Ioa | Acc] end, [])).
