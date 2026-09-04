-module(iec60870_server).
-moduledoc """
User-facing server API and callback behaviour (`docs/DESIGN.md`
sections 7-9).

A server is a supervision subtree (`m:iec60870_server_sup`); start it under
the library with `iec60870:start_server/2` or under your own supervisor with
`start_link/1` (the config map must then carry a `name`). Once running:

- `update/3` / `update/2` publish current values — the library writes the
  data model and, iff the value changed, sends a spontaneous (COT 3) ASDU to
  every active connection;
- the library answers station / group interrogation from the data model on
  its own;
- `send_asdu/3` is the escape hatch for hand-built ASDUs;
- `command_result/2` resolves an `{async, Ref, _}` returned from the
  `c:execute/2` callback.

The callback module is optional. When supplied it may implement
`c:interrogation/3` (override or supplement the automatic dump),
`c:connection_event/2`, `c:select/2` + `c:execute/2` (direct execute and
select-before-operate for C_SC/C_DC/C_RC/C_SE, `docs/DESIGN.md` section 7),
`c:clock_sync/3` (C_CS), `c:counter_interrogation/3` (C_CI — override or
supplement the automatic freeze + dump, same shape as `c:interrogation/3`),
and `c:set_parameter/5` + `c:activate_parameter/4` (P_ME_*/P_AC,
`docs/DESIGN.md` section 7). A command, parameter write or activation left
unimplemented (no callback module, or the callback doesn't export the
matching function) is rejected with a negative confirmation; an unimplemented
`c:clock_sync/3` is acknowledged by default, since accepting a clock sync
has no unsafe side effect. The read command (C_RD) and test command
(C_TS_TA_1) are pure protocol mechanics with no semantic action, so they
have no callback.
""".

-include_lib("iec60870/include/iec60870_asdu.hrl").

-export([start_link/1, update/2, update/3, send_asdu/3, listener_port/1,
         command_result/2]).

-export_type([server_ref/0, asdu_spec/0, conn_event/0]).

-type server_ref() :: atom() | pid() | {via, module(), term()}.

-doc """
The map accepted by `send_asdu/3` and returned by the `c:interrogation/3`
callback's explicit form. `objects` are `#object{}` records (build them with
the `m:iec60870_asdu` builders).
""".
-type asdu_spec() :: #{type := iec60870_asdu:type_name(),
                       coa := 0..65535,
                       cot := iec60870_cot:cot(),
                       objects := [#object{}],
                       sequence => boolean(),
                       negative => boolean(),
                       test => boolean(),
                       orig_addr => 0..255}.

-type conn_event() :: {activated, pid()}
                    | {deactivated, pid()}
                    | {down, pid(), term()}.

%%%===================================================================
%%% Callback behaviour
%%%===================================================================

-callback init(Args :: term()) -> {ok, CbState :: term()}.

-callback interrogation(Coa :: 0..65535, Qoi :: 0..255, CbState :: term()) ->
    {ok, CbState :: term()}
  | {ok, [asdu_spec()], CbState :: term()}.

-callback connection_event(conn_event(), CbState :: term()) ->
    {ok, CbState :: term()}.

-doc """
`select` is called for the select half (S/E = 1) of a select-before-operate
sequence; the library enforces the select timeout and that the matching
operate is identical to what was selected (`docs/DESIGN.md` section 7).
""".
-callback select(Command :: iec60870_command:command(), CbState :: term()) ->
    {accept, CbState :: term()} | {reject, iec60870_cot:cot(), CbState :: term()}.

-doc """
`execute` is called for a direct execute (S/E = 0 with no prior select) or
the operate half of a select-before-operate sequence. `{async, Ref, _}`
withholds `act_term` until `command_result/2` resolves `Ref`.
""".
-callback execute(Command :: iec60870_command:command(), CbState :: term()) ->
    {ok, CbState :: term()}
  | {ok, Info :: term(), CbState :: term()}
  | {error, iec60870_cot:cot(), CbState :: term()}
  | {async, reference(), CbState :: term()}.

