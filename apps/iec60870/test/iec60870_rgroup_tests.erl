%%% @doc eunit for the pure peer-address matcher used by `redundancy.mode =>
%%% multiple' ({@link iec60870_rgroup:match/3}).
-module(iec60870_rgroup_tests).

-include_lib("eunit/include/eunit.hrl").

-define(A, #{name => scada_a, match => [{ip, {10, 0, 0, 0}, 24}]}).
-define(B, #{name => scada_b, match => [{ip, {10, 1, 0, 5}, 32}]}).

no_groups_returns_default_test() ->
    ?assertEqual(other, iec60870_rgroup:match({192, 168, 1, 1}, [], other)).

cidr_24_match_test() ->
    ?assertEqual(scada_a, iec60870_rgroup:match({10, 0, 0, 7}, [?A, ?B], default)),
    ?assertEqual(scada_a, iec60870_rgroup:match({10, 0, 0, 255}, [?A, ?B], default)).

cidr_24_non_match_test() ->
    ?assertEqual(default, iec60870_rgroup:match({10, 0, 1, 7}, [?A, ?B], default)).

host_route_32_test() ->
    ?assertEqual(scada_b, iec60870_rgroup:match({10, 1, 0, 5}, [?A, ?B], default)),
    ?assertEqual(default, iec60870_rgroup:match({10, 1, 0, 6}, [?A, ?B], default)).

first_match_wins_test() ->
    Overlap = [#{name => wide, match => [{ip, {10, 0, 0, 0}, 8}]},
               #{name => narrow, match => [{ip, {10, 0, 0, 0}, 24}]}],
    ?assertEqual(wide, iec60870_rgroup:match({10, 0, 0, 1}, Overlap, default)).

multiple_specs_per_group_test() ->
    G = [#{name => g, match => [{ip, {10, 0, 0, 0}, 24}, {ip, {172, 16, 0, 0}, 16}]}],
    ?assertEqual(g, iec60870_rgroup:match({172, 16, 42, 9}, G, default)),
    ?assertEqual(default, iec60870_rgroup:match({172, 17, 0, 1}, G, default)).

prefix_0_matches_everything_test() ->
    G = [#{name => any, match => [{ip, {0, 0, 0, 0}, 0}]}],
    ?assertEqual(any, iec60870_rgroup:match({8, 8, 8, 8}, G, default)).

ipv6_match_test() ->
    G = [#{name => v6, match => [{ip, {16#fd00, 0, 0, 0, 0, 0, 0, 0}, 16}]}],
    ?assertEqual(v6, iec60870_rgroup:match({16#fd00, 16#abcd, 0, 0, 0, 0, 0, 1}, G, default)),
    ?assertEqual(default, iec60870_rgroup:match({16#fe80, 0, 0, 0, 0, 0, 0, 1}, G, default)).

family_mismatch_is_no_match_test() ->
    G = [#{name => v4, match => [{ip, {10, 0, 0, 0}, 8}]}],
    ?assertEqual(default,
                 iec60870_rgroup:match({16#fd00, 0, 0, 0, 0, 0, 0, 1}, G, default)).
