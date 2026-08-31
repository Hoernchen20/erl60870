-module(iec60870_104_apci_tests).

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

%%%===================================================================
%%% Spec byte vectors (IEC 60870-5-104 section 5.1)
%%%===================================================================

vec_i_frame_empty_test() ->
    check({i, 0, 0, <<>>}, <<16#68, 4, 0, 0, 0, 0>>).

vec_i_frame_with_asdu_test() ->
    check({i, 1, 2, <<1, 2, 3>>}, <<16#68, 7, 2, 0, 4, 0, 1, 2, 3>>).

%% N(S) that spans both control octets: 300 = 2#1_0010_1100.
vec_i_frame_wide_seq_test() ->
    check({i, 300, 0, <<>>}, <<16#68, 4, 88, 2, 0, 0>>).

vec_s_frame_test() ->
    check({s, 5}, <<16#68, 4, 16#01, 0, 10, 0>>).

vec_u_frames_test() ->
    check({u, startdt_act}, <<16#68, 4, 16#07, 0, 0, 0>>),
    check({u, startdt_con}, <<16#68, 4, 16#0B, 0, 0, 0>>),
    check({u, stopdt_act},  <<16#68, 4, 16#13, 0, 0, 0>>),
    check({u, stopdt_con},  <<16#68, 4, 16#23, 0, 0, 0>>),
    check({u, testfr_act},  <<16#68, 4, 16#43, 0, 0, 0>>),
    check({u, testfr_con},  <<16#68, 4, 16#83, 0, 0, 0>>).

%%%===================================================================
%%% Stream framing
%%%===================================================================

decode_incomplete_test() ->
    ?assertEqual({incomplete, 2}, iec60870_104_apci:decode(<<>>)),
    ?assertEqual({incomplete, 1}, iec60870_104_apci:decode(<<16#68>>)),
    ?assertEqual({incomplete, 4}, iec60870_104_apci:decode(<<16#68, 4>>)),
    ?assertEqual({incomplete, 1},
                 iec60870_104_apci:decode(<<16#68, 4, 16#07, 0, 0>>)).

decode_trailing_bytes_returned_test() ->
    Bin = <<16#68, 7, 2, 0, 4, 0, 1, 2, 3, 16#FF, 16#EE>>,
    ?assertEqual({ok, {i, 1, 2, <<1, 2, 3>>}, <<16#FF, 16#EE>>},
                 iec60870_104_apci:decode(Bin)).

decode_two_frames_test() ->
    Bin = <<(iec60870_104_apci:encode({u, startdt_act}))/binary,
            (iec60870_104_apci:encode({s, 3}))/binary>>,
    {ok, F1, Rest1} = iec60870_104_apci:decode(Bin),
    {ok, F2, Rest2} = iec60870_104_apci:decode(Rest1),
    ?assertEqual({u, startdt_act}, F1),
    ?assertEqual({s, 3}, F2),
    ?assertEqual(<<>>, Rest2).

decode_bad_start_test() ->
    ?assertEqual({error, {bad_start, 16#69}},
                 iec60870_104_apci:decode(<<16#69, 4, 16#07, 0, 0, 0>>)).

decode_bad_length_test() ->
    ?assertEqual({error, {bad_length, 3}},
                 iec60870_104_apci:decode(<<16#68, 3, 0, 0, 0, 0>>)).

decode_bad_control_test() ->
    %% CF1 bits1..0 = 11 (U-format) but no function bit set.
    ?assertEqual({error, {bad_control, 16#03}},
                 iec60870_104_apci:decode(<<16#68, 4, 16#03, 0, 0, 0>>)).

encode_asdu_too_large_test() ->
    ?assertError({asdu_too_large, 250},
                 iec60870_104_apci:encode({i, 0, 0, <<0:(250 * 8)>>})).

%%%===================================================================
%%% Properties
%%%===================================================================

roundtrip_test_() ->
    {timeout, 60, ?_assert(qc(prop_roundtrip(), 500))}.

seq_succ_cycles_test_() ->
    {timeout, 60, ?_assert(qc(prop_seq_succ_cycles(), 300))}.

seq_sub_add_test_() ->
    {timeout, 60, ?_assert(qc(prop_seq_sub_add(), 1000))}.

seq_in_window_test_() ->
    {timeout, 60, ?_assert(qc(prop_seq_in_window(), 200))}.

%% decode peels exactly one APDU and returns whatever followed it verbatim.
prop_roundtrip() ->
    ?FORALL({Frame, Trailing}, {frame_gen(), binary()},
            begin
                Bin = iec60870_104_apci:encode(Frame),
                ?WHENFAIL(
                   io:format("frame=~p bin=~p~n", [Frame, Bin]),
                   {ok, Frame, Trailing} =:=
                       iec60870_104_apci:decode(<<Bin/binary, Trailing/binary>>))
            end).

prop_seq_succ_cycles() ->
    ?FORALL(N, seq_gen(),
            N =:= lists:foldl(fun(_, Acc) -> iec60870_104_apci:seq_succ(Acc) end,
                              N, lists:seq(1, 32768))).

prop_seq_sub_add() ->
    ?FORALL({N, D}, {seq_gen(), seq_gen()},
            D =:= iec60870_104_apci:seq_sub(iec60870_104_apci:seq_add(N, D), N)).

%% Every offset up to Len is inside the window [Lo, Lo+Len]; the next one is not.
prop_seq_in_window() ->
    ?FORALL({Lo, Len}, {seq_gen(), range(0, 4000)},
            begin
                Hi = iec60870_104_apci:seq_add(Lo, Len),
                AllIn = lists:all(
                          fun(D) ->
                                  iec60870_104_apci:seq_in_window(
                                    iec60870_104_apci:seq_add(Lo, D), Lo, Hi)
                          end, lists:seq(0, Len)),
                AllIn andalso
                    not iec60870_104_apci:seq_in_window(
                          iec60870_104_apci:seq_add(Lo, Len + 1), Lo, Hi)
            end).

%%%===================================================================
%%% Generators / helpers
%%%===================================================================

frame_gen() ->
    oneof([?LET({NS, NR, A}, {seq_gen(), seq_gen(), asdu_bin_gen()},
                {i, NS, NR, A}),
           ?LET(NR, seq_gen(), {s, NR}),
           ?LET(F, oneof([startdt_act, startdt_con, stopdt_act, stopdt_con,
                          testfr_act, testfr_con]),
                {u, F})]).

seq_gen() -> range(0, 32767).

asdu_bin_gen() -> ?LET(Sz, range(0, 249), binary(Sz)).

qc(Prop, N) ->
    proper:quickcheck(Prop, [{numtests, N}, {to_file, user}]).

check(Frame, Bin) ->
    ?assertEqual(Bin, iec60870_104_apci:encode(Frame)),
    ?assertEqual({ok, Frame, <<>>}, iec60870_104_apci:decode(Bin)).
