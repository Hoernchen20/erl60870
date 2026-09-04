-module(iec60870_type).
-moduledoc """
Per-Type-ID dispatch: the atom/integer type map and the codec for one
information element's payload (everything after its information object
address).

Scope is the v1 type set of `docs/DESIGN.md` section 10. Field formats follow
IEC 60870-5-101 section 7.3 and the element definitions of IEC 60870-5-4.
Every payload has a fixed length, so `decode_payload/3` returns the object
together with the bytes it did not consume.

Value representation in `#object{}` (records are the internal form,
decision 5):

- single point: `value` is a `t:boolean/0`
- double point / command: `value` is `0..3` (the raw DPI/DCS/RCS code)
- step position: `value` is the position `-64..63`, `qualifier` is
  `#{transient => boolean()}`
- normalized / scaled: `value` is the raw 16-bit signed integer (normalized
  fraction = value / 32768)
- short float: `value` is a `t:float/0`
- integrated total: `value` is the 32-bit signed counter, `qualifier` is
  `#{sequence => 0..31, carry => boolean(), adjusted => boolean()}`
- commands: `qualifier` carries `#{select => boolean(), qu => 0..31}`
  (single/double/step) or `#{select => boolean(), ql => 0..127}` (set point)
- timestamped variants: `timestamp` is a `#cp56{}`
- parameter of measured value: `value` is the raw i16/float like the matching
  measured-value type, `qualifier` is `#{kind => not_used | threshold_value |
  smoothing_factor | low_limit | high_limit | 0..63, in_operation =>
  boolean(), local_change => boolean()}` (QPM)
- parameter activation: `value` is `not_used | act_deact_parameter |
  act_deact_persistent_cyclic | 0..127` (QPA)
""".

-include_lib("iec60870/include/iec60870_asdu.hrl").

-export([id_to_name/1, name_to_id/1, payload_size/1]).
-export([encode_payload/2, decode_payload/3]).

%%%===================================================================
%%% Type identification map (docs/DESIGN.md section 10)
%%%===================================================================

-spec name_to_id(iec60870_asdu:type_name() | 0..255) -> 0..255.
name_to_id(m_sp_na_1) -> 1;
name_to_id(m_dp_na_1) -> 3;
name_to_id(m_st_na_1) -> 5;
name_to_id(m_me_na_1) -> 9;
name_to_id(m_me_nb_1) -> 11;
name_to_id(m_me_nc_1) -> 13;
name_to_id(m_it_na_1) -> 15;
name_to_id(m_sp_tb_1) -> 30;
name_to_id(m_dp_tb_1) -> 31;
name_to_id(m_me_td_1) -> 34;
name_to_id(m_me_te_1) -> 35;
name_to_id(m_me_tf_1) -> 36;
name_to_id(m_it_tb_1) -> 37;
name_to_id(m_ei_na_1) -> 70;
name_to_id(c_sc_na_1) -> 45;
name_to_id(c_dc_na_1) -> 46;
name_to_id(c_rc_na_1) -> 47;
name_to_id(c_se_na_1) -> 48;
name_to_id(c_se_nb_1) -> 49;
name_to_id(c_se_nc_1) -> 50;
name_to_id(c_ic_na_1) -> 100;
name_to_id(c_ci_na_1) -> 101;
name_to_id(c_rd_na_1) -> 102;
name_to_id(c_cs_na_1) -> 103;
name_to_id(c_ts_ta_1) -> 107;
name_to_id(p_me_na_1) -> 110;
name_to_id(p_me_nb_1) -> 111;
name_to_id(p_me_nc_1) -> 112;
name_to_id(p_ac_na_1) -> 113;
name_to_id(N) when is_integer(N), N >= 0, N =< 255 -> N.

