%%% @doc Redundancy group — one `gen_statem' per group (docs/DESIGN.md
%%% section 5).
%%%
%%% A group owns a set of member {@link iec60870_104_conn} connections (it is
%%% their `owner'), at most one of which is the group's <em>active</em>
%%% connection — the one fed spontaneous / low-level traffic. It keeps an
%%% ordered, bounded buffer of ASDUs awaiting transmission, each with a
%%% monotonic index:
%%%
%%% <ul>
%%%   <li>{@link enqueue/2} appends an ASDU; with an active connection it also
%%%       goes out immediately (tagged with its index).</li>
%%%   <li>`{released, Index}' from the active connection (the peer acknowledged
%%%       the I-frame) drops every buffer entry up to `Index'.</li>
%%%   <li>on promotion of a new active connection, transmission resumes from the
%%%       last released index — sent-but-unacknowledged ASDUs are repeated.
%%%       Duplicates on the wire during switchover are expected.</li>
%%%   <li>with no active connection, events accumulate up to the bound
%%%       (drop-oldest on overflow).</li>
%%% </ul>
%%%
%%% Arbitration: when a member enters `active' (STARTDT) while another member is
%%% already the active one, the group simply promotes the newcomer — the former
%%% active connection stays open and keeps answering its own direct requests,
%%% it is just no longer fed group traffic (the `active_standby' of
%%% docs/DESIGN.md section 4 is tracked here, not as a connection state).
%%%
%%% Incoming ASDUs and connection lifecycle events (including `activated' /
%%% `deactivated', docs/DESIGN.md section 7's `connection_event/2') are
%%% relayed to the owning {@link iec60870_server_ctl}, looked up as
%%% `{ctl, Name}' in {@link iec60870_registry}. `activated' specifically is
%%% relayed *synchronously* ({@link iec60870_server_ctl:relay_sync/3}) so the
%%% control process's own direct send to the newly-active connection (end of
%%% initialization) cannot be overtaken by this module's own buffer replay to
%%% that same connection just below.
-module(iec60870_rgroup).
-behaviour(gen_statem).

-include_lib("iec60870/include/iec60870_asdu.hrl").

-export([start_link/3]).
-export([add_member/2, enqueue/2, info/1]).
-export([match/3]).
-export([init/1, callback_mode/0, handle_event/4, terminate/3, code_change/4]).

-export_type([opts/0]).

-type opts() :: #{buffer_max => pos_integer(),
                  ephemeral => boolean(),
                  initial_member => pid()}.

