-module(iec60870_server_ctl).
-moduledoc """
Server control process — config, data model and callback state
(`docs/DESIGN.md` sections 4-8).

One `gen_server` per server. It:

- starts the `ranch` listener, handing each connection a resolver fun that
  assigns it to an `m:iec60870_rgroup` by peer address (interim — the
  listener is still started here, see the phase-3 note in `docs/DESIGN.md`
  section 3);
- owns the default data model's ETS table (`iec60870_dm_ets:init/1` runs in
  this process);
- answers station / group interrogation (C_IC_NA_1) from the data model,
  batched via `m:iec60870_batch`;
- turns `iec60870_server:update/3` into spontaneous ASDUs and hands them to
  every redundancy group (each buffers / replays on its own —
  `docs/DESIGN.md` section 5);
- runs commands (C_SC/C_DC/C_RC/C_SE) — direct execute and
  select-before-operate, sync or async — clock sync (C_CS), counter
  interrogation (C_CI), the read command (C_RD), the test command
  (C_TS_TA_1) and parameter of measured value / parameter activation
  (P_ME_*/P_AC), `docs/DESIGN.md` section 7;
- sends the end-of-initialization ASDU (M_EI_NA_1, COT `initialized`) to a
  connection right after it activates, config key `coi`.

The redundancy groups own the connections; they `relay/3` incoming ASDUs and
connection lifecycle events here. Interrogation and command replies are sent
straight back on the requesting connection.
""".
-behaviour(gen_server).

-include_lib("iec60870/include/iec60870_asdu.hrl").

-export([start_link/2, relay/3, relay_sync/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).

-record(state, {
    name                       :: term(),
    coas = []                  :: [0..65535],
    orig_addr = 0              :: 0..255,
    asdu_opts = #{}            :: iec60870_asdu:opts(),
    listener_ref               :: ranch:ref() | undefined,
    rgroup_sup                  :: pid(),
    dm_mod                     :: module(),
    dm_state                   :: iec60870_data_model:state(),
    cb_mod = undefined         :: module() | undefined,
    cb_state = undefined       :: term(),
    select_timeout = 10000     :: pos_integer(),
    clock_sync_con = true      :: boolean(),
    coi = 0                    :: 0..127 | false,
    %% {Coa, Ioa} -> outstanding select (docs/DESIGN.md section 7)
    selects = #{}              :: #{{0..65535, non_neg_integer()} => select()},
    %% async-execute reference -> what to answer with when it resolves
    pending = #{}              :: #{reference() => pending()}
}).

-type select() :: #{cmd := iec60870_command:command(), conn := pid(),
                    timer := reference()}.
-type pending() :: #{asdu := #asdu{}, conn := pid()}.

%%%===================================================================
%%% API
%%%===================================================================

-spec start_link(term(), map()) -> gen_server:start_ret().
start_link(Name, Config) ->
    gen_server:start_link(?MODULE, {Name, Config}, []).

-doc """
Called by an `m:iec60870_rgroup` to hand an owner message (`{asdu, _}`,
`activated`, `deactivated`, `{closed, _}`, ...) from one of its member
connections up to this control process.
""".
-spec relay(pid(), pid(), term()) -> ok.
relay(Ctl, Conn, Payload) ->
    gen_server:cast(Ctl, {owner_event, Conn, Payload}).

-doc """
Like `relay/3`, but waits for this control process to have finished handling
`Payload` before returning. Used only for `activated` (`docs/DESIGN.md`
section 7, end of initialization): a redundancy group promoting a
newly-activated connection replays its buffer to that same connection right
after this call returns, and that replay must not overtake the
end-of-initialization ASDU this control process sends directly to the
connection while handling `activated` — a plain (asynchronous) `relay/3`
gives no such ordering guarantee between the two independent senders.
""".
-spec relay_sync(pid(), pid(), term()) -> ok.
relay_sync(Ctl, Conn, Payload) ->
    gen_server:call(Ctl, {owner_event, Conn, Payload}).