-spec id_to_name(0..255) -> iec60870_asdu:type_name() | 0..255.
id_to_name(1)   -> m_sp_na_1;
id_to_name(3)   -> m_dp_na_1;
id_to_name(5)   -> m_st_na_1;
id_to_name(9)   -> m_me_na_1;
id_to_name(11)  -> m_me_nb_1;
id_to_name(13)  -> m_me_nc_1;
id_to_name(15)  -> m_it_na_1;
id_to_name(30)  -> m_sp_tb_1;
id_to_name(31)  -> m_dp_tb_1;
id_to_name(34)  -> m_me_td_1;
id_to_name(35)  -> m_me_te_1;
id_to_name(36)  -> m_me_tf_1;
id_to_name(37)  -> m_it_tb_1;
id_to_name(70)  -> m_ei_na_1;
id_to_name(45)  -> c_sc_na_1;
id_to_name(46)  -> c_dc_na_1;
id_to_name(47)  -> c_rc_na_1;
id_to_name(48)  -> c_se_na_1;
id_to_name(49)  -> c_se_nb_1;
id_to_name(50)  -> c_se_nc_1;
id_to_name(100) -> c_ic_na_1;
id_to_name(101) -> c_ci_na_1;
id_to_name(102) -> c_rd_na_1;
id_to_name(103) -> c_cs_na_1;
id_to_name(107) -> c_ts_ta_1;
id_to_name(110) -> p_me_na_1;
id_to_name(111) -> p_me_nb_1;
id_to_name(112) -> p_me_nc_1;
id_to_name(113) -> p_ac_na_1;
id_to_name(N) when is_integer(N), N >= 0, N =< 255 -> N.

-doc """
Fixed octet length of one information element's payload (everything after its
information object address). Every v1 type has a constant width; used by
`m:iec60870_batch` to size ASDUs.
""".
-spec payload_size(iec60870_asdu:type_name()) -> non_neg_integer().
payload_size(m_sp_na_1) -> 1;
payload_size(m_dp_na_1) -> 1;
payload_size(m_st_na_1) -> 2;
payload_size(m_me_na_1) -> 3;
payload_size(m_me_nb_1) -> 3;
payload_size(m_me_nc_1) -> 5;
payload_size(m_it_na_1) -> 5;
payload_size(m_sp_tb_1) -> 8;
payload_size(m_dp_tb_1) -> 8;
payload_size(m_me_td_1) -> 10;
payload_size(m_me_te_1) -> 10;
payload_size(m_me_tf_1) -> 12;
payload_size(m_it_tb_1) -> 12;
payload_size(m_ei_na_1) -> 1;
payload_size(c_sc_na_1) -> 1;
payload_size(c_dc_na_1) -> 1;
payload_size(c_rc_na_1) -> 1;
payload_size(c_se_na_1) -> 3;
payload_size(c_se_nb_1) -> 3;
payload_size(c_se_nc_1) -> 5;
payload_size(c_ic_na_1) -> 1;
payload_size(c_ci_na_1) -> 1;
payload_size(c_rd_na_1) -> 0;
payload_size(c_cs_na_1) -> 7;
payload_size(c_ts_ta_1) -> 9;
payload_size(p_me_na_1) -> 3;
payload_size(p_me_nb_1) -> 3;
payload_size(p_me_nc_1) -> 5;
payload_size(p_ac_na_1) -> 1.

%%%===================================================================
%%% Payload encode
%%%===================================================================

