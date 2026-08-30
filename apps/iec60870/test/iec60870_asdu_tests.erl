-module(iec60870_asdu_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("iec60870/include/iec60870_asdu.hrl").

%%%===================================================================
%%% Spec byte vectors (IEC 60870-5-101 section 7, 104 default field
%%% widths unless noted). Each is checked both ways.
%%%===================================================================

%% M_SP_NA_1, one point, response to station interrogation.
vec_single_point_test() ->
    Asdu = #asdu{type = m_sp_na_1, cot = interrogated_station, coa = 1,
                 objects = [#object{ioa = 1, value = true, quality = []}]},
    Bin = <<1, 1, 20, 0, 1, 0, 1, 0, 0, 1>>,
    check(Asdu, Bin, #{}).

%% M_SP_NA_1, SQ=1 sequence of three consecutive points, spontaneous.
vec_single_point_sequence_test() ->
    Asdu = #asdu{type = m_sp_na_1, cot = spontaneous, coa = 1, sequence = true,
                 objects = [#object{ioa = 100, value = true, quality = []},
                            #object{ioa = 101, value = false, quality = []},
                            #object{ioa = 102, value = true, quality = []}]},
    Bin = <<1, 16#83, 3, 0, 1, 0, 100, 0, 0, 1, 0, 1>>,
    check(Asdu, Bin, #{}).

%% C_SC_NA_1, single command execute, IOA 5000.
vec_single_command_test() ->
    Asdu = #asdu{type = c_sc_na_1, cot = act, coa = 1,
                 objects = [#object{ioa = 5000, value = true,
                                    qualifier = #{select => false, qu => 0}}]},
    Bin = <<45, 1, 6, 0, 1, 0, 16#88, 16#13, 0, 1>>,
    check(Asdu, Bin, #{}).

%% M_SP_NA_1 with 101-style 1-octet COT / COA / IOA.
vec_narrow_fields_test() ->
    Asdu = #asdu{type = m_sp_na_1, cot = spontaneous, coa = 1, orig_addr = 0,
                 objects = [#object{ioa = 1, value = true, quality = []}]},
    Bin = <<1, 1, 3, 1, 1, 1>>,
    check(Asdu, Bin, #{cot_size => 1, coa_size => 1, ioa_size => 1}).

%% C_CS_NA_1 clock synchronisation.
vec_clock_sync_test() ->
    T = #cp56{milliseconds = 34567, minute = 52, hour = 20, day_of_month = 17,
              day_of_week = 6, month = 6, year = 6},
    Asdu = #asdu{type = c_cs_na_1, cot = act, coa = 1,
                 objects = [#object{ioa = 0, timestamp = T}]},
    Bin = <<103, 1, 6, 0, 1, 0, 0, 0, 0, 16#07, 16#87, 16#34, 16#14, 16#D1, 16#06, 16#06>>,
    check(Asdu, Bin, #{}).

%% Test + negative bits, originator address, 2-octet COA.
vec_test_negative_bits_test() ->
    Asdu = #asdu{type = m_dp_na_1, cot = act_con, negative = true, test = true,
                 coa = 5, orig_addr = 7,
                 objects = [#object{ioa = 1, value = 2, quality = []}]},
    Bin = <<3, 1, 16#C7, 7, 5, 0, 1, 0, 0, 2>>,
    check(Asdu, Bin, #{}).

%%%===================================================================
%%% VSQ
%%%===================================================================

vsq_sq_and_count_test() ->
    A0 = #asdu{type = m_sp_na_1, cot = spontaneous, coa = 1,
               objects = [#object{ioa = N, value = true, quality = []}
                          || N <- lists:seq(1, 5)]},
    <<_TypeId, SQ:1, Count:7, _/binary>> = iec60870_asdu:encode(A0),
    ?assertEqual({0, 5}, {SQ, Count}),
    A1 = A0#asdu{sequence = true},
    <<_, SQ1:1, Count1:7, _/binary>> = iec60870_asdu:encode(A1),
    ?assertEqual({1, 5}, {SQ1, Count1}).

%%%===================================================================
%%% decode error handling
%%%===================================================================

decode_truncated_test() ->
    ?assertEqual({error, truncated}, iec60870_asdu:decode(<<1, 1, 20, 0, 1, 0, 1>>)),
    ?assertEqual({error, truncated}, iec60870_asdu:decode(<<>>)),
    ?assertEqual({error, truncated}, iec60870_asdu:decode(<<1>>)).

decode_truncated_timestamp_test() ->
    %% M_SP_TB_1 needs SIQ + 7 time octets; give SIQ + 3.
    ?assertEqual({error, truncated},
                 iec60870_asdu:decode(<<30, 1, 3, 0, 1, 0, 1, 0, 0, 1, 9, 9, 9>>)).

decode_unsupported_type_test() ->
    ?assertEqual({error, {unsupported_type, 99}},
                 iec60870_asdu:decode(<<99, 1, 6, 0, 1, 0, 0, 0, 0>>)).

decode_trailing_bytes_are_returned_test() ->
    Bin = <<1, 1, 20, 0, 1, 0, 1, 0, 0, 1, 16#FF, 16#EE>>,
    {ok, #asdu{type = m_sp_na_1}, Rest} = iec60870_asdu:decode(Bin),
    ?assertEqual(<<16#FF, 16#EE>>, Rest).

decode_zero_objects_test() ->
    {ok, Asdu, <<>>} = iec60870_asdu:decode(<<1, 0, 3, 0, 1, 0>>),
    ?assertEqual([], Asdu#asdu.objects).

%%%===================================================================
%%% encode error handling
%%%===================================================================

encode_too_many_objects_test() ->
    Objs = [#object{ioa = N, value = true, quality = []} || N <- lists:seq(1, 128)],
    Asdu = #asdu{type = m_sp_na_1, cot = spontaneous, coa = 1, objects = Objs},
    ?assertError({too_many_objects, 128}, iec60870_asdu:encode(Asdu)).

encode_non_contiguous_sequence_test() ->
    Asdu = #asdu{type = m_sp_na_1, cot = spontaneous, coa = 1, sequence = true,
                 objects = [#object{ioa = 10, value = true, quality = []},
                            #object{ioa = 12, value = true, quality = []}]},
    ?assertError({non_contiguous_sequence, 11, 12}, iec60870_asdu:encode(Asdu)).

encode_coa_out_of_range_test() ->
    Asdu = #asdu{type = m_sp_na_1, cot = spontaneous, coa = 70000,
                 objects = [#object{ioa = 1, value = true, quality = []}]},
    ?assertError({value_out_of_range, 70000, 2}, iec60870_asdu:encode(Asdu)).

%%%===================================================================
%%% builders
%%%===================================================================

builder_single_point_test() ->
    ?assertEqual(#object{ioa = 5, value = true, quality = [invalid]},
                 iec60870_asdu:single_point(5, true, #{quality => [invalid]})),
    ?assertEqual(#object{ioa = 5, value = false},
                 iec60870_asdu:single_point(5, 0)).

builder_single_command_test() ->
    Obj = iec60870_asdu:single_command(5000, on, #{select => true, qu => 2}),
    ?assertEqual(#object{ioa = 5000, value = true,
                         qualifier = #{select => true, qu => 2}}, Obj).

builder_clock_sync_roundtrips_test() ->
    T = #cp56{milliseconds = 500, minute = 1, hour = 2, day_of_month = 3,
              month = 4, year = 25},
    Asdu = #asdu{type = c_cs_na_1, cot = act, coa = 1,
                 objects = [iec60870_asdu:clock_sync(T)]},
    {ok, Decoded, <<>>} = iec60870_asdu:decode(iec60870_asdu:encode(Asdu)),
    ?assertEqual(Asdu, Decoded).

%%%===================================================================
%%% helpers
%%%===================================================================

check(Asdu, Bin, Opts) ->
    ?assertEqual(Bin, iec60870_asdu:encode(Asdu, Opts)),
    ?assertEqual({ok, Asdu, <<>>}, iec60870_asdu:decode(Bin, Opts)).
