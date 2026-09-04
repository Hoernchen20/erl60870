%%% IEC 60870-5-104 connection state machine, driven over a real socket:
%%% a ranch listener runs iec60870_104_conn, the suite plays the
%%% controlling station with a raw `gen_tcp' client.
-module(iec60870_104_conn_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("iec60870/include/iec60870_asdu.hrl").

-export([suite/0, all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).

-export([startdt_activates/1, server_sends_asdu/1, incoming_iframe_delivered/1,
         ack_by_window/1, ack_by_t2/1, k_window_blocks_then_drains/1,
         t1_closes_idle_unacked/1, t3_emits_testfr/1, testfr_act_answered/1,
         stopdt_deactivates/1, iframe_before_startdt_closes/1,
         unexpected_ns_closes/1]).

%% Short timers so the timing cases finish quickly.
-define(PARAMS, #{t1 => 300, t2 => 120, t3 => 500, k => 3, w => 2}).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [startdt_activates, server_sends_asdu, incoming_iframe_delivered,
     ack_by_window, ack_by_t2, k_window_blocks_then_drains,
     t1_closes_idle_unacked, t3_emits_testfr, testfr_act_answered,
     stopdt_deactivates, iframe_before_startdt_closes, unexpected_ns_closes].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(iec60870),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(TC, Config) ->
    {ok, _} = iec60870_104_listener:start(
                TC, #{owner => self(),
                      transport_opts => [{ip, {127, 0, 0, 1}}, {port, 0}],
                      params => ?PARAMS}),
    Port = iec60870_104_listener:port(TC),
    [{listener, TC}, {port, Port} | Config].

end_per_testcase(TC, _Config) ->
    _ = iec60870_104_listener:stop(TC),
    ok.

%%%===================================================================
%%% Cases
%%%===================================================================

startdt_activates(Config) ->
    S = connect(Config),
    ok = send_frame(S, {u, startdt_act}),
    {u, startdt_con} = recv_frame(S),
    _Conn = expect_activated().

server_sends_asdu(Config) ->
    S = connect(Config),
    Conn = do_startdt(S),
    Asdu = monitored_asdu(1),
    ok = iec60870_104_conn:send_asdu(Conn, Asdu),
    {i, 0, 0, Bin} = recv_frame(S),
    {ok, Asdu, <<>>} = iec60870_asdu:decode(Bin).

incoming_iframe_delivered(Config) ->
    S = connect(Config),
    Conn = do_startdt(S),
    Asdu = interrogation_asdu(),
    ok = send_frame(S, {i, 0, 0, iec60870_asdu:encode(Asdu)}),
    receive
        {iec60870, Conn, {asdu, Got}} -> Asdu = Got
    after 1000 -> ct:fail(no_asdu)
    end,
    %% single I-frame (< w) is acknowledged by t2
    {s, 1} = recv_frame(S).

ack_by_window(Config) ->
    S = connect(Config),
    _Conn = do_startdt(S),
    ok = send_frame(S, {i, 0, 0, iec60870_asdu:encode(interrogation_asdu())}),
    ok = send_frame(S, {i, 1, 0, iec60870_asdu:encode(interrogation_asdu())}),
    %% w = 2 reached -> S-frame without waiting for t2
    {s, 2} = recv_frame(S, 200).

ack_by_t2(Config) ->
    S = connect(Config),
    _Conn = do_startdt(S),
    ok = send_frame(S, {i, 0, 0, iec60870_asdu:encode(interrogation_asdu())}),
    T0 = erlang:monotonic_time(millisecond),
    {s, 1} = recv_frame(S, 1000),
    Elapsed = erlang:monotonic_time(millisecond) - T0,
    true = Elapsed >= 90.

k_window_blocks_then_drains(Config) ->
    S = connect(Config),
    Conn = do_startdt(S),
    [ok = iec60870_104_conn:send_asdu(Conn, monitored_asdu(N)) || N <- lists:seq(1, 4)],
    {i, 0, 0, _} = recv_frame(S),
    {i, 1, 0, _} = recv_frame(S),
    {i, 2, 0, _} = recv_frame(S),
    ok = expect_no_data(S, 250),
    ok = send_frame(S, {s, 3}),
    {i, 3, 0, _} = recv_frame(S).

t1_closes_idle_unacked(Config) ->
    S = connect(Config),
    Conn = do_startdt(S),
    ok = iec60870_104_conn:send_asdu(Conn, monitored_asdu(1)),
    {i, 0, 0, _} = recv_frame(S),
    receive
        {iec60870, Conn, {closed, t1_timeout}} -> ok
    after 2000 -> ct:fail(no_t1_close)
    end,
    {error, closed} = gen_tcp:recv(S, 0, 1000).

t3_emits_testfr(Config) ->
    S = connect(Config),
    {u, testfr_act} = recv_frame(S, 2000),
    ok = send_frame(S, {u, testfr_con}),
    receive
        {iec60870, _, {closed, R}} -> ct:fail({unexpected_close, R})
    after 800 -> ok
    end.

testfr_act_answered(Config) ->
    S = connect(Config),
    ok = send_frame(S, {u, testfr_act}),
    {u, testfr_con} = recv_frame(S).

stopdt_deactivates(Config) ->
    S = connect(Config),
    Conn = do_startdt(S),
    ok = send_frame(S, {u, stopdt_act}),
    {u, stopdt_con} = recv_frame(S),
    receive
        {iec60870, Conn, deactivated} -> ok
    after 1000 -> ct:fail(no_deactivated)
    end.

iframe_before_startdt_closes(Config) ->
    S = connect(Config),
    ok = send_frame(S, {i, 0, 0, iec60870_asdu:encode(interrogation_asdu())}),
    receive
        {iec60870, _, {closed, {protocol_error, i_frame_while_stopped}}} -> ok
    after 1000 -> ct:fail(no_close)
    end,
    {error, closed} = gen_tcp:recv(S, 0, 1000).

unexpected_ns_closes(Config) ->
    S = connect(Config),
    Conn = do_startdt(S),
    ok = send_frame(S, {i, 5, 0, iec60870_asdu:encode(interrogation_asdu())}),
    receive
        {iec60870, Conn, {closed, {protocol_error, {unexpected_ns, 5, 0}}}} -> ok
    after 1000 -> ct:fail(no_close)
    end.

%%%===================================================================
%%% Helpers
%%%===================================================================

connect(Config) ->
    Port = ?config(port, Config),
    {ok, S} = gen_tcp:connect({127, 0, 0, 1}, Port,
                              [binary, {active, false}, {packet, 0}], 1000),
    S.

do_startdt(S) ->
    ok = send_frame(S, {u, startdt_act}),
    {u, startdt_con} = recv_frame(S),
    expect_activated().

expect_activated() ->
    receive
        {iec60870, Conn, activated} -> Conn
    after 1000 -> ct:fail(no_activated)
    end.

send_frame(S, Frame) ->
    gen_tcp:send(S, iec60870_104_apci:encode(Frame)).

recv_frame(S) -> recv_frame(S, 2000).

recv_frame(S, Timeout) ->
    {ok, <<16#68, Len>>} = gen_tcp:recv(S, 2, Timeout),
    {ok, Body} = gen_tcp:recv(S, Len, Timeout),
    {ok, Frame, <<>>} = iec60870_104_apci:decode(<<16#68, Len, Body/binary>>),
    Frame.

expect_no_data(S, Timeout) ->
    case gen_tcp:recv(S, 0, Timeout) of
        {error, timeout} -> ok;
        {ok, Data} -> ct:fail({unexpected_data, Data})
    end.

monitored_asdu(Ioa) ->
    #asdu{type = m_sp_na_1, cot = spontaneous, coa = 1,
          objects = [#object{ioa = Ioa, value = true, quality = []}]}.

interrogation_asdu() ->
    #asdu{type = c_ic_na_1, cot = act, coa = 1,
          objects = [#object{ioa = 0, value = 20}]}.