-spec encode_payload(iec60870_asdu:type_name() | 0..255, #object{}) -> binary().
%% --- monitored, no time ---
encode_payload(m_sp_na_1, #object{value = V, quality = Q}) ->
    siq(V, Q);
encode_payload(m_dp_na_1, #object{value = V, quality = Q}) ->
    diq(V, Q);
encode_payload(m_st_na_1, #object{value = V, quality = Q, qualifier = Ql}) ->
    <<(vti(V, transient(Ql)))/binary, (qds(Q))/binary>>;
encode_payload(m_me_na_1, #object{value = V, quality = Q}) ->
    <<(i16(V))/binary, (qds(Q))/binary>>;
encode_payload(m_me_nb_1, #object{value = V, quality = Q}) ->
    <<(i16(V))/binary, (qds(Q))/binary>>;
encode_payload(m_me_nc_1, #object{value = V, quality = Q}) ->
    <<(f32(V))/binary, (qds(Q))/binary>>;
encode_payload(m_it_na_1, #object{value = V, quality = Q, qualifier = Ql}) ->
    bcr(V, sequence(Ql), flag(Ql, carry), flag(Ql, adjusted), inv(Q));
%% --- monitored, CP56Time2a ---
encode_payload(m_sp_tb_1, #object{value = V, quality = Q, timestamp = T}) ->
    <<(siq(V, Q))/binary, (cp56(T))/binary>>;
encode_payload(m_dp_tb_1, #object{value = V, quality = Q, timestamp = T}) ->
    <<(diq(V, Q))/binary, (cp56(T))/binary>>;
encode_payload(m_me_td_1, #object{value = V, quality = Q, timestamp = T}) ->
    <<(i16(V))/binary, (qds(Q))/binary, (cp56(T))/binary>>;
encode_payload(m_me_te_1, #object{value = V, quality = Q, timestamp = T}) ->
    <<(i16(V))/binary, (qds(Q))/binary, (cp56(T))/binary>>;
encode_payload(m_me_tf_1, #object{value = V, quality = Q, timestamp = T}) ->
    <<(f32(V))/binary, (qds(Q))/binary, (cp56(T))/binary>>;
encode_payload(m_it_tb_1, #object{value = V, quality = Q, qualifier = Ql, timestamp = T}) ->
    <<(bcr(V, sequence(Ql), flag(Ql, carry), flag(Ql, adjusted), inv(Q)))/binary,
      (cp56(T))/binary>>;
%% --- end of initialization ---
encode_payload(m_ei_na_1, #object{value = V, qualifier = Ql})
  when is_integer(V), V >= 0, V =< 127 ->
    <<(local_change(Ql)):1, V:7>>;
%% --- commands ---
encode_payload(c_sc_na_1, #object{value = V, qualifier = Ql}) ->
    <<(bit(is_select(Ql))):1, (qu(Ql)):5, 0:1, (bit(V)):1>>;
encode_payload(c_dc_na_1, #object{value = V, qualifier = Ql}) ->
    <<(bit(is_select(Ql))):1, (qu(Ql)):5, V:2>>;
encode_payload(c_rc_na_1, #object{value = V, qualifier = Ql}) ->
    <<(bit(is_select(Ql))):1, (qu(Ql)):5, V:2>>;
encode_payload(c_se_na_1, #object{value = V, qualifier = Ql}) ->
    <<(i16(V))/binary, (bit(is_select(Ql))):1, (ql(Ql)):7>>;
encode_payload(c_se_nb_1, #object{value = V, qualifier = Ql}) ->
    <<(i16(V))/binary, (bit(is_select(Ql))):1, (ql(Ql)):7>>;
encode_payload(c_se_nc_1, #object{value = V, qualifier = Ql}) ->
    <<(f32(V))/binary, (bit(is_select(Ql))):1, (ql(Ql)):7>>;
%% --- system information ---
encode_payload(c_ic_na_1, #object{value = Qoi}) when is_integer(Qoi), Qoi >= 0, Qoi =< 255 ->
    <<Qoi:8>>;
encode_payload(c_ci_na_1, #object{value = Qcc}) ->
    qcc(Qcc);
encode_payload(c_rd_na_1, #object{}) ->
    <<>>;
encode_payload(c_cs_na_1, #object{timestamp = T}) ->
    cp56(T);
encode_payload(c_ts_ta_1, #object{value = Tsc, timestamp = T})
  when is_integer(Tsc), Tsc >= 0, Tsc =< 65535 ->
    <<Tsc:16/little-unsigned, (cp56(T))/binary>>;
%% --- parameter of measured value ---
encode_payload(p_me_na_1, #object{value = V, qualifier = Ql}) ->
    <<(i16(V))/binary, (qpm(Ql))/binary>>;
encode_payload(p_me_nb_1, #object{value = V, qualifier = Ql}) ->
    <<(i16(V))/binary, (qpm(Ql))/binary>>;
encode_payload(p_me_nc_1, #object{value = V, qualifier = Ql}) ->
    <<(f32(V))/binary, (qpm(Ql))/binary>>;
encode_payload(p_ac_na_1, #object{value = Qpa}) ->
    <<(qpa_int(Qpa)):8>>;
%% --- raw escape hatch for type ids the codec does not model ---
encode_payload(N, #object{value = Raw}) when is_integer(N) ->
    iolist_to_binary(Raw).

%%%===================================================================
%%% Payload decode
%%%===================================================================

-spec decode_payload(iec60870_asdu:type_name(), non_neg_integer(), binary()) ->
        {#object{}, binary()}.
%% --- monitored, no time ---
decode_payload(m_sp_na_1, Ioa, Bin) ->
    {V, Q, R} = siq_take(Bin),
    {#object{ioa = Ioa, value = V, quality = Q}, R};
decode_payload(m_dp_na_1, Ioa, Bin) ->
    {V, Q, R} = diq_take(Bin),
    {#object{ioa = Ioa, value = V, quality = Q}, R};
decode_payload(m_st_na_1, Ioa, Bin) ->
    {Pos, Tr, R0} = vti_take(Bin),
    {Q, R1} = qds_take(R0),
    {#object{ioa = Ioa, value = Pos, quality = Q, qualifier = #{transient => Tr}}, R1};
decode_payload(m_me_na_1, Ioa, Bin) -> measured_i16(Ioa, Bin);
decode_payload(m_me_nb_1, Ioa, Bin) -> measured_i16(Ioa, Bin);
decode_payload(m_me_nc_1, Ioa, Bin) ->
    {V, R0} = f32_take(Bin),
    {Q, R1} = qds_take(R0),
    {#object{ioa = Ioa, value = V, quality = Q}, R1};
decode_payload(m_it_na_1, Ioa, Bin) ->
    {V, Seq, CY, CA, IV, R} = bcr_take(Bin),
    {#object{ioa = Ioa, value = V, quality = inv_list(IV),
             qualifier = #{sequence => Seq, carry => CY, adjusted => CA}}, R};
%% --- monitored, CP56Time2a ---
decode_payload(m_sp_tb_1, Ioa, Bin) ->
    {V, Q, R0} = siq_take(Bin),
    {T, R1} = cp56_take(R0),
    {#object{ioa = Ioa, value = V, quality = Q, timestamp = T}, R1};
decode_payload(m_dp_tb_1, Ioa, Bin) ->
    {V, Q, R0} = diq_take(Bin),
    {T, R1} = cp56_take(R0),
    {#object{ioa = Ioa, value = V, quality = Q, timestamp = T}, R1};
decode_payload(m_me_td_1, Ioa, Bin) -> measured_i16_t(Ioa, Bin);
decode_payload(m_me_te_1, Ioa, Bin) -> measured_i16_t(Ioa, Bin);
decode_payload(m_me_tf_1, Ioa, Bin) ->
    {V, R0} = f32_take(Bin),
    {Q, R1} = qds_take(R0),
    {T, R2} = cp56_take(R1),
    {#object{ioa = Ioa, value = V, quality = Q, timestamp = T}, R2};
decode_payload(m_it_tb_1, Ioa, Bin) ->
    {V, Seq, CY, CA, IV, R0} = bcr_take(Bin),
    {T, R1} = cp56_take(R0),
    {#object{ioa = Ioa, value = V, quality = inv_list(IV),
             qualifier = #{sequence => Seq, carry => CY, adjusted => CA},
             timestamp = T}, R1};
%% --- end of initialization ---
decode_payload(m_ei_na_1, Ioa, <<LPC:1, UI:7, R/binary>>) ->
    {#object{ioa = Ioa, value = UI, qualifier = #{local_change => LPC =:= 1}}, R};
%% --- commands ---
decode_payload(c_sc_na_1, Ioa, <<SE:1, QU:5, _:1, SCS:1, R/binary>>) ->
    {#object{ioa = Ioa, value = SCS =:= 1,
             qualifier = #{select => SE =:= 1, qu => QU}}, R};
decode_payload(c_dc_na_1, Ioa, <<SE:1, QU:5, DCS:2, R/binary>>) ->
    {#object{ioa = Ioa, value = DCS, qualifier = #{select => SE =:= 1, qu => QU}}, R};
decode_payload(c_rc_na_1, Ioa, <<SE:1, QU:5, RCS:2, R/binary>>) ->
    {#object{ioa = Ioa, value = RCS, qualifier = #{select => SE =:= 1, qu => QU}}, R};
decode_payload(c_se_na_1, Ioa, Bin) -> setpoint_i16(Ioa, Bin);
decode_payload(c_se_nb_1, Ioa, Bin) -> setpoint_i16(Ioa, Bin);
decode_payload(c_se_nc_1, Ioa, Bin) ->
    {V, R0} = f32_take(Bin),
    <<SE:1, QL:7, R1/binary>> = R0,
    {#object{ioa = Ioa, value = V, qualifier = #{select => SE =:= 1, ql => QL}}, R1};
%% --- system information ---
decode_payload(c_ic_na_1, Ioa, <<Qoi:8, R/binary>>) ->
    {#object{ioa = Ioa, value = Qoi}, R};
decode_payload(c_ci_na_1, Ioa, <<FRZ:2, RQT:6, R/binary>>) ->
    {#object{ioa = Ioa, value = #{request => RQT, freeze => unfreeze(FRZ)}}, R};
decode_payload(c_rd_na_1, Ioa, Bin) ->
    {#object{ioa = Ioa}, Bin};
decode_payload(c_cs_na_1, Ioa, Bin) ->
    {T, R} = cp56_take(Bin),
    {#object{ioa = Ioa, timestamp = T}, R};
decode_payload(c_ts_ta_1, Ioa, <<Tsc:16/little-unsigned, Rest/binary>>) ->
    {T, R} = cp56_take(Rest),
    {#object{ioa = Ioa, value = Tsc, timestamp = T}, R};
%% --- parameter of measured value ---
decode_payload(p_me_na_1, Ioa, Bin) -> parameter_i16(Ioa, Bin);
decode_payload(p_me_nb_1, Ioa, Bin) -> parameter_i16(Ioa, Bin);
decode_payload(p_me_nc_1, Ioa, Bin) ->
    {V, R0} = f32_take(Bin),
    {Qpm, R1} = qpm_take(R0),
    {#object{ioa = Ioa, value = V, qualifier = Qpm}, R1};
decode_payload(p_ac_na_1, Ioa, <<Qpa:8, R/binary>>) ->
    {#object{ioa = Ioa, value = qpa(Qpa)}, R}.

%%%===================================================================
%%% Shared field codecs
%%%===================================================================

%% SIQ — single-point information with quality (no overflow bit).
siq(V, Q) when is_boolean(V) ->
    <<(inv(Q)):1, (nt(Q)):1, (sb(Q)):1, (bl(Q)):1, 0:3, (bit(V)):1>>.

siq_take(<<IV:1, NT:1, SB:1, BL:1, _:3, SPI:1, R/binary>>) ->
    {SPI =:= 1, quality_flags(BL, SB, NT, IV), R}.

%% DIQ — double-point information with quality.
diq(V, Q) when is_integer(V), V >= 0, V =< 3 ->
    <<(inv(Q)):1, (nt(Q)):1, (sb(Q)):1, (bl(Q)):1, 0:2, V:2>>.

diq_take(<<IV:1, NT:1, SB:1, BL:1, _:2, DPI:2, R/binary>>) ->
    {DPI, quality_flags(BL, SB, NT, IV), R}.

%% QDS — quality descriptor set (with overflow).
qds(Q) ->
    <<(inv(Q)):1, (nt(Q)):1, (sb(Q)):1, (bl(Q)):1, 0:3, (ov(Q)):1>>.

qds_take(<<IV:1, NT:1, SB:1, BL:1, _:3, OV:1, R/binary>>) ->
    Flags = [overflow || OV =:= 1] ++ quality_flags(BL, SB, NT, IV),
    {Flags, R}.

%% VTI — value with transient-state indication (7-bit two's complement).
vti(Pos, Transient) when is_integer(Pos), Pos >= -64, Pos =< 63 ->
    <<(bit(Transient)):1, (Pos band 16#7F):7>>.

vti_take(<<T:1, U:7, R/binary>>) ->
    Pos = case U >= 16#40 of true -> U - 16#80; false -> U end,
    {Pos, T =:= 1, R}.

%% NVA / SVA — 16-bit signed, little-endian.
i16(V) when is_integer(V), V >= -32768, V =< 32767 -> <<V:16/little-signed>>.
i16_take(<<V:16/little-signed, R/binary>>) -> {V, R}.

%% R32 — IEEE 754 single precision, little-endian.
f32(V) when is_number(V) -> <<(float(V)):32/little-float>>.
f32_take(<<V:32/little-float, R/binary>>) -> {V, R}.

%% BCR — binary counter reading (4-octet value + 1-octet sequence notation).
bcr(V, Seq, Carry, Adjusted, Invalid)
  when is_integer(V), V >= -2147483648, V =< 2147483647,
       is_integer(Seq), Seq >= 0, Seq =< 31 ->
    <<V:32/little-signed,
      (bit(Invalid)):1, (bit(Adjusted)):1, (bit(Carry)):1, Seq:5>>.

bcr_take(<<V:32/little-signed, IV:1, CA:1, CY:1, Seq:5, R/binary>>) ->
    {V, Seq, CY =:= 1, CA =:= 1, IV =:= 1, R}.

%% QCC — qualifier of counter interrogation command.
qcc(#{request := RQT, freeze := F}) when is_integer(RQT), RQT >= 0, RQT =< 63 ->
    <<(freeze(F)):2, RQT:6>>;
qcc(N) when is_integer(N), N >= 0, N =< 255 ->
    <<N:8>>.

freeze(read)             -> 0;
freeze(freeze_no_reset)  -> 1;
freeze(freeze_reset)     -> 2;
freeze(reset)            -> 3.

unfreeze(0) -> read;
unfreeze(1) -> freeze_no_reset;
unfreeze(2) -> freeze_reset;
unfreeze(3) -> reset.

%% QPM — qualifier of parameter of measured value (kind, point-in-operation,
%% local-change flags).
qpm(#{kind := Kind, in_operation := InOp, local_change := LPC}) ->
    <<(bit(LPC)):1, (bit(InOp =:= false)):1, (kpa_int(Kind)):6>>.

qpm_take(<<LPC:1, POP:1, KPA:6, R/binary>>) ->
    {#{kind => kpa(KPA), in_operation => POP =:= 0, local_change => LPC =:= 1}, R}.

kpa(0) -> not_used;
kpa(1) -> threshold_value;
kpa(2) -> smoothing_factor;
kpa(3) -> low_limit;
kpa(4) -> high_limit;
kpa(N) when is_integer(N) -> N.

kpa_int(not_used) -> 0;
kpa_int(threshold_value) -> 1;
kpa_int(smoothing_factor) -> 2;
kpa_int(low_limit) -> 3;
kpa_int(high_limit) -> 4;
kpa_int(N) when is_integer(N), N >= 0, N =< 63 -> N.

%% QPA — qualifier of parameter activation.
qpa(0) -> not_used;
qpa(1) -> act_deact_parameter;
qpa(2) -> act_deact_persistent_cyclic;
qpa(N) when is_integer(N) -> N.

qpa_int(not_used) -> 0;
qpa_int(act_deact_parameter) -> 1;
qpa_int(act_deact_persistent_cyclic) -> 2;
qpa_int(N) when is_integer(N), N >= 0, N =< 127 -> N.

cp56_take(<<B:7/binary, R/binary>>) -> {iec60870_cp56:from_binary(B), R}.

cp56(#cp56{} = T) -> iec60870_cp56:to_binary(T);
cp56(Millis) when is_integer(Millis) -> iec60870_cp56:to_binary(iec60870_cp56:from_timestamp(Millis)).

%%%===================================================================
%%% Small decode helpers (shared bodies)
%%%===================================================================

measured_i16(Ioa, Bin) ->
    {V, R0} = i16_take(Bin),
    {Q, R1} = qds_take(R0),
    {#object{ioa = Ioa, value = V, quality = Q}, R1}.

measured_i16_t(Ioa, Bin) ->
    {V, R0} = i16_take(Bin),
    {Q, R1} = qds_take(R0),
    {T, R2} = cp56_take(R1),
    {#object{ioa = Ioa, value = V, quality = Q, timestamp = T}, R2}.

setpoint_i16(Ioa, Bin) ->
    {V, R0} = i16_take(Bin),
    <<SE:1, QL:7, R1/binary>> = R0,
    {#object{ioa = Ioa, value = V, qualifier = #{select => SE =:= 1, ql => QL}}, R1}.

parameter_i16(Ioa, Bin) ->
    {V, R0} = i16_take(Bin),
    {Qpm, R1} = qpm_take(R0),
    {#object{ioa = Ioa, value = V, qualifier = Qpm}, R1}.

%%%===================================================================
%%% Quality-list <-> bit helpers
%%%===================================================================

quality_flags(BL, SB, NT, IV) ->
    [blocked     || BL =:= 1] ++
    [substituted || SB =:= 1] ++
    [not_topical || NT =:= 1] ++
    [invalid     || IV =:= 1].

ov(Q) -> bit(lists:member(overflow, Q)).
bl(Q) -> bit(lists:member(blocked, Q)).
sb(Q) -> bit(lists:member(substituted, Q)).
nt(Q) -> bit(lists:member(not_topical, Q)).
inv(Q) -> bit(lists:member(invalid, Q)).

inv_list(true)  -> [invalid];
inv_list(false) -> [].

%%%===================================================================
%%% Qualifier-map accessors (tolerant of `undefined')
%%%===================================================================

transient(#{transient := T}) -> T;
transient(_) -> false.

sequence(#{sequence := S}) when is_integer(S) -> S;
sequence(_) -> 0.

flag(M, K) when is_map(M) -> maps:get(K, M, false) =:= true;
flag(_, _) -> false.

local_change(#{local_change := true}) -> 1;
local_change(_) -> 0.

is_select(#{select := S}) -> S =:= true;
is_select(_) -> false.

qu(#{qu := N}) when is_integer(N), N >= 0, N =< 31 -> N;
qu(_) -> 0.

ql(#{ql := N}) when is_integer(N), N >= 0, N =< 127 -> N;
ql(_) -> 0.

bit(true) -> 1;
bit(false) -> 0;
bit(1) -> 1;
bit(0) -> 0.
