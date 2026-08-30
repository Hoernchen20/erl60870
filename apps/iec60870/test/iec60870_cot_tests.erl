-module(iec60870_cot_tests).

-include_lib("eunit/include/eunit.hrl").

named_codes_test() ->
    ?assertEqual(3, iec60870_cot:to_int(spontaneous)),
    ?assertEqual(6, iec60870_cot:to_int(act)),
    ?assertEqual(7, iec60870_cot:to_int(act_con)),
    ?assertEqual(10, iec60870_cot:to_int(act_term)),
    ?assertEqual(20, iec60870_cot:to_int(interrogated_station)),
    ?assertEqual(spontaneous, iec60870_cot:from_int(3)),
    ?assertEqual(act_term, iec60870_cot:from_int(10)).

group_family_test() ->
    ?assertEqual(21, iec60870_cot:to_int({interrogated_group, 1})),
    ?assertEqual(36, iec60870_cot:to_int({interrogated_group, 16})),
    ?assertEqual({interrogated_group, 1}, iec60870_cot:from_int(21)),
    ?assertEqual({interrogated_group, 16}, iec60870_cot:from_int(36)),
    ?assertEqual(38, iec60870_cot:to_int({interrogated_counter_group, 1})),
    ?assertEqual({interrogated_counter_group, 4}, iec60870_cot:from_int(41)).

unknown_causes_test() ->
    ?assertEqual(44, iec60870_cot:to_int(unknown_type_id)),
    ?assertEqual(47, iec60870_cot:to_int(unknown_ioa)),
    ?assertEqual(unknown_coa, iec60870_cot:from_int(46)).

raw_passthrough_test() ->
    ?assertEqual(0, iec60870_cot:to_int(0)),
    ?assertEqual(63, iec60870_cot:to_int(63)),
    ?assertEqual(14, iec60870_cot:from_int(14)),
    ?assertEqual(63, iec60870_cot:from_int(63)).

roundtrip_all_test() ->
    [?assertEqual(N, iec60870_cot:to_int(iec60870_cot:from_int(N)))
     || N <- lists:seq(0, 63)].
