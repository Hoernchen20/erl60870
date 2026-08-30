-module(iec60870_type_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("iec60870/include/iec60870_asdu.hrl").

%%%===================================================================
%%% Type identification map
%%%===================================================================

id_map_roundtrip_test() ->
    Names = [m_sp_na_1, m_sp_tb_1, m_dp_na_1, m_dp_tb_1, m_st_na_1,
             m_me_na_1, m_me_nb_1, m_me_nc_1, m_me_td_1, m_me_te_1, m_me_tf_1,
             m_it_na_1, m_it_tb_1, m_ei_na_1,
             c_sc_na_1, c_dc_na_1, c_rc_na_1, c_se_na_1, c_se_nb_1, c_se_nc_1,
             c_ic_na_1, c_ci_na_1, c_rd_na_1, c_cs_na_1, c_ts_ta_1],
    [?assertEqual(N, iec60870_type:id_to_name(iec60870_type:name_to_id(N)))
     || N <- Names].

id_map_known_values_test() ->
    ?assertEqual(1, iec60870_type:name_to_id(m_sp_na_1)),
    ?assertEqual(30, iec60870_type:name_to_id(m_sp_tb_1)),
    ?assertEqual(13, iec60870_type:name_to_id(m_me_nc_1)),
    ?assertEqual(45, iec60870_type:name_to_id(c_sc_na_1)),
    ?assertEqual(100, iec60870_type:name_to_id(c_ic_na_1)),
    ?assertEqual(103, iec60870_type:name_to_id(c_cs_na_1)),
    ?assertEqual(107, iec60870_type:name_to_id(c_ts_ta_1)).

id_map_unknown_passthrough_test() ->
    ?assertEqual(200, iec60870_type:id_to_name(200)),
    ?assertEqual(200, iec60870_type:name_to_id(200)).

%%%===================================================================
%%% Single point (SIQ) — bit 0 value, bits 4-7 quality, no overflow
%%%===================================================================

siq_encode_test() ->
    ?assertEqual(<<16#01>>, enc(m_sp_na_1, #object{value = true, quality = []})),
    ?assertEqual(<<16#00>>, enc(m_sp_na_1, #object{value = false, quality = []})),
    ?assertEqual(<<16#81>>, enc(m_sp_na_1, #object{value = true, quality = [invalid]})),
    ?assertEqual(<<16#51>>, enc(m_sp_na_1, #object{value = true,
                                                  quality = [blocked, not_topical]})).

siq_decode_test() ->
    ?assertEqual(#object{ioa = 7, value = true, quality = []},
                 dec(m_sp_na_1, 7, <<16#01>>)),
    ?assertEqual(#object{ioa = 7, value = false, quality = [substituted, invalid]},
                 dec(m_sp_na_1, 7, <<16#A0>>)).

siq_ignores_overflow_bit_test() ->
    %% bit 0 is SPI, so a payload of 16#01 is "on", never "overflow".
    #object{value = V, quality = Q} = dec(m_sp_na_1, 1, <<16#01>>),
    ?assertEqual({true, []}, {V, Q}).

%%%===================================================================
%%% Double point (DIQ) — bits 0-1 value
%%%===================================================================

diq_test() ->
    [?assertEqual(<<V>>, enc(m_dp_na_1, #object{value = V, quality = []}))
     || V <- [0, 1, 2, 3]],
    ?assertEqual(<<16#82>>, enc(m_dp_na_1, #object{value = 2, quality = [invalid]})),
    ?assertEqual(#object{ioa = 0, value = 3, quality = [not_topical]},
                 dec(m_dp_na_1, 0, <<16#43>>)).

%%%===================================================================
%%% Step position (VTI) — 7-bit two's complement + transient bit
%%%===================================================================

vti_test() ->
    ?assertEqual(<<16#00, 16#00>>,
                 enc(m_st_na_1, #object{value = 0, quality = [],
                                        qualifier = #{transient => false}})),
    ?assertEqual(<<16#3F, 16#00>>,
                 enc(m_st_na_1, #object{value = 63, quality = [],
                                        qualifier = #{transient => false}})),
    %% -64 -> 7-bit two's complement 16#40, transient set -> 16#C0
    ?assertEqual(<<16#C0, 16#00>>,
                 enc(m_st_na_1, #object{value = -64, quality = [],
                                        qualifier = #{transient => true}})),
    ?assertEqual(<<16#7F, 16#00>>,
                 enc(m_st_na_1, #object{value = -1, quality = [],
                                        qualifier = #{transient => false}})).

vti_roundtrip_test() ->
    [begin
         Obj = #object{ioa = 3, value = P, quality = [invalid],
                       qualifier = #{transient => T}},
         ?assertEqual(Obj, dec(m_st_na_1, 3, enc(m_st_na_1, Obj)))
     end || P <- [-64, -1, 0, 1, 63], T <- [true, false]].

%%%===================================================================
%%% Measured values — little-endian, signed for NVA/SVA, IEEE754 for R32
%%%===================================================================

nva_endianness_test() ->
    ?assertEqual(<<16#D2, 16#04, 16#00>>,
                 enc(m_me_na_1, #object{value = 1234, quality = []})),
    ?assertEqual(<<16#00, 16#80, 16#00>>,
                 enc(m_me_na_1, #object{value = -32768, quality = []})),
    ?assertEqual(#object{ioa = 1, value = -1, quality = []},
                 dec(m_me_na_1, 1, <<16#FF, 16#FF, 16#00>>)).

r32_roundtrip_test() ->
    [begin
         Obj = #object{ioa = 9, value = F, quality = [overflow]},
         Dec = dec(m_me_nc_1, 9, enc(m_me_nc_1, Obj)),
         ?assertEqual(Obj, Dec)
     end || F <- [0.0, 1.0, -1.0, 3.5, -0.25, 100000.0]].

r32_little_endian_test() ->
    %% 1.0f32 = 0x3F800000, little-endian on the wire.
    ?assertEqual(<<16#00, 16#00, 16#80, 16#3F, 16#00>>,
                 enc(m_me_nc_1, #object{value = 1.0, quality = []})).

%%%===================================================================
%%% Integrated totals (BCR)
%%%===================================================================

bcr_test() ->
    Obj = #object{ioa = 2, value = -5,
                  qualifier = #{sequence => 9, carry => true, adjusted => false}},
    Bin = enc(m_it_na_1, Obj),
    ?assertEqual(5, byte_size(Bin)),
    <<Val:32/little-signed, IV:1, CA:1, CY:1, Seq:5>> = Bin,
    ?assertEqual({-5, 0, 0, 1, 9}, {Val, IV, CA, CY, Seq}),
    ?assertEqual(Obj, dec(m_it_na_1, 2, Bin)).

bcr_invalid_flag_test() ->
    Obj = #object{ioa = 2, value = 42, quality = [invalid],
                  qualifier = #{sequence => 0, carry => false, adjusted => true}},
    ?assertEqual(Obj, dec(m_it_na_1, 2, enc(m_it_na_1, Obj))).

%%%===================================================================
%%% Commands
%%%===================================================================

sco_test() ->
    %% S/E=0 (execute), QU=0, SCS=1
    ?assertEqual(<<16#01>>,
                 enc(c_sc_na_1, #object{value = true,
                                        qualifier = #{select => false, qu => 0}})),
    %% S/E=1 (select), QU=0, SCS=0
    ?assertEqual(<<16#80>>,
                 enc(c_sc_na_1, #object{value = false,
                                        qualifier = #{select => true, qu => 0}})),
    %% QU=1 occupies bits 2-6 -> 16#04
    ?assertEqual(<<16#05>>,
                 enc(c_sc_na_1, #object{value = true,
                                        qualifier = #{select => false, qu => 1}})),
    ?assertEqual(#object{ioa = 5, value = true,
                         qualifier = #{select => true, qu => 3}},
                 dec(c_sc_na_1, 5, <<16#8D>>)).

dco_test() ->
    ?assertEqual(<<16#82>>,
                 enc(c_dc_na_1, #object{value = 2,
                                        qualifier = #{select => true, qu => 0}})),
    ?assertEqual(#object{ioa = 0, value = 1, qualifier = #{select => false, qu => 0}},
                 dec(c_dc_na_1, 0, <<16#01>>)).

setpoint_test() ->
    Obj = #object{ioa = 4, value = -100,
                  qualifier = #{select => false, ql => 5}},
    Bin = enc(c_se_nb_1, Obj),
    ?assertEqual(3, byte_size(Bin)),
    ?assertEqual(Obj, dec(c_se_nb_1, 4, Bin)).

%%%===================================================================
%%% System information
%%%===================================================================

interrogation_test() ->
    ?assertEqual(<<20>>, enc(c_ic_na_1, #object{value = 20})),
    ?assertEqual(#object{ioa = 0, value = 21}, dec(c_ic_na_1, 0, <<21>>)).

counter_interrogation_test() ->
    Obj = #object{ioa = 0, value = #{request => 5, freeze => freeze_reset}},
    Bin = enc(c_ci_na_1, Obj),
    ?assertEqual(<<16#85>>, Bin), %% FRZ=2 (bits 7-6), RQT=5 (bits 5-0)
    ?assertEqual(Obj, dec(c_ci_na_1, 0, Bin)).

read_command_test() ->
    ?assertEqual(<<>>, enc(c_rd_na_1, #object{ioa = 99})),
    ?assertEqual({#object{ioa = 99}, <<1, 2>>},
                 iec60870_type:decode_payload(c_rd_na_1, 99, <<1, 2>>)).

clock_sync_test() ->
    T = #cp56{milliseconds = 1000, minute = 30, hour = 12, day_of_month = 1,
              month = 1, year = 24},
    Obj = #object{ioa = 0, timestamp = T},
    ?assertEqual(Obj, dec(c_cs_na_1, 0, enc(c_cs_na_1, Obj))).

test_command_test() ->
    T = #cp56{milliseconds = 0, minute = 0, hour = 0, day_of_month = 1,
              month = 1, year = 0},
    Obj = #object{ioa = 0, value = 16#5AA5, timestamp = T},
    Bin = enc(c_ts_ta_1, Obj),
    ?assertMatch(<<16#A5, 16#5A, _:7/binary>>, Bin), %% TSC little-endian
    ?assertEqual(Obj, dec(c_ts_ta_1, 0, Bin)).

end_of_init_test() ->
    Obj = #object{ioa = 0, value = 2, qualifier = #{local_change => true}},
    ?assertEqual(<<16#82>>, enc(m_ei_na_1, Obj)),
    ?assertEqual(Obj, dec(m_ei_na_1, 0, <<16#82>>)).

%%%===================================================================
%%% Timestamped monitored variants keep the 7-octet tail
%%%===================================================================

timestamped_lengths_test() ->
    T = #cp56{milliseconds = 0, minute = 0, hour = 0, day_of_month = 1,
              month = 1, year = 0},
    ?assertEqual(8, byte_size(enc(m_sp_tb_1, #object{value = true, quality = [],
                                                    timestamp = T}))),
    ?assertEqual(8, byte_size(enc(m_dp_tb_1, #object{value = 1, quality = [],
                                                    timestamp = T}))),
    ?assertEqual(10, byte_size(enc(m_me_td_1, #object{value = 0, quality = [],
                                                     timestamp = T}))),
    ?assertEqual(12, byte_size(enc(m_me_tf_1, #object{value = 0.0, quality = [],
                                                     timestamp = T}))),
    ?assertEqual(12, byte_size(enc(m_it_tb_1, #object{value = 0,
                                                     qualifier = #{sequence => 0},
                                                     timestamp = T}))).

%%%===================================================================
%%% helpers
%%%===================================================================

enc(Type, Obj) -> iec60870_type:encode_payload(Type, Obj).

dec(Type, Ioa, Bin) ->
    {Obj, <<>>} = iec60870_type:decode_payload(Type, Ioa, Bin),
    Obj.
