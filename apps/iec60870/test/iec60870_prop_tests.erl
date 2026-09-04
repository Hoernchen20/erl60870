%%% Property: `decode(encode(ASDU)) == ASDU' for every v1 type id, across
%%% the configurable COT / COA / IOA field widths and both structure qualifiers.
-module(iec60870_prop_tests).

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("iec60870/include/iec60870_asdu.hrl").

roundtrip_test_() ->
    {timeout, 120,
     ?_assert(proper:quickcheck(prop_roundtrip(),
                                [{numtests, 1000}, {to_file, user}]))}.

prop_roundtrip() ->
    ?FORALL({Asdu, Opts}, asdu_gen(),
            begin
                Bin = iec60870_asdu:encode(Asdu, Opts),
                ?WHENFAIL(
                   io:format("opts=~p~nasdu=~p~nbin=~p~n", [Opts, Asdu, Bin]),
                   {ok, Asdu, <<>>} =:= iec60870_asdu:decode(Bin, Opts))
            end).

%%%===================================================================
%%% ASDU generator
%%%===================================================================

asdu_gen() ->
    ?LET(Type, oneof(all_types()),
    ?LET({CotSz, CoaSz, IoaSz}, {oneof([1, 2]), oneof([1, 2]), oneof([1, 2, 3])},
    ?LET(SQ, sq_gen(Type),
    ?LET(Count, range(1, 12),
    ?LET({Cot, Test, Neg, Orig, Coa, Base, Objs0},
         {cot_gen(), boolean(), boolean(), range(0, 255),
          coa_gen(CoaSz), base_ioa(IoaSz, Count), vector(Count, obj_gen(Type))},
         begin
             Orig1 = case CotSz of 1 -> 0; 2 -> Orig end,
             Asdu = #asdu{type = Type, cot = Cot, negative = Neg, test = Test,
                          orig_addr = Orig1, coa = Coa, sequence = SQ,
                          objects = assign_ioas(Objs0, Base)},
             {Asdu, #{cot_size => CotSz, coa_size => CoaSz, ioa_size => IoaSz}}
         end))))).

all_types() ->
    [m_sp_na_1, m_sp_tb_1, m_dp_na_1, m_dp_tb_1, m_st_na_1,
     m_me_na_1, m_me_nb_1, m_me_nc_1, m_me_td_1, m_me_te_1, m_me_tf_1,
     m_it_na_1, m_it_tb_1, m_ei_na_1,
     c_sc_na_1, c_dc_na_1, c_rc_na_1, c_se_na_1, c_se_nb_1, c_se_nc_1,
     c_ic_na_1, c_ci_na_1, c_rd_na_1, c_cs_na_1, c_ts_ta_1,
     p_me_na_1, p_me_nb_1, p_me_nc_1, p_ac_na_1].

%% SQ=1 only for the monitored types with a fixed-size payload.
sq_gen(Type) ->
    case lists:member(Type, [m_sp_na_1, m_sp_tb_1, m_dp_na_1, m_dp_tb_1, m_st_na_1,
                             m_me_na_1, m_me_nb_1, m_me_nc_1, m_me_td_1, m_me_te_1,
                             m_me_tf_1, m_it_na_1, m_it_tb_1,
                             p_me_na_1, p_me_nb_1, p_me_nc_1]) of
        true -> boolean();
        false -> false
    end.

cot_gen() ->
    oneof([periodic, background, spontaneous, initialized, request,
           act, act_con, deact, deact_con, act_term,
           return_remote, return_local, file_transfer,
           interrogated_station, interrogated_counter,
           unknown_type_id, unknown_cot, unknown_coa, unknown_ioa,
           {interrogated_group, range(1, 16)},
           {interrogated_counter_group, range(1, 4)},
           0, 14, 19, 63]).

coa_gen(1) -> range(0, 255);
coa_gen(2) -> range(0, 65535).

base_ioa(IoaSz, Count) ->
    range(0, max(0, (1 bsl (8 * IoaSz)) - 1 - Count)).

assign_ioas(Objs, Base) ->
    [O#object{ioa = Base + I}
     || {O, I} <- lists:zip(Objs, lists:seq(0, length(Objs) - 1))].

%%%===================================================================
%%% per-type object generators — must match exactly what decode yields
%%%===================================================================

obj_gen(m_sp_na_1) -> ?LET({V, Q}, {boolean(), qual_sp()},
                           #object{value = V, quality = Q});
obj_gen(m_sp_tb_1) -> ?LET({V, Q, T}, {boolean(), qual_sp(), cp56_g()},
                           #object{value = V, quality = Q, timestamp = T});
obj_gen(m_dp_na_1) -> ?LET({V, Q}, {range(0, 3), qual_sp()},
                           #object{value = V, quality = Q});
obj_gen(m_dp_tb_1) -> ?LET({V, Q, T}, {range(0, 3), qual_sp(), cp56_g()},
                           #object{value = V, quality = Q, timestamp = T});
obj_gen(m_st_na_1) -> ?LET({V, Tr, Q}, {range(-64, 63), boolean(), qual_full()},
                           #object{value = V, quality = Q,
                                   qualifier = #{transient => Tr}});
obj_gen(m_me_na_1) -> measured(i16_g());
obj_gen(m_me_nb_1) -> measured(i16_g());
obj_gen(m_me_nc_1) -> measured(f32_g());
obj_gen(m_me_td_1) -> measured_t(i16_g());
obj_gen(m_me_te_1) -> measured_t(i16_g());
obj_gen(m_me_tf_1) -> measured_t(f32_g());
obj_gen(m_it_na_1) ->
    ?LET({V, S, C, A, IV}, {i32_g(), range(0, 31), boolean(), boolean(), boolean()},
         #object{value = V, quality = inv_q(IV),
                 qualifier = #{sequence => S, carry => C, adjusted => A}});
obj_gen(m_it_tb_1) ->
    ?LET({V, S, C, A, IV, T},
         {i32_g(), range(0, 31), boolean(), boolean(), boolean(), cp56_g()},
         #object{value = V, quality = inv_q(IV),
                 qualifier = #{sequence => S, carry => C, adjusted => A},
                 timestamp = T});
obj_gen(m_ei_na_1) ->
    ?LET({V, LC}, {range(0, 127), boolean()},
         #object{value = V, qualifier = #{local_change => LC}});
obj_gen(c_sc_na_1) ->
    ?LET({V, S, Qu}, {boolean(), boolean(), range(0, 31)},
         #object{value = V, qualifier = #{select => S, qu => Qu}});
obj_gen(c_dc_na_1) -> command_code();
obj_gen(c_rc_na_1) -> command_code();
obj_gen(c_se_na_1) -> setpoint(i16_g());
obj_gen(c_se_nb_1) -> setpoint(i16_g());
obj_gen(c_se_nc_1) -> setpoint(f32_g());
obj_gen(c_ic_na_1) -> ?LET(V, range(0, 255), #object{value = V});
obj_gen(c_ci_na_1) ->
    ?LET({R, F}, {range(0, 63),
                  oneof([read, freeze_no_reset, freeze_reset, reset])},
         #object{value = #{request => R, freeze => F}});
obj_gen(c_rd_na_1) -> #object{};
obj_gen(c_cs_na_1) -> ?LET(T, cp56_g(), #object{timestamp = T});
obj_gen(c_ts_ta_1) -> ?LET({V, T}, {range(0, 65535), cp56_g()},
                           #object{value = V, timestamp = T});
obj_gen(p_me_na_1) -> param_obj(i16_g());
obj_gen(p_me_nb_1) -> param_obj(i16_g());
obj_gen(p_me_nc_1) -> param_obj(f32_g());
obj_gen(p_ac_na_1) ->
    ?LET(Q, oneof([not_used, act_deact_parameter,
                  act_deact_persistent_cyclic, range(3, 127)]),
         #object{value = Q}).

param_obj(ValGen) ->
    ?LET({V, K, InOp, LPC},
         {ValGen, oneof([not_used, threshold_value, smoothing_factor,
                        low_limit, high_limit, range(5, 63)]),
          boolean(), boolean()},
         #object{value = V, qualifier = #{kind => K, in_operation => InOp,
                                          local_change => LPC}}).

measured(ValGen) ->
    ?LET({V, Q}, {ValGen, qual_full()}, #object{value = V, quality = Q}).

measured_t(ValGen) ->
    ?LET({V, Q, T}, {ValGen, qual_full(), cp56_g()},
         #object{value = V, quality = Q, timestamp = T}).

setpoint(ValGen) ->
    ?LET({V, S, Ql}, {ValGen, boolean(), range(0, 127)},
         #object{value = V, qualifier = #{select => S, ql => Ql}}).

command_code() ->
    ?LET({V, S, Qu}, {range(0, 3), boolean(), range(0, 31)},
         #object{value = V, qualifier = #{select => S, qu => Qu}}).

%%%===================================================================
%%% field generators
%%%===================================================================

qual_full() -> canon_sublist([overflow, blocked, substituted, not_topical, invalid]).
qual_sp()   -> canon_sublist([blocked, substituted, not_topical, invalid]).

canon_sublist(All) ->
    ?LET(Keep, vector(length(All), boolean()),
         [X || {X, true} <- lists:zip(All, Keep)]).

cp56_g() ->
    ?LET({MS, Mi, H, DoM, DoW, Mo, Y, SU, IV},
         {range(0, 59999), range(0, 59), range(0, 23), range(1, 31),
          range(0, 7), range(1, 12), range(0, 99), boolean(), boolean()},
         #cp56{milliseconds = MS, minute = Mi, hour = H, day_of_month = DoM,
               day_of_week = DoW, month = Mo, year = Y,
               summer_time = SU, invalid = IV}).

i16_g() -> range(-32768, 32767).
i32_g() -> range(-2147483648, 2147483647).

%% Values that are exactly representable as an IEEE-754 single, so `=:='
%% survives the 32-bit narrowing on the wire.
f32_g() ->
    ?LET({N, D}, {range(-8000000, 8000000), oneof([1, 2, 4, 8, 16])}, N / D).

inv_q(true)  -> [invalid];
inv_q(false) -> [].
