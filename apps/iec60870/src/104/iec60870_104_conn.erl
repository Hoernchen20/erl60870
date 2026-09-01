%%% @doc IEC 60870-5-104 connection — one `gen_statem' per accepted socket
%%% (docs/DESIGN.md section 4).
%%%
%%% Runs the APCI protocol machinery: the STARTDT / STOPDT / TESTFR handshake,
%%% the `k' / `w' flow-control window, the `t1' / `t2' / `t3' timers and the
%%% 15-bit send/receive sequence numbers. Decoded ASDUs are handed to an owner
%%% process and ASDUs to transmit are taken from it — see {@type owner_msg()}
%%% and {@link send_asdu/2}.
%%%
%%% States:
%%% <ul>
%%%   <li>`connected' — socket up, data transfer stopped (STOPDT state). t3
%%%       supervises the idle link; incoming I-frames are a protocol error.</li>
%%%   <li>`active' — STARTDT completed, I/S-frames flow.</li>
%%% </ul>
%%%
%%% The `active_standby' state of docs/DESIGN.md section 4 (a connection parked
%%% by its redundancy group) arrives with phase 5.
%%%
%%% This module is the `ranch_protocol' callback; {@link iec60870_104_listener}
%%% wires it to a listening socket. The `owner' listener option is either a
%%% static pid (phase 2-4 style, and direct embedding) or a
%%% `fun((PeerIp) -> {ok, pid()} | {error, term()})' resolved once per socket
%%% just after `ranch:handshake' — that is how phase 5 assigns each connection
%%% to its {@link iec60870_rgroup} by peer address.
-module(iec60870_104_conn).
-behaviour(gen_statem).
-behaviour(ranch_protocol).

-include_lib("iec60870/include/iec60870_asdu.hrl").

%% ranch_protocol
-export([start_link/3]).
%% owner API
-export([send_asdu/2, send_asdu/3, stop/1]).
%% gen_statem
-export([init/1, callback_mode/0, handle_event/4, terminate/3, code_change/4]).

-export_type([params/0, owner_msg/0, closed_reason/0]).

-type params() :: #{k := 1..32767, w := 1..32767,
                    t1 := pos_integer(), t2 := pos_integer(), t3 := pos_integer(),
                    max_outbox := pos_integer(),
                    cot_size := 1..2, coa_size := 1..2, ioa_size := 1..3}.

-type closed_reason() :: t1_timeout
                       | peer_closed
                       | {socket_error, term()}
                       | {protocol_error, term()}.

%% Messages the owner receives, all shaped `{iec60870, ConnPid, Payload}':
-type owner_msg() ::
        {iec60870, pid(), activated}
      | {iec60870, pid(), deactivated}
      | {iec60870, pid(), {asdu, #asdu{}}}
      | {iec60870, pid(), {released, non_neg_integer()}}
      | {iec60870, pid(), {decode_error, iec60870_asdu:decode_error()}}
      | {iec60870, pid(), {outbox_overflow, non_neg_integer()}}
      | {iec60870, pid(), {closed, closed_reason()}}.

%% An opaque per-ASDU tag supplied to {@link send_asdu/3}: the sender's own
%% identifier (the redundancy group passes its buffer index), echoed back in a
%% `{released, Tag}' owner message once the peer acknowledges the I-frame that
%% carried it. `undefined' (from {@link send_asdu/2}) is never echoed.
-type send_tag() :: non_neg_integer() | undefined.
-export_type([send_tag/0]).

-define(DEFAULT_PARAMS,
        #{k => 12, w => 8,
          t1 => 15000, t2 => 10000, t3 => 20000,
          max_outbox => 1000,
          cot_size => 2, coa_size => 2, ioa_size => 3}).

-record(data, {
    transport                :: module(),
    socket                   :: term(),
    ok_tag                   :: atom(),
    closed_tag               :: atom(),
    error_tag                :: atom(),
    owner                    :: pid(),
    owner_mon                :: reference(),
    params                   :: params(),
    asdu_opts                :: iec60870_asdu:opts(),
    buf = <<>>               :: binary(),
    %% V(S): sequence number the next sent I-frame will carry.
    vs = 0                   :: iec60870_104_apci:seq(),
    %% V(R): sequence number expected on the next received I-frame.
    vr = 0                   :: iec60870_104_apci:seq(),
    %% oldest sent I-frame not yet acknowledged by the peer (== vs when idle).
    ack = 0                  :: iec60870_104_apci:seq(),
    %% highest V(R) already confirmed to the peer via an S- or I-frame.
    acked_vr = 0             :: iec60870_104_apci:seq(),
    %% received I-frames since we last sent an acknowledgement (drives w / t2).
    recv_since_ack = 0       :: non_neg_integer(),
    %% sent-but-unacknowledged I-frames: {seq, monotonic ms when sent, send_tag()}
    %% (drives t1; the tag drives `{released, _}' owner notifications).
    sent = queue:new()       :: queue:queue({iec60870_104_apci:seq(), integer(),
                                             send_tag()}),
    %% ASDUs waiting on the k window or on STARTDT, each with its send_tag().
    outbox = queue:new()     :: queue:queue({#asdu{}, send_tag()}),
    outbox_len = 0           :: non_neg_integer(),
    %% false | monotonic ms when we sent an unanswered TESTFR_ACT.
    testfr_pending = false   :: false | integer(),
    %% true between STOPDT_ACT and draining the last outstanding I-frame.
    stopping = false         :: boolean()
}).

%%%===================================================================
%%% ranch_protocol / owner API
%%%===================================================================

-spec start_link(ranch:ref(), module(), map()) -> {ok, pid()}.
start_link(Ref, Transport, ProtoOpts) ->
    {ok, proc_lib:spawn_link(?MODULE, init, [{Ref, Transport, ProtoOpts}])}.

%% @doc Queue an ASDU for transmission. It leaves as an I-frame once the
%% connection is `active' and the `k' window has room; otherwise it waits.
-spec send_asdu(gen_statem:server_ref(), #asdu{}) -> ok.
send_asdu(Conn, #asdu{} = Asdu) ->
    send_asdu(Conn, Asdu, undefined).

%% @doc As {@link send_asdu/2}, but tag the ASDU: once the peer acknowledges the
%% I-frame that carries it the owner is sent `{iec60870, ConnPid, {released,
%% Tag}}'. The redundancy group uses this to release its event buffer.
-spec send_asdu(gen_statem:server_ref(), #asdu{}, send_tag()) -> ok.
send_asdu(Conn, #asdu{} = Asdu, Tag) ->
    gen_statem:cast(Conn, {send_asdu, Asdu, Tag}).

%% @doc Close the connection without notifying the owner (the owner asked).
-spec stop(gen_statem:server_ref()) -> ok.
stop(Conn) ->
    gen_statem:cast(Conn, stop).

%%%===================================================================
%%% gen_statem
%%%===================================================================

-spec init({ranch:ref(), module(), map()}) -> no_return().
init({Ref, Transport, ProtoOpts}) ->
    {ok, Socket} = ranch:handshake(Ref),
    Owner = resolve_owner(maps:get(owner, ProtoOpts), Transport, Socket),
    Mon = monitor(process, Owner),
    Params = validate_params(
               maps:merge(?DEFAULT_PARAMS, maps:get(params, ProtoOpts, #{}))),
    {OkT, ClosedT, ErrT} = msg_tags(Transport:messages()),
    ok = Transport:setopts(Socket, [{active, once}]),
    Data = #data{transport = Transport, socket = Socket,
                 ok_tag = OkT, closed_tag = ClosedT, error_tag = ErrT,
                 owner = Owner, owner_mon = Mon,
                 params = Params,
                 asdu_opts = maps:with([cot_size, coa_size, ioa_size], Params)},
    gen_statem:enter_loop(?MODULE, [], connected, Data).

-spec callback_mode() -> gen_statem:callback_mode_result().
callback_mode() ->
    [handle_event_function, state_enter].

%% A static pid is the owner directly (phase 2-4 style, direct embedding); a
%% 1-arity fun is resolved against the peer IP (phase 5 group assignment).
resolve_owner(Pid, _Transport, _Socket) when is_pid(Pid) ->
    Pid;
resolve_owner(Fun, Transport, Socket) when is_function(Fun, 1) ->
    {ok, {PeerIp, _Port}} = Transport:peername(Socket),
    case Fun(PeerIp) of
        {ok, Pid} when is_pid(Pid) ->
            Pid;
        Other ->
            _ = Transport:close(Socket),
            exit({owner_resolution_failed, Other})
    end.

%%%-------------------------------------------------------------------
%%% state enter
%%%-------------------------------------------------------------------

handle_event(enter, OldState, connected, Data0) ->
    Data = Data0#data{recv_since_ack = 0},
    case OldState of
        active -> notify(Data, deactivated);
        _ -> ok
    end,
    {keep_state, Data, [arm_t3(Data)]};
handle_event(enter, _OldState, active, Data0) ->
    notify(Data0, activated),
    Data = drain_outbox(Data0#data{recv_since_ack = 0, stopping = false}),
    {keep_state, Data, [arm_t3(Data), t1_action(Data)]};

%%%-------------------------------------------------------------------
%%% socket input
%%%-------------------------------------------------------------------

handle_event(info, {OkT, Sock, Bin}, _State,
             #data{ok_tag = OkT, socket = Sock, transport = T, buf = Buf} = Data0) ->
    _ = T:setopts(Sock, [{active, once}]),
    Data = Data0#data{buf = <<Buf/binary, Bin/binary>>},
    {keep_state, Data, [{next_event, internal, parse}, arm_t3(Data)]};
handle_event(info, {ClosedT, Sock}, _State,
             #data{closed_tag = ClosedT, socket = Sock} = Data) ->
    close(Data, peer_closed);
handle_event(info, {ErrT, Sock, Reason}, _State,
             #data{error_tag = ErrT, socket = Sock} = Data) ->
    close(Data, {socket_error, Reason});
handle_event(info, {'DOWN', Mon, process, _Pid, _Reason}, _State,
             #data{owner_mon = Mon}) ->
    {stop, normal};
handle_event(info, _Msg, _State, _Data) ->
    keep_state_and_data;

%%%-------------------------------------------------------------------
%%% frame parsing + dispatch
%%%-------------------------------------------------------------------

handle_event(internal, parse, _State, #data{buf = Buf} = Data) ->
    case parse_all(Buf, []) of
        {ok, Frames, Rest} ->
            {keep_state, Data#data{buf = Rest},
             [{next_event, internal, {frame, F}} || F <- Frames]};
        {error, Reason} ->
            close(Data, {protocol_error, Reason})
    end;
handle_event(internal, {frame, Frame}, State, Data) ->
    handle_frame(Frame, State, Data);

%%%-------------------------------------------------------------------
%%% timers
%%%-------------------------------------------------------------------

handle_event({timeout, t1}, t1, _State,
             #data{sent = Sent, testfr_pending = TP} = Data) ->
    case queue:is_empty(Sent) andalso TP =:= false of
        true -> keep_state_and_data;
        false -> close(Data, t1_timeout)
    end;
handle_event({timeout, t2}, t2, _State, #data{recv_since_ack = 0}) ->
    keep_state_and_data;
handle_event({timeout, t2}, t2, _State, Data) ->
    {keep_state, send_ack(Data)};
handle_event({timeout, t3}, t3, _State, Data0) ->
    Data = send_frame(Data0#data{testfr_pending = now_ms()}, {u, testfr_act}),
    {keep_state, Data, [arm_t3(Data), t1_action(Data)]};

%%%-------------------------------------------------------------------
%%% owner casts
%%%-------------------------------------------------------------------

handle_event(cast, {send_asdu, Asdu, Tag}, active, #data{stopping = false} = Data0) ->
    case window_open(Data0) of
        true ->
            Data = transmit_i(Asdu, Tag, Data0),
            {keep_state, Data, [t1_action(Data), {{timeout, t2}, cancel}]};
        false ->
            {keep_state, enqueue(Asdu, Tag, Data0)}
    end;
handle_event(cast, {send_asdu, Asdu, Tag}, _State, Data0) ->
    {keep_state, enqueue(Asdu, Tag, Data0)};
handle_event(cast, stop, _State, _Data) ->
    {stop, normal};

handle_event(_Type, _Event, _State, _Data) ->
    keep_state_and_data.

-spec terminate(term(), term(), #data{} | term()) -> ok.
terminate(_Reason, _State, #data{transport = T, socket = S}) ->
    _ = T:close(S),
    ok;
terminate(_Reason, _State, _Data) ->
    ok.

-spec code_change(term(), State, Data, term()) -> {ok, State, Data}.
code_change(_Vsn, State, Data, _Extra) ->
    {ok, State, Data}.

%%%===================================================================
%%% Frame handling
%%%===================================================================

handle_frame({u, startdt_act}, connected, Data) ->
    {next_state, active, send_frame(Data, {u, startdt_con})};
handle_frame({u, stopdt_act}, connected, Data) ->
    {keep_state, send_frame(Data, {u, stopdt_con})};
handle_frame({u, testfr_act}, connected, Data) ->
    {keep_state, send_frame(Data, {u, testfr_con})};
handle_frame({u, testfr_con}, _State, Data0) ->
    Data = Data0#data{testfr_pending = false},
    {keep_state, Data, [t1_action(Data)]};
handle_frame({u, _}, connected, _Data) ->
    %% STARTDT_CON / STOPDT_CON — the server never sent the matching act.
    keep_state_and_data;
handle_frame({s, _NR}, connected, _Data) ->
    keep_state_and_data;
handle_frame({i, _NS, _NR, _Bin}, connected, Data) ->
    close(Data, {protocol_error, i_frame_while_stopped});

handle_frame({i, NS, NR, Bin}, active, Data) ->
    handle_i(NS, NR, Bin, Data);
handle_frame({s, NR}, active, Data) ->
    handle_s(NR, Data);
handle_frame({u, startdt_act}, active, Data) ->
    {keep_state, send_frame(Data, {u, startdt_con})};
handle_frame({u, stopdt_act}, active, Data) ->
    handle_stopdt(Data);
handle_frame({u, testfr_act}, active, Data) ->
    {keep_state, send_frame(Data, {u, testfr_con})};
handle_frame({u, _}, active, _Data) ->
    keep_state_and_data.

handle_i(NS, NR, Bin, #data{vr = Vr, ack = Ack, vs = Vs} = Data0) ->
    case NS =:= Vr andalso iec60870_104_apci:seq_in_window(NR, Ack, Vs) of
        false when NS =/= Vr ->
            close(Data0, {protocol_error, {unexpected_ns, NS, Vr}});
        false ->
            close(Data0, {protocol_error, {invalid_nr, NR}});
        true ->
            Data1 = apply_ack(NR, Data0),
            Data2 = Data1#data{vr = iec60870_104_apci:seq_succ(Vr),
                               recv_since_ack = Data1#data.recv_since_ack + 1},
            deliver_asdu(Bin, Data2),
            {Data3, AckActions} = ack_by_w(Data2),
            progress(Data3, AckActions)
    end.

handle_s(NR, #data{ack = Ack, vs = Vs} = Data0) ->
    case iec60870_104_apci:seq_in_window(NR, Ack, Vs) of
        false -> close(Data0, {protocol_error, {invalid_nr, NR}});
        true -> progress(apply_ack(NR, Data0), [])
    end.

handle_stopdt(#data{sent = Sent} = Data) ->
    case queue:is_empty(Sent) of
        true -> {next_state, connected, send_frame(Data, {u, stopdt_con})};
        false -> {keep_state, Data#data{stopping = true}}
    end.

%% Continue after a received frame: honour a pending STOPDT once the last
%% outstanding I-frame is acknowledged, and (re)arm t1.
progress(#data{stopping = true, sent = Sent} = Data, Extra) ->
    case queue:is_empty(Sent) of
        true ->
            Data1 = send_frame(Data#data{stopping = false}, {u, stopdt_con}),
            {next_state, connected, Data1, [t1_action(Data1) | Extra]};
        false ->
            {keep_state, Data, [t1_action(Data) | Extra]}
    end;
progress(Data, Extra) ->
    {keep_state, Data, [t1_action(Data) | Extra]}.

%%%===================================================================
%%% Acknowledgement bookkeeping
%%%===================================================================

%% Apply a received N(R): drop the I-frames it acknowledges, advance `ack',
%% tell the owner about any tagged ASDUs now released, and use the freed window
%% to drain the outbox.
apply_ack(NR, #data{sent = Sent} = Data0) ->
    {Sent1, Tags} = drop_acked(Sent, NR, []),
    Data = notify_released(Tags, Data0),
    drain_outbox(Data#data{sent = Sent1, ack = NR}).

drop_acked(Sent, NR, Tags) ->
    case queue:peek(Sent) of
        {value, {Seq, _Ts, _Tag}} when Seq =:= NR -> {Sent, lists:reverse(Tags)};
        {value, {_Seq, _Ts, Tag}} -> drop_acked(queue:drop(Sent), NR, [Tag | Tags]);
        empty -> {Sent, lists:reverse(Tags)}
    end.

%% Indices are monotonic, so the highest released tag implies all the lower
%% ones — one `{released, _}' message per acknowledgement is enough.
notify_released(Tags, Data) ->
    case [T || T <- Tags, T =/= undefined] of
        [] -> Data;
        Idxs -> notify(Data, {released, lists:max(Idxs)}), Data
    end.

%% Send an S-frame now if `w' received I-frames are unacknowledged, else make
%% sure t2 is running so the acknowledgement goes out in time.
ack_by_w(#data{recv_since_ack = N, params = #{w := W}} = Data) when N >= W ->
    {send_ack(Data), [{{timeout, t2}, cancel}]};
ack_by_w(#data{recv_since_ack = 1, params = #{t2 := T2}} = Data) ->
    {Data, [{{timeout, t2}, T2, t2}]};
ack_by_w(Data) ->
    {Data, []}.

send_ack(#data{vr = Vr} = Data) ->
    (send_frame(Data, {s, Vr}))#data{acked_vr = Vr, recv_since_ack = 0}.

%%%===================================================================
%%% Transmission
%%%===================================================================

window_open(#data{vs = Vs, ack = Ack, params = #{k := K}}) ->
    iec60870_104_apci:seq_sub(Vs, Ack) < K.

drain_outbox(#data{stopping = true} = Data) ->
    Data;
drain_outbox(#data{outbox_len = 0} = Data) ->
    Data;
drain_outbox(#data{outbox = Q, outbox_len = N} = Data) ->
    case window_open(Data) of
        true ->
            {{value, {Asdu, Tag}}, Q1} = queue:out(Q),
            drain_outbox(transmit_i(Asdu, Tag, Data#data{outbox = Q1, outbox_len = N - 1}));
        false ->
            Data
    end.

transmit_i(Asdu, Tag, #data{vs = Vs, vr = Vr, sent = Sent, asdu_opts = Opts} = Data) ->
    Bin = iec60870_asdu:encode(Asdu, Opts),
    Data1 = send_frame(Data, {i, Vs, Vr, Bin}),
    Data1#data{vs = iec60870_104_apci:seq_succ(Vs),
               sent = queue:in({Vs, now_ms(), Tag}, Sent),
               acked_vr = Vr, recv_since_ack = 0}.

enqueue(Asdu, Tag, #data{outbox = Q, outbox_len = N, params = #{max_outbox := Max}} = Data) ->
    case N >= Max of
        true ->
            notify(Data, {outbox_overflow, N}),
            Data#data{outbox = queue:in({Asdu, Tag}, queue:drop(Q))};
        false ->
            Data#data{outbox = queue:in({Asdu, Tag}, Q), outbox_len = N + 1}
    end.

send_frame(#data{transport = T, socket = S} = Data, Frame) ->
    _ = T:send(S, iec60870_104_apci:encode(Frame)),
    Data.

deliver_asdu(Bin, #data{asdu_opts = Opts} = Data) ->
    case iec60870_asdu:decode(Bin, Opts) of
        {ok, Asdu, _Rest} -> notify(Data, {asdu, Asdu});
        {error, Reason} -> notify(Data, {decode_error, Reason})
    end.

%%%===================================================================
%%% Timers, teardown, helpers
%%%===================================================================

arm_t3(#data{params = #{t3 := T3}}) ->
    {{timeout, t3}, T3, t3}.

%% t1 is anchored to the oldest outstanding item (an unacknowledged I-frame or
%% an unanswered TESTFR_ACT), never reset by newer traffic; cancelled when
%% nothing is outstanding.
t1_action(#data{sent = Sent, testfr_pending = TP, params = #{t1 := T1}}) ->
    case earliest_pending(Sent, TP) of
        none -> {{timeout, t1}, cancel};
        Ts -> {{timeout, t1}, max(0, T1 - (now_ms() - Ts)), t1}
    end.

earliest_pending(Sent, TP) ->
    TsList = [Ts || Ts <- [TP], is_integer(Ts)] ++
        case queue:peek(Sent) of
            {value, {_Seq, Ts, _Tag}} -> [Ts];
            empty -> []
        end,
    case TsList of
        [] -> none;
        _ -> lists:min(TsList)
    end.

close(#data{transport = T, socket = S} = Data, Reason) ->
    notify(Data, {closed, Reason}),
    _ = T:close(S),
    {stop, normal}.

notify(#data{owner = Owner}, Payload) ->
    Owner ! {iec60870, self(), Payload},
    ok.

parse_all(Buf, Acc) ->
    case iec60870_104_apci:decode(Buf) of
        {ok, Frame, Rest} -> parse_all(Rest, [Frame | Acc]);
        {incomplete, _} -> {ok, lists:reverse(Acc), Buf};
        {error, Reason} -> {error, Reason}
    end.

now_ms() ->
    erlang:monotonic_time(millisecond).

msg_tags({Ok, Closed, Error}) -> {Ok, Closed, Error};
msg_tags({Ok, Closed, Error, _Passive}) -> {Ok, Closed, Error}.

validate_params(#{k := K, w := W, t1 := T1, t2 := T2, t3 := T3,
                  max_outbox := MO} = Params) ->
    (is_integer(K) andalso K >= 1 andalso K =< 32767)
        orelse error({bad_param, {k, K}}),
    (is_integer(W) andalso W >= 1 andalso W =< (2 * K) div 3)
        orelse error({bad_param, {w, W, {k, K}}}),
    lists:all(fun(T) -> is_integer(T) andalso T > 0 end, [T1, T2, T3])
        orelse error({bad_param, {timers, {T1, T2, T3}}}),
    (T2 < T1) orelse error({bad_param, {t2_not_below_t1, {T2, T1}}}),
    (is_integer(MO) andalso MO >= 1) orelse error({bad_param, {max_outbox, MO}}),
    Params.