-record(data, {
    id                          :: term(),
    name                        :: term(),
    buffer_max = 1000           :: pos_integer(),
    %% `connection'-mode groups are 1:1 with a connection and stop when it goes.
    ephemeral = false           :: boolean(),
    members = #{}               :: #{pid() => reference()},
    buffer = queue:new()        :: queue:queue({pos_integer(), #asdu{}}),
    buffer_len = 0             :: non_neg_integer(),
    next_index = 1             :: pos_integer(),
    %% highest index dropped from the buffer (acknowledged or forced out).
    released = 0               :: non_neg_integer(),
    %% highest index handed to the current active connection.
    sent = 0                  :: non_neg_integer()
}).

%% State: `no_active' | `{active, ConnPid}'.
-type state() :: no_active | {active, pid()}.

%%%===================================================================
%%% API
%%%===================================================================

-spec start_link(term(), opts(), term()) -> gen_statem:start_ret().
start_link(Id, Opts, Name) ->
    gen_statem:start_link(?MODULE, {Id, Opts, Name}, []).

%% @doc Register `ConnPid' as a member of the group. Idempotent.
-spec add_member(gen_statem:server_ref(), pid()) -> ok.
add_member(Group, ConnPid) when is_pid(ConnPid) ->
    gen_statem:call(Group, {add_member, ConnPid}).

%% @doc Append an ASDU to the group's event buffer (and send it now if a
%% connection is active).
-spec enqueue(gen_statem:server_ref(), #asdu{}) -> ok.
enqueue(Group, #asdu{} = Asdu) ->
    gen_statem:cast(Group, {enqueue, Asdu}).

%% @doc A snapshot of the group's state — for tests and debugging.
-spec info(gen_statem:server_ref()) -> map().
info(Group) ->
    gen_statem:call(Group, info).

%%%===================================================================
%%% gen_statem
%%%===================================================================

-spec init({term(), opts(), term()}) -> {ok, state(), #data{}}.
init({Id, Opts, Name}) ->
    Data0 = #data{id = Id, name = Name,
                  buffer_max = maps:get(buffer_max, Opts, 1000),
                  ephemeral = maps:get(ephemeral, Opts, false)},
    Data = case maps:get(initial_member, Opts, undefined) of
               Pid when is_pid(Pid) -> add_member_data(Pid, Data0);
               undefined -> Data0
           end,
    {ok, no_active, Data}.

-spec callback_mode() -> gen_statem:callback_mode_result().
callback_mode() ->
    handle_event_function.

%%%-------------------------------------------------------------------
%%% calls
%%%-------------------------------------------------------------------

handle_event({call, From}, {add_member, Pid}, _State, Data) ->
    {keep_state, add_member_data(Pid, Data), [{reply, From, ok}]};
handle_event({call, From}, info, State, Data) ->
    Reply = #{state => State,
              members => maps:keys(Data#data.members),
              buffer_len => Data#data.buffer_len,
              next_index => Data#data.next_index,
              released => Data#data.released,
              sent => Data#data.sent},
    {keep_state_and_data, [{reply, From, Reply}]};

%%%-------------------------------------------------------------------
%%% enqueue
%%%-------------------------------------------------------------------

handle_event(cast, {enqueue, Asdu}, no_active, Data) ->
    {keep_state, push_buffer(Asdu, Data)};
handle_event(cast, {enqueue, Asdu}, {active, Conn}, Data) ->
    {keep_state, flush_new(Conn, push_buffer(Asdu, Data))};

%%%-------------------------------------------------------------------
%%% owner messages from member connections
%%%-------------------------------------------------------------------

handle_event(info, {iec60870, Conn, activated}, State, Data) ->
    case is_member(Conn, Data) of
        false ->
            keep_state_and_data;
        true ->
            %% synchronous: must return before the replay below, so the
            %% control process's own direct send (end of initialization) to
            %% `Conn' cannot be overtaken by it on the wire (see relay_sync/3).
            _ = relay_sync(activated, Conn, Data),
            case State of
                {active, Conn} -> keep_state_and_data;
                _ -> {next_state, {active, Conn}, replay(Conn, Data)}
            end
    end;

handle_event(info, {iec60870, Conn, deactivated}, {active, Conn}, Data) ->
    _ = relay(deactivated, Conn, Data),
    {next_state, no_active, Data};
handle_event(info, {iec60870, Conn, deactivated}, _State, Data) ->
    _ = relay(deactivated, Conn, Data),
    keep_state_and_data;

handle_event(info, {iec60870, Conn, {released, Index}}, {active, Conn}, Data) ->
    {keep_state, drop_released(Index, Data)};
handle_event(info, {iec60870, _Conn, {released, _Index}}, _State, _Data) ->
    keep_state_and_data;

handle_event(info, {iec60870, Conn, {asdu, _} = Payload}, _State, Data) ->
    _ = relay(Payload, Conn, Data),
    keep_state_and_data;
handle_event(info, {iec60870, Conn, {decode_error, _} = Payload}, _State, Data) ->
    _ = relay(Payload, Conn, Data),
    keep_state_and_data;
handle_event(info, {iec60870, Conn, {outbox_overflow, _} = Payload}, _State, Data) ->
    _ = relay(Payload, Conn, Data),
    keep_state_and_data;

handle_event(info, {iec60870, Conn, {closed, Reason}}, State, Data) ->
    conn_gone(Conn, {closed, Reason}, State, Data);
handle_event(info, {'DOWN', Mon, process, Pid, Reason}, State, Data) ->
    case Data#data.members of
        #{Pid := Mon} -> conn_gone(Pid, {closed, {down, Reason}}, State, Data);
        _ -> keep_state_and_data
    end;

handle_event(_EventType, _Event, _State, _Data) ->
    keep_state_and_data.

-spec terminate(term(), state(), #data{}) -> ok.
terminate(_Reason, _State, _Data) ->
    ok.

-spec code_change(term(), State, Data, term()) -> {ok, State, Data}.
code_change(_Vsn, State, Data, _Extra) ->
    {ok, State, Data}.

%%%===================================================================
%%% Membership
%%%===================================================================

add_member_data(Pid, #data{members = Members} = Data) ->
    case Members of
        #{Pid := _} ->
            Data;
        _ ->
            Mon = monitor(process, Pid),
            Data#data{members = Members#{Pid => Mon}}
    end.

is_member(Pid, #data{members = Members}) ->
    maps:is_key(Pid, Members).

%% A member connection is gone: relay it up (once — guarded on still being a
%% member, so a `{closed, _}' and a `DOWN' for the same pid don't double-fire),
%% drop it, and stop an emptied ephemeral group.
conn_gone(Conn, RelayPayload, State, #data{members = Members} = Data) ->
    case maps:take(Conn, Members) of
        error ->
            keep_state_and_data;
        {Mon, Rest} ->
            _ = demonitor(Mon, [flush]),
            _ = relay(RelayPayload, Conn, Data),
            Data1 = Data#data{members = Rest},
            NextState = case State of
                            {active, Conn} -> no_active;
                            _ -> State
                        end,
            case Data1#data.ephemeral andalso map_size(Rest) =:= 0 of
                true -> {stop, normal, Data1};
                false -> {next_state, NextState, Data1}
            end
    end.

%%%===================================================================
%%% Event buffer
%%%===================================================================

push_buffer(Asdu, #data{buffer = Q, buffer_len = N, buffer_max = Max,
                        next_index = Ix, released = Rel,
                        name = Name, id = Id} = Data) ->
    Entry = {Ix, Asdu},
    case N >= Max of
        true ->
            {{value, {DropIx, _}}, Q1} = queue:out(Q),
            logger:warning("iec60870 rgroup ~p/~p: event buffer full (~p), "
                           "dropping oldest (index ~p)", [Name, Id, Max, DropIx]),
            Data#data{buffer = queue:in(Entry, Q1), next_index = Ix + 1,
                      released = max(Rel, DropIx)};
        false ->
            Data#data{buffer = queue:in(Entry, Q), buffer_len = N + 1,
                      next_index = Ix + 1}
    end.

%% Send every buffer entry the active connection has not been handed yet
%% (normally just the one just pushed).
flush_new(Conn, #data{buffer = Q, sent = Sent} = Data) ->
    New = [E || {Ix, _} = E <- queue:to_list(Q), Ix > Sent],
    send_entries(Conn, New),
    case New of
        [] -> Data;
        _ -> Data#data{sent = last_index(New)}
    end.

%% Promote `Conn': resend everything still in the buffer (all of it is past
%% `released' by construction) and reset the send high-water mark to it.
replay(Conn, #data{buffer = Q, released = Rel} = Data) ->
    Entries = queue:to_list(Q),
    send_entries(Conn, Entries),
    case Entries of
        [] -> Data#data{sent = Rel};
        _ -> Data#data{sent = last_index(Entries)}
    end.

drop_released(Index, #data{buffer = Q, released = Rel} = Data) ->
    Kept = [E || {Ix, _} = E <- queue:to_list(Q), Ix > Index],
    Data#data{buffer = queue:from_list(Kept), buffer_len = length(Kept),
              released = max(Rel, Index)}.

send_entries(Conn, Entries) ->
    lists:foreach(fun({Ix, Asdu}) ->
                          iec60870_104_conn:send_asdu(Conn, Asdu, Ix)
                  end, Entries).

last_index(Entries) ->
    {Ix, _} = lists:last(Entries),
    Ix.

%%%===================================================================
%%% Relay to iec60870_server_ctl
%%%===================================================================

relay(Payload, Conn, #data{name = Name}) ->
    case iec60870_registry:whereis_name({ctl, Name}) of
        undefined -> ok;
        Ctl -> iec60870_server_ctl:relay(Ctl, Conn, Payload)
    end.

relay_sync(Payload, Conn, #data{name = Name}) ->
    case iec60870_registry:whereis_name({ctl, Name}) of
        undefined -> ok;
        Ctl -> iec60870_server_ctl:relay_sync(Ctl, Conn, Payload)
    end.

%%%===================================================================
%%% Peer-address matching (`multiple' mode) — pure
%%%===================================================================

%% @doc The configured group id whose `match' list contains `PeerIp', or
%% `DefaultId'. `Groups' is the `redundancy.groups' list; each entry is a map
%% with `name' and a `match' list of `{ip, BaseAddr, PrefixLen}'.
-spec match(inet:ip_address(), [map()], term()) -> term().
match(PeerIp, Groups, DefaultId) ->
    case lists:search(fun(G) -> matches_any(PeerIp, maps:get(match, G, [])) end,
                      Groups) of
        {value, G} -> maps:get(name, G);
        false -> DefaultId
    end.

matches_any(Ip, Specs) ->
    lists:any(fun(Spec) -> match_spec(Ip, Spec) end, Specs).

match_spec(Ip, {ip, Base, Prefix})
  when tuple_size(Ip) =:= tuple_size(Base),
       is_integer(Prefix), Prefix >= 0 ->
    Bits = bit_width(Ip),
    Prefix =< Bits andalso
        begin
            Shift = Bits - Prefix,
            (ip_to_int(Ip) bsr Shift) =:= (ip_to_int(Base) bsr Shift)
        end;
match_spec(_Ip, _Spec) ->
    false.

bit_width(Ip) when tuple_size(Ip) =:= 4 -> 32;
bit_width(Ip) when tuple_size(Ip) =:= 8 -> 128.

ip_to_int({A, B, C, D}) ->
    (A bsl 24) bor (B bsl 16) bor (C bsl 8) bor D;
ip_to_int({A, B, C, D, E, F, G, H}) ->
    lists:foldl(fun(X, Acc) -> (Acc bsl 16) bor X end, 0, [A, B, C, D, E, F, G, H]).