-callback clock_sync(Coa :: 0..65535, Time :: #cp56{}, CbState :: term()) ->
    {ok, CbState :: term()} | {error, iec60870_cot:cot(), CbState :: term()}.

-callback counter_interrogation(Coa :: 0..65535, Qcc :: term(), CbState :: term()) ->
    {ok, CbState :: term()}
  | {ok, [asdu_spec()], CbState :: term()}.

-doc """
`set_parameter` answers a P_ME_NA_1/NB_1/NC_1 (parameter of measured value);
`Value` is the raw i16/float like the matching measured-value type, `Qpm` is
`#{kind => ..., in_operation => boolean(), local_change => boolean()}` (see
the `m:iec60870_type` moduledoc).
""".
-callback set_parameter(Coa :: 0..65535, Ioa :: non_neg_integer(),
                        Value :: number(), Qpm :: map(), CbState :: term()) ->
    {ok, CbState :: term()} | {error, iec60870_cot:cot(), CbState :: term()}.

-doc """
`activate_parameter` answers a P_AC_NA_1 (parameter activation); `Qpa` is
`not_used | act_deact_parameter | act_deact_persistent_cyclic | 0..127`.
""".
-callback activate_parameter(Coa :: 0..65535, Ioa :: non_neg_integer(),
                             Qpa :: term(), CbState :: term()) ->
    {ok, CbState :: term()} | {error, iec60870_cot:cot(), CbState :: term()}.

-optional_callbacks([interrogation/3, connection_event/2, select/2, execute/2,
                     clock_sync/3, counter_interrogation/3,
                     set_parameter/5, activate_parameter/4]).

%%%===================================================================
%%% API
%%%===================================================================

-doc """
Start a server subtree under the caller's supervisor. `Config` is the
`docs/DESIGN.md` section 9 map and must contain a `name`.
""".
-spec start_link(map()) -> supervisor:startlink_ret().
start_link(Config) when is_map(Config) ->
    Name = maps:get(name, Config),
    iec60870_server_sup:start_link(Name, Config).

-doc """
Publish one current value. `Spec` is an `m:iec60870_point` spec map (`type`
and `value` are required); `cot => background` sends it as a background scan
(COT 2) unconditionally, bypassing the change gate that a plain (default
`spontaneous`, COT 3) update is subject to — the library has no cyclic scan
timer of its own, so a periodic background scan is the caller's own timer
repeating an `update/3` with `cot => background`.
""".
-spec update(server_ref(), {0..65535, non_neg_integer()}, map()) -> ok.
update(Server, {Coa, Ioa}, Spec) when is_map(Spec) ->
    update(Server, [{{Coa, Ioa}, Spec}]).

-doc """
Publish many current values at once; changed points of equal `{type, COA}`
are batched into as few ASDUs as the wire allows.
""".
-spec update(server_ref(), [{{0..65535, non_neg_integer()}, map()}]) -> ok.
update(Server, Writes) when is_list(Writes) ->
    gen_server:cast(ctl(Server), {update, Writes}).

-doc """
Send a hand-built ASDU. `Selector` (`all | {group, _} | {coa, _}`) is
accepted for forward compatibility; for now every redundancy group gets it
(so its active connection does). Bypasses the current-value store.
""".
-spec send_asdu(server_ref(), all | {group, term()} | {coa, 0..65535}, asdu_spec()) -> ok.
send_asdu(Server, Selector, Spec) when is_map(Spec) ->
    gen_server:cast(ctl(Server), {send_asdu, Selector, Spec}).

-doc """
Resolve an `{async, Ref, _}` previously returned by the `c:execute/2`
callback: `ok` sends a positive `act_term`, `{error, Cause}` a negative
one. `Ref` carries its own routing (bound to its server by
`m:iec60870_server_ctl` when the async execute started, via
`iec60870_registry:bind_command/2`); an unknown or already-resolved `Ref` is
silently ignored.
""".
-spec command_result(reference(), ok | {error, iec60870_cot:cot()}) -> ok.
command_result(Ref, Result) when is_reference(Ref) ->
    case iec60870_registry:command_owner(Ref) of
        undefined -> ok;
        Ctl -> gen_server:cast(Ctl, {command_result, Ref, Result})
    end.

-doc "The TCP port the server's listener is bound to (useful with port 0).".
-spec listener_port(server_ref()) -> inet:port_number().
listener_port(Server) ->
    gen_server:call(ctl(Server), port).

%%%===================================================================
%%% Name resolution
%%%===================================================================

ctl(Pid) when is_pid(Pid) ->
    require(iec60870_server_sup:ctl(Pid));
ctl({via, Mod, Name}) ->
    ctl_from_sup(Mod:whereis_name(Name));
ctl(Name) ->
    ctl_from_sup(iec60870_registry:whereis_name(Name)).

ctl_from_sup(undefined) -> error(unknown_server);
ctl_from_sup(Sup) when is_pid(Sup) -> require(iec60870_server_sup:ctl(Sup)).

require(undefined) -> error(server_not_ready);
require(Pid) when is_pid(Pid) -> Pid.
