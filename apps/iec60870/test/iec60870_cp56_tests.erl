-module(iec60870_cp56_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("iec60870/include/iec60870_asdu.hrl").

%% IEC 60870-5-4 section 6.8. Worked example: 2006-06-17 20:52:34.567,
%% Saturday (day of week 6), standard time.
%%   ms of minute = 34*1000 + 567 = 34567 = 16#8707  -> octets 07 87
%%   minute 52, IV=0                                  -> octet  34
%%   hour 20, SU=0                                    -> octet  14
%%   dow 6, dom 17  -> <<6:3, 17:5>> = 16#D1          -> octet  D1
%%   month 6        -> <<0:4, 6:4>>                   -> octet  06
%%   year 6         -> <<0:1, 6:7>>                   -> octet  06
-define(VECTOR_BIN, <<16#07, 16#87, 16#34, 16#14, 16#D1, 16#06, 16#06>>).
-define(VECTOR_REC, #cp56{milliseconds = 34567, minute = 52, hour = 20,
                          day_of_month = 17, day_of_week = 6, month = 6,
                          year = 6, summer_time = false, invalid = false}).

vector_encode_test() ->
    ?assertEqual(?VECTOR_BIN, iec60870_cp56:to_binary(?VECTOR_REC)).

vector_decode_test() ->
    ?assertEqual(?VECTOR_REC, iec60870_cp56:from_binary(?VECTOR_BIN)).

length_test() ->
    ?assertEqual(7, byte_size(iec60870_cp56:to_binary(?VECTOR_REC))).

flag_bits_test() ->
    Base = ?VECTOR_REC,
    Rec = Base#cp56{summer_time = true, invalid = true},
    <<_:16, IV:1, _:1, _:6, SU:1, _:2, _:5, _:24>> = iec60870_cp56:to_binary(Rec),
    ?assertEqual({1, 1}, {IV, SU}),
    ?assertEqual(Rec, iec60870_cp56:from_binary(iec60870_cp56:to_binary(Rec))).

reserved_bits_ignored_on_decode_test() ->
    <<A:16, B, C, D, E, F>> = ?VECTOR_BIN,
    Dirty = <<A:16, (B bor 16#40), (C bor 16#60), D, (E bor 16#F0), (F bor 16#80)>>,
    ?assertEqual(?VECTOR_REC, iec60870_cp56:from_binary(Dirty)).

roundtrip_all_fields_test() ->
    Rec = #cp56{milliseconds = 59999, minute = 59, hour = 23, day_of_month = 31,
                day_of_week = 7, month = 12, year = 99,
                summer_time = true, invalid = true},
    ?assertEqual(Rec, iec60870_cp56:from_binary(iec60870_cp56:to_binary(Rec))).

datetime_roundtrip_test() ->
    DT = {{2023, 3, 14}, {15, 9, 26}},
    Rec = iec60870_cp56:from_datetime(DT),
    ?assertEqual(DT, iec60870_cp56:to_datetime(Rec)),
    ?assertEqual(2, Rec#cp56.day_of_week). %% 2023-03-14 is a Tuesday

timestamp_roundtrip_test() ->
    Millis = 1_700_000_000_123,
    Rec = iec60870_cp56:from_timestamp(Millis),
    ?assertEqual(Millis, iec60870_cp56:to_timestamp(Rec)).