%%%===================================================================
%%% gen_server
%%%===================================================================

-spec init({term(), map()}) -> {ok, #state{}} | {stop, term()}.
init({Name, Config}) ->
    process_flag(trap_exit, true),
    case iec60870_registry:whereis_name({rgroup_sup, Name}) of
        RgroupSup when is_pid(RgroupSup) ->
            _ = iec60870_registry:unregister_name({ctl, Name}),
            yes = iec60870_registry:register_name({ctl, Name}, self()),
            do_init(Name, Config, RgroupSup);
        undefined ->
            {stop, {rgroup_sup_not_registered, Name}}
    end.

do_init(Name, Config, RgroupSup) ->
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
            Resolver = make_resolver(Config, RgroupSup, Name),
            ListenerOpts = #{owner => Resolver, transport => Transport,
                             transport_opts => TOpts, params => Params},
            case iec60870_104_listener:start(Ref, ListenerOpts) of
                {ok, _} ->
                    {ok, #state{
                        name = Name,
                        coas = maps:get(common_addresses, Config, []),
                        orig_addr = maps:get(orig_addr, Params, 0),
                        asdu_opts = AsduOpts,
                        listener_ref = Ref,
                        rgroup_sup = RgroupSup,
                        dm_mod = DmMod, dm_state = DmState,
                        cb_mod = CbMod, cb_state = CbState,
                        select_timeout = maps:get(select_timeout, Config, 10000),
                        clock_sync_con = maps:get(clock_sync_confirm, Config, true),
                        coi = maps:get(coi, Config, 0)}};
                {error, Reason} ->
                    _ = DmMod:terminate(DmState),
                    _ = iec60870_registry:unregister_name({ctl, Name}),
                    {stop, {listener_failed, Reason}}
            end;
        {error, Reason} ->
            _ = DmMod:terminate(DmState),
            _ = iec60870_registry:unregister_name({ctl, Name}),
            {stop, {callback_failed, Reason}}
    end.

