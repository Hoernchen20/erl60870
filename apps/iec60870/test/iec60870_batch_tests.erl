-module(iec60870_batch_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("iec60870/include/iec60870_asdu.hrl").

-define(OPTS, #{cot_size => 2, coa_size => 2, ioa_size => 3}).

%%%===================================================================
%%% SQ selection
%%%===================================================================

single_object_is_sq0_test() ->
    [Asdu] = pack(m_sp_na_1, spontaneous, [sp(10, true)]),
    ?assertEqual(false, Asdu#asdu.sequence),
    ?assertEqual(1, length(Asdu#asdu.objects)).

contiguous_run_is_sq1_test() ->
    [Asdu] = pack(m_sp_na_1, spontaneous, [sp(10, true), sp(11, false), sp(12, true)]),
    ?assertEqual(true, Asdu#asdu.sequence),
    ?assertEqual([10, 11, 12], ioas(Asdu)).

scattered_singletons_share_one_sq0_asdu_test() ->
    [Asdu] = pack(m_sp_na_1, spontaneous, [sp(10, true), sp(20, false), sp(30, true)]),
    ?assertEqual(false, Asdu#asdu.sequence),
    ?assertEqual([10, 20, 30], ioas(Asdu)).

mixed_runs_and_singletons_test() ->
    Objs = [sp(1, true), sp(2, false), sp(3, true), sp(10, true), sp(20, false)],
    Asdus = pack(m_sp_na_1, spontaneous, Objs),
    Seqs = [A || A <- Asdus, A#asdu.sequence],
    Flats = [A || A <- Asdus, not A#asdu.sequence],
    ?assertEqual([[1, 2, 3]], [ioas(A) || A <- Seqs]),
    ?assertEqual([[10, 20]], [ioas(A) || A <- Flats]).

%%%===================================================================
%%% Splitting
%%%===================================================================

object_count_cap_splits_test() ->
    %% 200 contiguous single points, SQ=1 payload 1 octet: cap is the 127 VSQ
    %% limit, so 200 -> 127 + 73.
    Objs = [sp(N, true) || N <- lists:seq(1, 200)],
    Asdus = pack(m_sp_na_1, spontaneous, Objs),
    ?assertEqual([127, 73], [length(A#asdu.objects) || A <- Asdus]),
    ?assert(lists:all(fun(A) -> A#asdu.sequence end, Asdus)).

octet_cap_splits_test() ->
    %% M_ME_TF_1 SQ=1: 12-octet payload. (249 - 2 - 2 - 2 - 3) / 12 = 20 per ASDU.
    Objs = [me_tf(N, 1.0) || N <- lists:seq(1, 45)],
    Asdus = pack(m_me_tf_1, spontaneous, Objs),
    ?assertEqual([20, 20, 5], [length(A#asdu.objects) || A <- Asdus]),
    ?assert(lists:all(fun(A) -> encoded_size(A) =< ?IEC60870_ASDU_MAX_OCTETS end, Asdus)).

one_asdu_per_type_test() ->
    Groups = [{{m_sp_na_1, 1, spontaneous}, [sp(1, true)]},
              {{m_me_nc_1, 1, spontaneous}, [me_nc(1, 2.5)]}],
    Asdus = iec60870_batch:pack(Groups, ?OPTS),
    ?assertEqual([m_sp_na_1, m_me_nc_1], [A#asdu.type || A <- Asdus]).

empty_groups_pruned_test() ->
    ?assertEqual([], iec60870_batch:pack([{{m_sp_na_1, 1, spontaneous}, []}], ?OPTS)).

%%%===================================================================
%%% Round trip through the wire codec
%%%===================================================================

dedup_last_write_wins_test() ->
    [Asdu] = pack(m_sp_na_1, spontaneous, [sp(10, true), sp(10, false)]),
    ?assertEqual([#object{ioa = 10, value = false, quality = []}],
                 Asdu#asdu.objects).

roundtrip_reassembles_objects_test() ->
    Objs = [sp(N, N rem 2 =:= 0) || N <- lists:seq(1, 130)]
        ++ [sp(500, true), sp(1000, false)],
    Asdus = pack(m_sp_na_1, spontaneous, Objs),
    Decoded = lists:append(
                [begin
                     {ok, A, <<>>} = iec60870_asdu:decode(iec60870_asdu:encode(A, ?OPTS), ?OPTS),
                     A#asdu.objects
                 end || A <- Asdus]),
    Expected = lists:sort([{O#object.ioa, O#object.value} || O <- Objs]),
    Got = lists:sort([{O#object.ioa, O#object.value} || O <- Decoded]),
    ?assertEqual(Expected, Got).

%%%===================================================================
%%% helpers
%%%===================================================================

pack(Type, Cot, Objs) ->
    iec60870_batch:pack([{{Type, 1, Cot}, Objs}], ?OPTS).

ioas(#asdu{objects = Objs}) -> [O#object.ioa || O <- Objs].

encoded_size(Asdu) -> byte_size(iec60870_asdu:encode(Asdu, ?OPTS)).

sp(Ioa, V) -> #object{ioa = Ioa, value = V, quality = []}.

me_nc(Ioa, V) -> #object{ioa = Ioa, value = V, quality = []}.

me_tf(Ioa, V) ->
    #object{ioa = Ioa, value = V, quality = [],
            timestamp = #cp56{milliseconds = 0, minute = 0, hour = 0,
                              day_of_month = 1, month = 1, year = 25}}.
