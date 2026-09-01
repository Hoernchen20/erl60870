%%% @doc Server control process — config, data model, callback state, and the
%%% connection owner (docs/DESIGN.md sections 4, 7, 8).
%%%
%%% One `gen_server' per server. It:
%%%
%%% <ul>
%%%   <li>starts and owns the `ranch' listener, passing itself as the
%%%       {@link iec60870_104_conn} owner (phase-3 interim — the redundancy
%%%       group takes this over in phase 5);</li>
%%%   <li>owns the default data model's ETS table
%%%       ({@link iec60870_dm_ets:init/1} runs in this process);</li>
%%%   <li>answers station / group interrogation (C_IC_NA_1) from the data
%%%       model, batched via {@link iec60870_batch};</li>
%%%   <li>turns {@link iec60870_server:update/3} into spontaneous ASDUs, held in
%%%       a bounded drop-oldest buffer while no connection is active.</li>
%%% </ul>
%%%
%%% Multiple active connections all receive spontaneous and low-level traffic
%%% (the future `redundancy => connection' semantics); interrogation is answered
%%% on the requesting connection. Commands and clock sync are answered with a
%%% negative confirmation until phases 4 / 7.
-module(iec60870_server_ctl).
-behaviour(gen_server).

-include_lib("iec60870/include/iec60870_asdu.hrl").

-export([start_link/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).

-record(state, {
    name                       :: term(),
    coas = []                  :: [0..65535],
    orig_addr = 0              :: 0..255,
    asdu_opts = #{}            :: iec60870_asdu:opts(),
    listener_ref               :: ranch:ref() | undefined,
    dm_mod                     :: module(),
    dm_state                   :: iec60870_data_model:state(),
    cb_mod = undefined         :: module() | undefined,
    cb_state = undefined       :: term(),
    %% conn pid -> {active | inactive, monitor ref}
    conns = #{}                :: #{pid() => {active | inactive, reference()}},
    buffer = queue:new()       :: queue:queue(#asdu{}),
    buffer_len = 0             :: non_neg_integer(),
    buffer_max = 1000          :: pos_integer()
}).

%%%===================================================================
%%% API
%%%===================================================================

-spec start_link(term(), map()) -> gen_server:start_ret().
start_link(Name, Config) ->
    gen_server:start_link(?MODULE, {Name, Config}, []).

%%%===================================================================
%%% gen_server
%%%===================================================================

-spec init({term(), map()}) -> {ok, #state{}} | {stop, term()}.
init({Name, Config}) ->
    process_flag(trap_exit, true),
    Params = maps:get(params, Config, #{}),
    AsduOpts = #{cot_size => maps:get(cot_size, Params, 2),
                 coa_size => maps:get(coa_size, Params, 2),
                 ioa_size => maps:get(ioa_size, Params, 3)},
    {Transport, TOpts} = transport(maps:get(transport, Config, {tcp, []})),
    {DmMod, DmArgs} = maps:get(data_model, Config, {iec60870_dm_ets, #{}}),
    {ok, DmState} = DmMod:init(DmArgs),
    case start_callback(maps:get(callback, Config, undefined)) of
        {ok, CbMod, CbState} ->
            Ref = {iec60870_server, Name},
            _ = iec60870_104_listener:stop(Ref),
            ListenerOpts = #{owner => self(), transport => Transport,
                             transport_opts => TOpts, params => Params},
            case iec60870_104_listener:start(Ref, ListenerOpts) of
                {ok, _} ->
                    {ok, #state{
                        name = Name,
                        coas = maps:get(common_addresses, Config, []),
                        orig_addr = maps:get(orig_addr, Params, 0),
                        asdu_opts = AsduOpts,
                        listener_ref = Ref,
                        dm_mod = DmMod, dm_state = DmState,
                        cb_mod = CbMod, cb_state = CbState,
                        buffer_max = buffer_max(Config)}};
                {error, Reason} ->
                    _ = DmMod:terminate(DmState),
                    {stop, {listener_failed, Reason}}
            end;
        {error, Reason} ->
            _ = DmMod:terminate(DmState),
            {stop, {callback_failed, Reason}}
    end.

handle_call(port, _From, #state{listener_ref = Ref} = State) ->
    {reply, ranch:get_port(Ref), State};
handle_call(_Request, _From, State) ->
    {reply, {error, bad_request}, State}.

handle_cast({update, Writes}, State) ->
    {noreply, do_update(Writes, State)};
handle_cast({send_asdu, _Selector, Spec}, State) ->
    {noreply, dispatch([spec_to_asdu(Spec)], State)};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({iec60870, Conn, Payload}, State) ->
    handle_owner(Payload, Conn, State);
handle_info({'DOWN', _Mon, process, Pid, _Reason}, #state{conns = Conns} = State) ->
    {noreply, State#state{conns = maps:remove(Pid, Conns)}};
handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, #state{listener_ref = Ref, dm_mod = DmMod, dm_state = DmState}) ->
    _ = case Ref of
            undefined -> ok;
            _ -> iec60870_104_listener:stop(Ref)
        end,
    _ = (catch DmMod:terminate(DmState)),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Owner messages from iec60870_104_conn
%%%===================================================================

handle_owner(activated, Conn, State) ->
    State1 = flush_buffer(Conn, track(Conn, active, State)),
    {noreply, cb_event({activated, Conn}, State1)};
handle_owner(deactivated, Conn, State) ->
    {noreply, cb_event({deactivated, Conn}, track(Conn, inactive, State))};
handle_owner({asdu, Asdu}, Conn, State) ->
    route(Asdu, Conn, State);
handle_owner({closed, Reason}, Conn, #state{conns = Conns} = State) ->
    State1 = case maps:take(Conn, Conns) of
                 {{_, Mon}, Rest} ->
                     _ = demonitor(Mon, [flush]),
                     State#state{conns = Rest};
                 error ->
                     State
             end,
    {noreply, cb_event({down, Conn, Reason}, State1)};
handle_owner({decode_error, Reason}, _Conn, #state{name = Name} = State) ->
    logger:warning("iec60870 server ~p: incoming ASDU decode error: ~p",
                   [Name, Reason]),
    {noreply, State};
handle_owner({outbox_overflow, Dropped}, _Conn, #state{name = Name} = State) ->
    logger:warning("iec60870 server ~p: connection outbox overflow, ~p dropped",
                   [Name, Dropped]),
    {noreply, State};
handle_owner(_Other, _Conn, State) ->
    {noreply, State}.

track(Conn, Status, #state{conns = Conns} = State) ->
    Entry = case Conns of
                #{Conn := {_, Mon}} -> {Status, Mon};
                _ -> {Status, monitor(process, Conn)}
            end,
    State#state{conns = Conns#{Conn => Entry}}.

active_conns(#state{conns = Conns}) ->
    [Conn || Conn := {active, _} <- Conns].

%%%===================================================================
%%% Incoming ASDU routing
%%%===================================================================

route(#asdu{type = c_ic_na_1, cot = act} = Asdu, Conn, State) ->
    interrogate(Asdu, Conn, State);
route(#asdu{type = c_ic_na_1, cot = deact} = Asdu, Conn, State) ->
    send_to(Conn, Asdu#asdu{cot = deact_con}),
    {noreply, State};
route(#asdu{cot = act} = Asdu, Conn, State) ->
    %% commands / clock sync — not until phases 4 / 7.
    send_to(Conn, Asdu#asdu{cot = unknown_type_id, negative = true, objects = []}),
    {noreply, State};
route(_Asdu, _Conn, State) ->
    {noreply, State}.

%%%===================================================================
%%% Interrogation (C_IC_NA_1) — docs/DESIGN.md section 7
%%%===================================================================

interrogate(#asdu{coa = Coa, orig_addr = OA, test = Test,
                  objects = [#object{value = Qoi}]},
            Conn, #state{coas = Coas} = State) ->
    Mirror = fun(Cot, Neg) ->
                 #asdu{type = c_ic_na_1, cot = Cot, negative = Neg, test = Test,
                       orig_addr = OA, coa = Coa,
                       objects = [#object{ioa = 0, value = Qoi}]}
             end,
    case lists:member(Coa, Coas) andalso qoi_group(Qoi) of
        false ->
            send_to(Conn, Mirror(act_con, true)),
            {noreply, State};
        Group ->
            send_to(Conn, Mirror(act_con, false)),
            {Dump, State1} = dump(Coa, Qoi, Group, OA, Test, State),
            lists:foreach(fun(Asdu) -> send_to(Conn, Asdu) end, Dump),
            send_to(Conn, Mirror(act_term, false)),
            {noreply, State1}
    end;
interrogate(_Asdu, _Conn, State) ->
    %% malformed C_IC — no QOI object
    {noreply, State}.

qoi_group(20) -> station;
qoi_group(N) when is_integer(N), N >= 21, N =< 36 -> N - 20;
qoi_group(_) -> false.

dump(Coa, Qoi, Group, OA, Test, #state{cb_mod = CbMod, cb_state = CbState0} = State) ->
    case call_interrogation(CbMod, Coa, Qoi, CbState0) of
        {library, CbState1} ->
            Asdus = stamp(library_dump(Coa, Group, State), OA, Test),
            {Asdus, State#state{cb_state = CbState1}};
        {explicit, Specs, CbState1} ->
            {[spec_to_asdu(S) || S <- Specs], State#state{cb_state = CbState1}}
    end.

library_dump(Coa, Group, #state{dm_mod = DmMod, dm_state = DmState,
                                asdu_opts = Opts}) ->
    Cot = case Group of
              station -> interrogated_station;
              N -> {interrogated_group, N}
          end,
    ByType = DmMod:fold(DmState, Coa, Group,
                        fun(Ioa, Point, Acc) ->
                                Type = maps:get(type, Point),
                                Obj = iec60870_point:to_object(Type, Ioa, Point),
                                maps:update_with(Type, fun(L) -> [Obj | L] end,
                                                 [Obj], Acc)
                        end, #{}),
    Groups = [{{Type, Coa, Cot}, Objs} || Type := Objs <- ByType],
    iec60870_batch:pack(Groups, Opts).

stamp(Asdus, 0, false) -> Asdus;
stamp(Asdus, OA, Test) -> [A#asdu{orig_addr = OA, test = Test} || A <- Asdus].

call_interrogation(undefined, _Coa, _Qoi, CbState) ->
    {library, CbState};
call_interrogation(CbMod, Coa, Qoi, CbState) ->
    case erlang:function_exported(CbMod, interrogation, 3) of
        false ->
            {library, CbState};
        true ->
            case CbMod:interrogation(Coa, Qoi, CbState) of
                {ok, CbState1} -> {library, CbState1};
                {ok, Specs, CbState1} when is_list(Specs) -> {explicit, Specs, CbState1}
            end
    end.

%%%===================================================================
%%% update/3 -> spontaneous transmission — docs/DESIGN.md section 8
%%%===================================================================

do_update(Writes, State) ->
    {Changed, State1} = apply_writes(Writes, State, []),
    case Changed of
        [] ->
            State1;
        _ ->
            Groups = spontaneous_groups(Changed),
            dispatch(iec60870_batch:pack(Groups, State1#state.asdu_opts), State1)
    end.

apply_writes([], State, Acc) ->
    {Acc, State};
apply_writes([{{Coa, Ioa}, Spec} | Rest], #state{dm_mod = DmMod} = State, Acc) ->
    Point = iec60870_point:spec_to_point(Spec),
    {ok, DmState1, Changed} = DmMod:write(State#state.dm_state, Coa, Ioa, Point),
    Acc1 = case Changed of
               true -> [{Coa, Ioa, maps:get(type, Point), Point} | Acc];
               false -> Acc
           end,
    apply_writes(Rest, State#state{dm_state = DmState1}, Acc1).

spontaneous_groups(Changed) ->
    ByKey = lists:foldl(
              fun({Coa, Ioa, Type, Point}, Acc) ->
                      Key = {Type, Coa, spontaneous},
                      Obj = iec60870_point:to_object(Type, Ioa, Point),
                      maps:update_with(Key, fun(L) -> [Obj | L] end, [Obj], Acc)
              end, #{}, Changed),
    maps:to_list(ByKey).

%%%===================================================================
%%% Dispatch / buffering
%%%===================================================================

dispatch(Asdus, State) ->
    case active_conns(State) of
        [] ->
            lists:foldl(fun buffer_push/2, State, Asdus);
        Conns ->
            lists:foreach(
              fun(Asdu) ->
                      lists:foreach(fun(Conn) -> send_to(Conn, Asdu) end, Conns)
              end, Asdus),
            State
    end.

buffer_push(Asdu, #state{buffer = Q, buffer_len = N, buffer_max = Max,
                         name = Name} = State) ->
    case N >= Max of
        true ->
            logger:warning("iec60870 server ~p: spontaneous buffer full (~p), "
                           "dropping oldest", [Name, Max]),
            State#state{buffer = queue:in(Asdu, queue:drop(Q))};
        false ->
            State#state{buffer = queue:in(Asdu, Q), buffer_len = N + 1}
    end.

flush_buffer(_Conn, #state{buffer_len = 0} = State) ->
    State;
flush_buffer(Conn, #state{buffer = Q} = State) ->
    lists:foreach(fun(Asdu) -> send_to(Conn, Asdu) end, queue:to_list(Q)),
    State#state{buffer = queue:new(), buffer_len = 0}.

send_to(Conn, Asdu) ->
    iec60870_104_conn:send_asdu(Conn, Asdu).

%%%===================================================================
%%% Callback plumbing
%%%===================================================================

start_callback(undefined) ->
    {ok, undefined, undefined};
start_callback({Mod, Args}) ->
    _ = code:ensure_loaded(Mod),
    try Mod:init(Args) of
        {ok, CbState} -> {ok, Mod, CbState}
    catch
        Class:Reason -> {error, {Class, Reason}}
    end.

cb_event(_Event, #state{cb_mod = undefined} = State) ->
    State;
cb_event(Event, #state{cb_mod = CbMod, cb_state = CbState} = State) ->
    case erlang:function_exported(CbMod, connection_event, 2) of
        true ->
            {ok, CbState1} = CbMod:connection_event(Event, CbState),
            State#state{cb_state = CbState1};
        false ->
            State
    end.

%%%===================================================================
%%% Helpers
%%%===================================================================

transport({Transport, Opts}) when is_list(Opts) -> {Transport, Opts};
transport(Transport) when is_atom(Transport) -> {Transport, []}.

buffer_max(Config) ->
    maps:get(buffer, maps:get(redundancy, Config, #{}), 1000).

spec_to_asdu(#{type := Type, coa := Coa, cot := Cot} = Spec) ->
    #asdu{type = Type, coa = Coa, cot = Cot,
          negative = maps:get(negative, Spec, false),
          test = maps:get(test, Spec, false),
          orig_addr = maps:get(orig_addr, Spec, 0),
          sequence = maps:get(sequence, Spec, false),
          objects = maps:get(objects, Spec, [])}.