%% One resolver fun per listener, called by each iec60870_104_conn with
%% its peer IP to pick (or, for `connection` mode, spawn) its redundancy group.
make_resolver(Config, RgroupSup, Name) ->
    Red = maps:get(redundancy, Config, #{}),
    DefaultBuffer = maps:get(buffer, Red, 1000),
    case maps:get(mode, Red, connection) of
        connection ->
            fun(_PeerIp) ->
                iec60870_rgroup_sup:start_dynamic(RgroupSup, DefaultBuffer,
                                                  Name, self())
            end;
        single ->
            fun(_PeerIp) -> join(RgroupSup, default) end;
        multiple ->
            Groups = maps:get(groups, Red, []),
            fun(PeerIp) ->
                join(RgroupSup, iec60870_rgroup:match(PeerIp, Groups, default))
            end
    end.

%% Runs in the connecting iec60870_104_conn's init: pick the static
%% group for `Id` and register this connection (`self()`) as a member.
join(RgroupSup, Id) ->
    case iec60870_rgroup_sup:group_pid(RgroupSup, Id) of
        undefined ->
            {error, {no_group, Id}};
        Pid ->
            ok = iec60870_rgroup:add_member(Pid, self()),
            {ok, Pid}
    end.

handle_call(port, _From, #state{listener_ref = Ref} = State) ->
    {reply, ranch:get_port(Ref), State};
handle_call({owner_event, Conn, Payload}, _From, State) ->
    {noreply, State1} = handle_owner(Payload, Conn, State),
    {reply, ok, State1};
handle_call(_Request, _From, State) ->
    {reply, {error, bad_request}, State}.

handle_cast({update, Writes}, State) ->
    {noreply, do_update(Writes, State)};
handle_cast({send_asdu, _Selector, Spec}, State) ->
    {noreply, dispatch([spec_to_asdu(Spec)], State)};
handle_cast({command_result, Ref, Result}, State) ->
    {noreply, resolve_command(Ref, Result, State)};
handle_cast({owner_event, Conn, Payload}, State) ->
    handle_owner(Payload, Conn, State);
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({timeout, TRef, {select_expired, Key}}, #state{selects = Selects} = State) ->
    State1 = case Selects of
                 #{Key := #{timer := TRef}} -> State#state{selects = maps:remove(Key, Selects)};
                 _ -> State
             end,
    {noreply, State1};
handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, #state{name = Name, listener_ref = Ref, dm_mod = DmMod,
                          dm_state = DmState, pending = Pending}) ->
    _ = maps:foreach(fun(Ref1, _) -> iec60870_registry:unbind_command(Ref1) end, Pending),
    _ = iec60870_registry:unregister_name({ctl, Name}),
    _ = case Ref of
            undefined -> ok;
            _ -> iec60870_104_listener:stop(Ref)
        end,
    _ = (catch DmMod:terminate(DmState)),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Owner messages, relayed from an iec60870_rgroup (see relay/3)
%%%===================================================================

handle_owner(activated, Conn, State) ->
    send_end_of_init(Conn, State),
    {noreply, cb_event({activated, Conn}, State)};
handle_owner(deactivated, Conn, State) ->
    {noreply, cb_event({deactivated, Conn}, State)};
handle_owner({asdu, Asdu}, Conn, State) ->
    route(Asdu, Conn, State);
handle_owner({closed, Reason}, Conn, State) ->
    {noreply, cb_event({down, Conn, Reason}, State)};
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

%% One M_EI_NA_1 (end of initialization) per configured COA, straight to the
%% connection that just activated — docs/DESIGN.md section 7. Sent on every
%% activation (including a reconnect), not just once at server startup, so it
%% works the same way under all three redundancy modes (docs/DESIGN.md
%% section 5) instead of depending on a group already existing to buffer it.
%% Config key `coi' (0..127, the cause-of-initialization byte) defaults to 0
%% ("local power switch on"); `coi => false' disables it for callers managing
%% M_EI by hand via `send_asdu/3'.
send_end_of_init(_Conn, #state{coi = false}) ->
    ok;
send_end_of_init(Conn, #state{coi = Coi, coas = Coas}) ->
    lists:foreach(
      fun(Coa) ->
              send_to(Conn, #asdu{type = m_ei_na_1, cot = initialized, coa = Coa,
                                  objects = [#object{ioa = 0, value = Coi,
                                                     qualifier = #{local_change => false}}]})
      end, Coas).

%%%===================================================================
%%% Incoming ASDU routing
%%%===================================================================

route(#asdu{type = c_ic_na_1, cot = act} = Asdu, Conn, State) ->
    interrogate(Asdu, Conn, State);
route(#asdu{type = c_ic_na_1, cot = deact} = Asdu, Conn, State) ->
    send_to(Conn, Asdu#asdu{cot = deact_con}),
    {noreply, State};
route(#asdu{type = c_ci_na_1, cot = act} = Asdu, Conn, State) ->
    counter_interrogate(Asdu, Conn, State);
route(#asdu{type = c_rd_na_1} = Asdu, Conn, State) ->
    read_command(Asdu, Conn, State);
route(#asdu{type = c_cs_na_1, cot = act} = Asdu, Conn, State) ->
    clock_sync(Asdu, Conn, State);
route(#asdu{type = c_ts_ta_1, cot = act} = Asdu, Conn, State) ->
    test_command(Asdu, Conn, State);
route(#asdu{type = Type, cot = act} = Asdu, Conn, State)
  when Type =:= p_me_na_1; Type =:= p_me_nb_1; Type =:= p_me_nc_1 ->
    set_parameter(Asdu, Conn, State);
route(#asdu{type = p_ac_na_1, cot = act} = Asdu, Conn, State) ->
    activate_parameter(Asdu, Conn, State);
route(#asdu{cot = act} = Asdu, Conn, State) ->
    case iec60870_command:is_command(Asdu#asdu.type) of
        true ->
            command(Asdu, Conn, State);
        false ->
            send_to(Conn, Asdu#asdu{cot = unknown_type_id, negative = true, objects = []}),
            {noreply, State}
    end;
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
%%% Counter interrogation (C_CI_NA_1) — docs/DESIGN.md section 7
%%%===================================================================

counter_interrogate(#asdu{coa = Coa, orig_addr = OA, test = Test,
                          objects = [#object{value = #{request := Rqt} = Qcc}]} = Asdu,
                    Conn, #state{coas = Coas} = State) ->
    Mirror = fun(Cot, Neg) -> Asdu#asdu{cot = Cot, negative = Neg} end,
    case lists:member(Coa, Coas) andalso rqt_group(Rqt) of
        false ->
            send_to(Conn, Mirror(act_con, true)),
            {noreply, State};
        Group ->
            send_to(Conn, Mirror(act_con, false)),
            {Dump, State1} = counter_dump(Coa, Qcc, Group, OA, Test, State),
            lists:foreach(fun(A) -> send_to(Conn, A) end, Dump),
            send_to(Conn, Mirror(act_term, false)),
            {noreply, State1}
    end;
counter_interrogate(_Asdu, _Conn, State) ->
    %% malformed C_CI — no QCC object
    {noreply, State}.

rqt_group(5) -> station;
rqt_group(N) when is_integer(N), N >= 1, N =< 4 -> N;
rqt_group(_) -> false.

%% The dump reads the pre-freeze values — `freeze_reset' / `reset' only zero
%% the store *after* they have been reported, so the delivered value is the
%% one at the moment of the command, matching the BCR freeze semantics.
counter_dump(Coa, Qcc, Group, OA, Test,
             #state{cb_mod = CbMod, cb_state = CbState0} = State) ->
    case call_counter_interrogation(CbMod, Coa, Qcc, CbState0) of
        {library, CbState1} ->
            State1 = State#state{cb_state = CbState1},
            Asdus = stamp(library_counter_dump(Coa, Group, State1), OA, Test),
            {ok, DmState1} = (State1#state.dm_mod):freeze_counters(
                               State1#state.dm_state, Coa, Group, maps:get(freeze, Qcc)),
            {Asdus, State1#state{dm_state = DmState1}};
        {explicit, Specs, CbState1} ->
            {[spec_to_asdu(S) || S <- Specs], State#state{cb_state = CbState1}}
    end.

library_counter_dump(Coa, Group, #state{dm_mod = DmMod, dm_state = DmState,
                                        asdu_opts = Opts}) ->
    Cot = case Group of
              station -> interrogated_counter;
              N -> {interrogated_counter_group, N}
          end,
    ByType = DmMod:fold_counters(DmState, Coa, Group,
                        fun(Ioa, Point, Acc) ->
                                Type = maps:get(type, Point),
                                Obj = iec60870_point:to_object(Type, Ioa, Point),
                                maps:update_with(Type, fun(L) -> [Obj | L] end,
                                                 [Obj], Acc)
                        end, #{}),
    Groups = [{{Type, Coa, Cot}, Objs} || Type := Objs <- ByType],
    iec60870_batch:pack(Groups, Opts).

call_counter_interrogation(undefined, _Coa, _Qcc, CbState) ->
    {library, CbState};
call_counter_interrogation(CbMod, Coa, Qcc, CbState) ->
    case erlang:function_exported(CbMod, counter_interrogation, 3) of
        false ->
            {library, CbState};
        true ->
            case CbMod:counter_interrogation(Coa, Qcc, CbState) of
                {ok, CbState1} -> {library, CbState1};
                {ok, Specs, CbState1} when is_list(Specs) -> {explicit, Specs, CbState1}
            end
    end.

%%%===================================================================
%%% Read command (C_RD_NA_1) — docs/DESIGN.md section 7
%%%===================================================================

%% No act_con/act_term — the reply is the addressed point's current type
%% ASDU, COT `request' (5, "used only by read command"), or a negative
%% confirmation of the read command itself on a bad COA / unknown IOA.
read_command(#asdu{coa = Coa, orig_addr = OA, test = Test,
                   objects = [#object{ioa = Ioa}]} = Asdu, Conn,
             #state{coas = Coas, dm_mod = DmMod, dm_state = DmState} = State) ->
    case lists:member(Coa, Coas) of
        false ->
            send_to(Conn, Asdu#asdu{cot = unknown_coa, negative = true});
        true ->
            case DmMod:read(DmState, Coa, Ioa) of
                {ok, Point} ->
                    Type = maps:get(type, Point),
                    Obj = iec60870_point:to_object(Type, Ioa, Point),
                    send_to(Conn, #asdu{type = Type, cot = request, test = Test,
                                        orig_addr = OA, coa = Coa, objects = [Obj]});
                not_found ->
                    send_to(Conn, Asdu#asdu{cot = unknown_ioa, negative = true})
            end
    end,
    {noreply, State};
read_command(_Asdu, _Conn, State) ->
    %% malformed C_RD — no IOA object
    {noreply, State}.

%%%===================================================================
%%% Test command (C_TS_TA_1) — docs/DESIGN.md section 7
%%%===================================================================

%% Pure echo — no semantic action, so no callback: the same test pattern and
%% timestamp mirrored back with a positive/negative act_con per COA.
test_command(#asdu{coa = Coa} = Asdu, Conn, #state{coas = Coas} = State) ->
    Negative = not lists:member(Coa, Coas),
    send_to(Conn, Asdu#asdu{cot = act_con, negative = Negative}),
    {noreply, State}.

%%%===================================================================
%%% Parameter of measured value / activation (P_ME_*/P_AC) — docs/DESIGN.md
%%% section 7
%%%===================================================================

set_parameter(#asdu{coa = Coa,
                    objects = [#object{ioa = Ioa, value = Value, qualifier = Qpm}]} = Asdu,
              Conn, #state{coas = Coas} = State) ->
    case lists:member(Coa, Coas) of
        false ->
            send_to(Conn, Asdu#asdu{cot = act_con, negative = true}),
            {noreply, State};
        true ->
            case call_set_parameter(Coa, Ioa, Value, Qpm, State) of
                {ok, State1} ->
                    send_to(Conn, Asdu#asdu{cot = act_con, negative = false}),
                    send_to(Conn, Asdu#asdu{cot = act_term, negative = false}),
                    {noreply, State1};
                {error, Cot, State1} ->
                    send_to(Conn, Asdu#asdu{cot = neg_cot(Cot), negative = true}),
                    {noreply, State1}
            end
    end;
set_parameter(_Asdu, _Conn, State) ->
    %% malformed P_ME_* — not exactly one object
    {noreply, State}.

%% No callback module, or one that doesn't opt into `set_parameter/5':
%% rejected by default — same reasoning as commands (unsafe to no-op).
call_set_parameter(_Coa, _Ioa, _Value, _Qpm, #state{cb_mod = undefined} = State) ->
    {error, act_con, State};
call_set_parameter(Coa, Ioa, Value, Qpm, #state{cb_mod = CbMod, cb_state = CbState} = State) ->
    case erlang:function_exported(CbMod, set_parameter, 5) of
        false ->
            {error, act_con, State};
        true ->
            case CbMod:set_parameter(Coa, Ioa, Value, Qpm, CbState) of
                {ok, CbState1} -> {ok, State#state{cb_state = CbState1}};
                {error, Cot, CbState1} -> {error, Cot, State#state{cb_state = CbState1}}
            end
    end.

activate_parameter(#asdu{coa = Coa, objects = [#object{ioa = Ioa, value = Qpa}]} = Asdu,
                   Conn, #state{coas = Coas} = State) ->
    case lists:member(Coa, Coas) of
        false ->
            send_to(Conn, Asdu#asdu{cot = act_con, negative = true}),
            {noreply, State};
        true ->
            case call_activate_parameter(Coa, Ioa, Qpa, State) of
                {ok, State1} ->
                    send_to(Conn, Asdu#asdu{cot = act_con, negative = false}),
                    send_to(Conn, Asdu#asdu{cot = act_term, negative = false}),
                    {noreply, State1};
                {error, Cot, State1} ->
                    send_to(Conn, Asdu#asdu{cot = neg_cot(Cot), negative = true}),
                    {noreply, State1}
            end
    end;
activate_parameter(_Asdu, _Conn, State) ->
    %% malformed P_AC — not exactly one object
    {noreply, State}.

%% No callback module, or one that doesn't opt into `activate_parameter/4':
%% rejected by default — same reasoning as commands (unsafe to no-op).
call_activate_parameter(_Coa, _Ioa, _Qpa, #state{cb_mod = undefined} = State) ->
    {error, act_con, State};
call_activate_parameter(Coa, Ioa, Qpa, #state{cb_mod = CbMod, cb_state = CbState} = State) ->
    case erlang:function_exported(CbMod, activate_parameter, 4) of
        false ->
            {error, act_con, State};
        true ->
            case CbMod:activate_parameter(Coa, Ioa, Qpa, CbState) of
                {ok, CbState1} -> {ok, State#state{cb_state = CbState1}};
                {error, Cot, CbState1} -> {error, Cot, State#state{cb_state = CbState1}}
            end
    end.

%%%===================================================================
%%% Commands (C_SC/C_DC/C_RC/C_SE) — docs/DESIGN.md section 7
%%%===================================================================

%% Direct execute (S/E = 0, no prior select) or select-before-operate,
%% dispatched on the single command object's S/E bit.
command(#asdu{coa = Coa, objects = [_]} = Asdu, Conn, #state{coas = Coas} = State) ->
    case lists:member(Coa, Coas) of
        false ->
            send_to(Conn, iec60870_command:mirror(Asdu, act_con, true)),
            {noreply, State};
        true ->
            Cmd = iec60870_command:to_map(Asdu),
            case maps:get(select, Cmd) of
                true -> do_select(Asdu, Cmd, Conn, State);
                false -> do_execute(Asdu, Cmd, Conn, State)
            end
    end;
command(_Asdu, _Conn, State) ->
    %% malformed command — not exactly one object
    {noreply, State}.

do_select(Asdu, #{coa := Coa, ioa := Ioa} = Cmd, Conn, State) ->
    case call_select(Cmd, State) of
        {accept, State1} ->
            send_to(Conn, iec60870_command:mirror(Asdu, act_con, false)),
            Selects = start_select(Coa, Ioa, Cmd, Conn, State1),
            {noreply, State1#state{selects = Selects}};
        {reject, Cot, State1} ->
            send_to(Conn, iec60870_command:mirror(Asdu, neg_cot(Cot), true)),
            {noreply, State1}
    end.

%% No callback module, or one that doesn't opt into `select/2': commands are
%% refused by default rather than silently accepted.
call_select(_Cmd, #state{cb_mod = undefined} = State) ->
    {reject, act_con, State};
call_select(Cmd, #state{cb_mod = CbMod, cb_state = CbState} = State) ->
    case erlang:function_exported(CbMod, select, 2) of
        false ->
            {reject, act_con, State};
        true ->
            case CbMod:select(Cmd, CbState) of
                {accept, CbState1} -> {accept, State#state{cb_state = CbState1}};
                {reject, Cot, CbState1} -> {reject, Cot, State#state{cb_state = CbState1}}
            end
    end.

start_select(Coa, Ioa, Cmd, Conn, #state{selects = Selects, select_timeout = Timeout}) ->
    Key = {Coa, Ioa},
    _ = case Selects of
            #{Key := #{timer := Old}} -> erlang:cancel_timer(Old);
            _ -> ok
        end,
    TRef = erlang:start_timer(Timeout, self(), {select_expired, Key}),
    Selects#{Key => #{cmd => Cmd, conn => Conn, timer => TRef}}.

do_execute(Asdu, #{coa := Coa, ioa := Ioa} = Cmd, Conn, #state{selects = Selects} = State) ->
    case take_select(Coa, Ioa, Cmd, Selects) of
        {ok, Selects1} ->
            run_execute(Asdu, Cmd, Conn, State#state{selects = Selects1});
        none ->
            run_execute(Asdu, Cmd, Conn, State);
        mismatch ->
            %% an outstanding select exists but this operate doesn't match it
            %% — reject and leave the select armed for a correct retry.
            send_to(Conn, iec60870_command:mirror(Asdu, act_con, true)),
            {noreply, State}
    end.

take_select(Coa, Ioa, Cmd, Selects) ->
    Key = {Coa, Ioa},
    case Selects of
        #{Key := #{cmd := SelCmd, timer := TRef}} ->
            case iec60870_command:matches(SelCmd, Cmd) of
                true ->
                    _ = erlang:cancel_timer(TRef),
                    {ok, maps:remove(Key, Selects)};
                false ->
                    mismatch
            end;
        _ ->
            none
    end.

run_execute(Asdu, Cmd, Conn, State) ->
    case call_execute(Cmd, State) of
        {error, Cot, State1} ->
            send_to(Conn, iec60870_command:mirror(Asdu, neg_cot(Cot), true)),
            {noreply, State1};
        {ok, State1} ->
            send_to(Conn, iec60870_command:mirror(Asdu, act_con, false)),
            send_to(Conn, iec60870_command:mirror(Asdu, act_term, false)),
            {noreply, State1};
        {async, Ref, #state{pending = Pending} = State1} ->
            send_to(Conn, iec60870_command:mirror(Asdu, act_con, false)),
            ok = iec60870_registry:bind_command(Ref, self()),
            Pending1 = Pending#{Ref => #{asdu => Asdu, conn => Conn}},
            {noreply, State1#state{pending = Pending1}}
    end.

%% No callback module, or one that doesn't opt into `execute/2': commands are
%% refused by default rather than silently accepted.
call_execute(_Cmd, #state{cb_mod = undefined} = State) ->
    {error, act_con, State};
call_execute(Cmd, #state{cb_mod = CbMod, cb_state = CbState} = State) ->
    case erlang:function_exported(CbMod, execute, 2) of
        false ->
            {error, act_con, State};
        true ->
            case CbMod:execute(Cmd, CbState) of
                {ok, CbState1} -> {ok, State#state{cb_state = CbState1}};
                %% return-information (COT 11/12) from `Info' is deferred —
                %% treated the same as a plain `{ok, _}' for now.
                {ok, _Info, CbState1} -> {ok, State#state{cb_state = CbState1}};
                {error, Cot, CbState1} -> {error, Cot, State#state{cb_state = CbState1}};
                {async, Ref, CbState1} -> {async, Ref, State#state{cb_state = CbState1}}
            end
    end.

%% `{command_result, Ref, Result}' cast — resolves an `{async, Ref, _}' left
%% pending by `execute/2'. An unknown or already-resolved `Ref' is ignored.
resolve_command(Ref, Result, #state{pending = Pending} = State) ->
    case maps:take(Ref, Pending) of
        {#{asdu := Asdu, conn := Conn}, Pending1} ->
            _ = iec60870_registry:unbind_command(Ref),
            send_to(Conn, iec60870_command:mirror(Asdu, act_term, Result =/= ok)),
            State#state{pending = Pending1};
        error ->
            State
    end.

%% A rejection/error `Cot' the callback supplied must be a valid COT; fall
%% back to a plain `act_con' rather than let a misbehaving callback crash the
%% connection on encode.
neg_cot(Cot) ->
    try iec60870_cot:to_int(Cot) of
        _ -> Cot
    catch
        error:_ -> act_con
    end.

%%%===================================================================
%%% Clock sync (C_CS_NA_1) — docs/DESIGN.md section 7
%%%===================================================================

clock_sync(#asdu{coa = Coa, objects = [#object{timestamp = Time}]} = Asdu, Conn,
           #state{coas = Coas} = State) ->
    case lists:member(Coa, Coas) of
        false ->
            send_to(Conn, iec60870_command:mirror(Asdu, act_con, true)),
            {noreply, State};
        true ->
            case call_clock_sync(Coa, Time, State) of
                {ok, State1} ->
                    case State1#state.clock_sync_con of
                        true -> send_to(Conn, iec60870_command:mirror(Asdu, act_con, false));
                        false -> ok
                    end,
                    {noreply, State1};
                {error, Cot, State1} ->
                    send_to(Conn, iec60870_command:mirror(Asdu, neg_cot(Cot), true)),
                    {noreply, State1}
            end
    end;
clock_sync(_Asdu, _Conn, State) ->
    %% malformed C_CS — no time object
    {noreply, State}.

%% No callback / no `clock_sync/3': accepted by default — unlike a command,
%% acknowledging a clock sync has no unsafe side effect.
call_clock_sync(_Coa, _Time, #state{cb_mod = undefined} = State) ->
    {ok, State};
call_clock_sync(Coa, Time, #state{cb_mod = CbMod, cb_state = CbState} = State) ->
    case erlang:function_exported(CbMod, clock_sync, 3) of
        false ->
            {ok, State};
        true ->
            case CbMod:clock_sync(Coa, Time, CbState) of
                {ok, CbState1} -> {ok, State#state{cb_state = CbState1}};
                {error, Cot, CbState1} -> {error, Cot, State#state{cb_state = CbState1}}
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
    %% `cot => background' (a background scan, docs/DESIGN.md section 8) is
    %% always sent, unlike a plain `spontaneous' update which is gated on
    %% `Changed'.
    Cot = maps:get(cot, Spec, spontaneous),
    {ok, DmState1, Changed} = DmMod:write(State#state.dm_state, Coa, Ioa, Point),
    Acc1 = case Cot =:= background orelse Changed of
               true -> [{Coa, Ioa, maps:get(type, Point), Point, Cot} | Acc];
               false -> Acc
           end,
    apply_writes(Rest, State#state{dm_state = DmState1}, Acc1).

spontaneous_groups(Changed) ->
    ByKey = lists:foldl(
              fun({Coa, Ioa, Type, Point, Cot}, Acc) ->
                      Key = {Type, Coa, Cot},
                      Obj = iec60870_point:to_object(Type, Ioa, Point),
                      maps:update_with(Key, fun(L) -> [Obj | L] end, [Obj], Acc)
              end, #{}, Changed),
    maps:to_list(ByKey).

%%%===================================================================
%%% Dispatch
%%%===================================================================

%% Spontaneous / low-level traffic goes to every redundancy group; each group
%% buffers it, sends it on to its own active connection, and replays it across
%% a switchover (docs/DESIGN.md section 5).
dispatch(Asdus, #state{rgroup_sup = RgroupSup} = State) ->
    Groups = iec60870_rgroup_sup:which_groups(RgroupSup),
    lists:foreach(
      fun(Group) ->
              lists:foreach(fun(Asdu) -> iec60870_rgroup:enqueue(Group, Asdu) end,
                            Asdus)
      end, Groups),
    State.

%% Interrogation / command / clock-sync replies go straight back on the
%% requesting connection, bypassing the group buffer.
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

spec_to_asdu(#{type := Type, coa := Coa, cot := Cot} = Spec) ->
    #asdu{type = Type, coa = Coa, cot = Cot,
          negative = maps:get(negative, Spec, false),
          test = maps:get(test, Spec, false),
          orig_addr = maps:get(orig_addr, Spec, 0),
          sequence = maps:get(sequence, Spec, false),
          objects = maps:get(objects, Spec, [])}.
