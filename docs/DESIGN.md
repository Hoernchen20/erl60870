# IEC 60870 Erlang Library — Design

Status: phases 0–4 implemented (skeleton + ASDU codec + APCI / single-connection
state machine + default data model / interrogation / spontaneous path +
commands / select-before-operate / clock sync); phase 5 (redundancy) is next.
Authoritative copy; the published artifact is a rendered snapshot.

## 1. Scope

- **Phase 1:** IEC 60870-5-104 **server** (controlled station), Edition 2 (2006), with redundancy.
- **Phase 2:** IEC 60870-5-104 **client** (controlling station).
- **Phase 3:** IEC 60870-5-101 (serial), reusing the shared application layer.
- OTP 26+, rebar3, `ranch` for the acceptor and TLS transport.
- Multiple independent servers and clients per node, started and supervised by the
  user or by the library.

## 2. Module layering

The application layer (ASDU) is identical for 101 and 104 — 104 is the companion
standard of 101. Only the lower layers differ. The ASDU layer stays completely
transport-free so the 101 phase is mostly "add a link layer".

```
apps/iec60870/
  include/
    iec60870_asdu.hrl          records: #asdu{}, #object{}, #qds{}, #cp56{}  (public)
  src/
    asdu/
      iec60870_asdu.erl        APDU/ASDU record <-> binary + object builders
      iec60870_type.erl        per-Type-ID encode/decode dispatch
      iec60870_type_*.erl      (optional split) M_SP_NA_1, M_ME_NC_1, C_SC_NA_1, ...
      iec60870_cot.erl         cause-of-transmission atom <-> integer
    104/
      iec60870_104_apci.erl     start byte, length, I/S/U control fields, seq numbers
      iec60870_104_conn.erl     gen_statem: per-socket APCI state machine + timers
                                (also the ranch_protocol callback)
      iec60870_104_listener.erl ranch:start_listener wrapper; redundancy-group
                                assignment added in phase 5
    101/                        (phase 3)
      iec60870_101_link.erl
    core/
      iec60870.erl               top-level convenience API (start_server/2, ...)
      iec60870_server.erl        user-facing server API + behaviour definition
      iec60870_server_sup.erl
      iec60870_server_ctl.erl    gen_server: config, callback state, command router
      iec60870_command.erl       command decode/match/mirror (pure)
      iec60870_rgroup_sup.erl
      iec60870_rgroup.erl        gen_statem: active-conn arbitration + event buffer
      iec60870_registry.erl      gen_server: instance name -> pid (also {via,_,_});
                                 also binds async-command refs to their server
      iec60870_instances_sup.erl DynamicSupervisor for library-managed instances
      iec60870_data_model.erl    behaviour
      iec60870_dm_ets.erl        default ETS-backed data model
    iec60870_app.erl
    iec60870_sup.erl
```

`iec60870_asdu.hrl` lives in `include/` rather than `src/asdu/`: the records are
part of the public surface (user code assembling ASDUs by hand, section 8), and
`include/` is what `-include_lib("iec60870/include/...")` resolves to.

## 3. Supervision tree

One subtree per user-created server, grafted either under the library's
`iec60870_instances_sup` (via `iec60870:start_server/2`) or under the user's own
supervisor (via `iec60870_server:start_link/1`).

```
iec60870_sup                     one_for_one, app root
├── iec60870_registry            gen_server, ETS owner (names -> pids;
│                                also {rgroup_sup, Name} / {ctl, Name})
└── iec60870_instances_sup       DynamicSupervisor
    └── iec60870_server_sup      per server, rest_for_one
        ├── iec60870_rgroup_sup      one_for_one; the redundancy groups
        │   └── iec60870_rgroup      gen_statem, one per group: members, active
        │                            connection, bounded event buffer, replay
        └── iec60870_server_ctl      gen_server — config, callback module + state,
                                     command routing, data model handle; also
                                     starts the ranch listener (interim)
```

`rest_for_one`, children in start order. `rgroup_sup` is **first** so
`server_ctl` can resolve it (`{rgroup_sup, Name}` in `iec60870_registry` —
siblings started in one supervisor `init` cannot pass pids directly). Effects:

- `rgroup_sup` dies → `server_ctl` restarts too (rebuilds against fresh groups).
- `server_ctl` dies alone → the groups, their buffered events and the live
  connections **survive**; the listener is stopped and restarted (established
  sockets are unaffected).

Each redundancy group is the `owner` (section 4) of its member connections. The
listener is handed a resolver `fun((PeerIp) -> {ok, GroupPid} | {error, _})`
that `iec60870_104_conn` calls just after `ranch:handshake` — this is how a
connection is assigned to a group by peer address. Groups relay incoming ASDUs
and connection lifecycle events to `server_ctl` (`iec60870_server_ctl:relay/3`).

**Deferred (not in phase 5).** `server_ctl` still starts the `ranch` listener
itself rather than through a supervised `child_spec`, and still hosts the
default data model's `public` ETS table (`iec60870_dm_ets:init/1` runs in this
process) — so a standalone data-model process and a supervised listener /
`conn_sup` node are still future work, and point values do not survive a
`server_ctl` restart. Per-connection crashes are already isolated by ranch's
own connection supervisor.

## 4. APCI / connection state machine

`iec60870_104_conn`, a `gen_statem`, one per socket.

### Frame formats

```
APDU = APCI (6 octets) + ASDU (0..249 octets)      ; APDU max 253

APCI:  68  LEN  CF1 CF2 CF3 CF4
       │   │    └──────────────  control field, format-dependent
       │   └─ length of APDU minus the 2 start octets (1..253)
       └─ start

I-format  CF1.b0 = 0    send seq N(S) in CF1..CF2, recv seq N(R) in CF3..CF4  (carries ASDU)
S-format  CF1 = 0x01    recv seq N(R) in CF3..CF4                             (ack only)
U-format  CF1 = 0x03+   STARTDT / STOPDT / TESTFR, act or con                 (no seq)
```

### States

| State | Meaning | I-frames | On entry |
|---|---|---|---|
| `connected` | socket up, STARTDT not received (STOPDT state) | not sent; incoming rejected | start t3 |
| `active` | STARTDT_ACT received, STARTDT_CON sent — data transfer running | sent & processed | drain outbox |

Driven by U-frames (STARTDT/STOPDT/TESTFR act/con), I-frames, S-frames, and the
timers below. `STOPDT_ACT` → finish outstanding I-frames, send `STOPDT_CON`,
return to `connected`.

**`active_standby` is not a connection state.** A redundancy group with more
than one `active` member simply stops feeding the non-chosen ones its event
buffer (section 5); at the APCI layer they stay fully `active` and keep
answering their own direct requests (interrogation, commands). This is simpler
than a wire-level park and closer to how a hot-standby master actually behaves.

### Timers (defaults, all configurable)

| Timer | Default | Fires when | Action |
|---|---|---|---|
| t0 | 30 s | connection not established | abort connect (client side) |
| t1 | 15 s | sent I / U(TESTFR/STARTDT/STOPDT) not acknowledged | close connection |
| t2 | 10 s | I-frames received, no S-frame sent yet (t2 < t1) | send S-frame ack |
| t3 | 20 s | nothing received while idle | send TESTFR_ACT |

### Flow control

- `k` (default 12): max I-frames sent but not yet acknowledged. Window full ⇒ stop sending, wait for S/I ack.
- `w` (default 8, ≤ ⅔·k): send an S-frame after receiving `w` I-frames at the latest.
- 15-bit sequence numbers, modulo 32768. Per connection: V(S) send counter, V(R) receive counter, ack-state. Invalid N(R)/N(S) ⇒ close connection.

### Owner interface

`iec60870_104_conn` talks to a single **owner** process. The listener's `owner`
option is either a static pid (direct embedding, tests) or a
`fun((PeerIp) -> {ok, pid()} | {error, _})` resolved once per socket right after
`ranch:handshake` — phase 5 passes a fun that returns the connection's
`iec60870_rgroup`.

The owner drives transmission with `iec60870_104_conn:send_asdu/2,3` (an ASDU
leaves as an I-frame once `active` and the `k` window has room, otherwise it
waits in a bounded `outbox`) and receives, as `{iec60870, ConnPid, Payload}`:

| Payload | When |
|---|---|
| `activated` / `deactivated` | entered / left `active` (STARTDT / STOPDT done) |
| `{asdu, #asdu{}}` | a decoded incoming ASDU |
| `{released, Tag}` | the peer acknowledged the I-frame carrying a `send_asdu/3` tagged ASDU (highest tag; monotonic) |
| `{decode_error, Reason}` | an I-frame whose ASDU payload would not parse (connection kept) |
| `{outbox_overflow, N}` | `send_asdu` dropped the oldest queued ASDU |
| `{closed, Reason}` | connection gone: `t1_timeout`, `peer_closed`, `{socket_error, _}`, `{protocol_error, _}` |

`send_asdu/3` carries an opaque tag (the redundancy group passes its buffer
index); `send_asdu/2` is `/3` with `undefined` and is never echoed. Direct
command / interrogation replies from `server_ctl` use `/2` and go straight to
the requesting connection, bypassing the group buffer.

## 5. Redundancy groups

`iec60870_rgroup`, a `gen_statem`, one per group.

### Modes (`redundancy.mode`)

| Mode | Behaviour |
|---|---|
| `connection` | each accepted connection is its own group — classic multi-master, no redundancy |
| `single` | all connections share one group; exactly one `active` at a time |
| `multiple` | explicitly configured groups; connection matched to a group by peer IP, else the default group |

```erlang
redundancy => #{
  mode => multiple,
  buffer => 1000,                 %% default per-group bound (all modes)
  groups => [
    #{name => scada_a, match => [{ip, {10,0,0,0}, 24}], buffer => 5000},
    #{name => scada_b, match => [{ip, {10,1,0,5}, 32}]}
  ],
  default => #{buffer => 200}     %% unmatched peers; the `default' group always exists
}
```

`match` entries are `{ip, BaseAddr, PrefixLen}` (IPv4 or IPv6), tested in order,
first group to match wins (`iec60870_rgroup:match/3`). With `mode` absent the
default is `connection`, which preserves the pre-phase-5 multi-master behaviour.

### Active-connection arbitration

At most one member is fed the event buffer. When a member enters `active`
(STARTDT) while another already holds that role, `iec60870_rgroup` promotes the
newcomer and simply stops feeding the previous one (which stays open — see the
`active_standby` note in section 4). The controlling station is responsible for
the orderly STOPDT/STARTDT handover; the server also tolerates an abrupt switch
(dead TCP plus `STARTDT` on a sibling).

### Event buffer + switchover replay

- Each group owns an **ordered, bounded queue of ASDUs**, each with a monotonic
  index. Overflow: drop-oldest (the dropped index counts as released).
- New ASDUs are appended by `iec60870_server_ctl` (`iec60870_rgroup:enqueue/2`,
  one copy per group) and, if a connection is active, sent on immediately via
  `iec60870_104_conn:send_asdu/3` tagged with their index.
- `{released, Index}` from the active connection (the peer acknowledged the
  I-frame) drops every buffer entry `=< Index`.
- On promotion, the whole remaining buffer (everything past the last released
  index) is re-sent to the new active connection. Duplicates on the wire during
  switchover are expected and acceptable.
- While a group has **no** active connection, events keep accumulating up to the
  bound.
- The data-model overflow flag on drop is not raised yet (deferred).

## 6. Data model

Pluggable via the `iec60870_data_model` behaviour; the library ships
`iec60870_dm_ets` and uses it by default.

```erlang
%% init/terminate are plain behaviour callbacks — an implementation need not be
%% a process. iec60870_dm_ets keeps a `public` ETS table owned by whoever calls
%% init/1 (iec60870_server_ctl).
-callback init(Args :: term()) -> {ok, State}.
-callback terminate(State) -> ok.

%% current-value store (shared; read for interrogation & no-change suppression)
-callback read(State, Coa, Ioa) -> {ok, point()} | not_found.
-callback write(State, Coa, Ioa, point()) -> {ok, State, changed :: boolean()}.

%% interrogation: fold the interrogable points of (Coa, InterrogationGroup);
%% `station` visits every one, `1..16` only that group's. The fold function
%% sees each point's IOA (a point() does not carry its own address).
-callback fold(State, Coa, ig() | station,
               fun((Ioa, point(), Acc) -> Acc), Acc) -> Acc.
-callback coas(State) -> [Coa].

%% counters (for counter interrogation) — phase 7
-callback read_counter(State, Coa, Ioa) -> {ok, counter()} | not_found.
-callback freeze_counters(State, Coa, qcc()) -> {ok, State}.
```

`point()` is a map: `#{type := type_name(), value := term(),
quality := [quality_flag()], ts := ms_since_epoch | undefined,
group := 1..16 | undefined, qualifier => term()}` — see `iec60870_point`.
Integrated totals (`m_it_*`) are stored but not `interrogable`; cyclic /
background scan flags are deferred to phase 7.

`iec60870_data_model:is_significant_change/2` is the shared no-change policy: a
new IOA always counts; otherwise `write` reports `changed` only when the value
or the (order-independent) quality list differs. A bare timestamp refresh does
not count.

Two conceptually separate stores — do not conflate:

| Store | Scope | Purpose |
|---|---|---|
| current values | per common address, shared across the server | answer interrogation; suppress no-change spontaneous events |
| event queue | per redundancy group (§5) | spontaneous transmission + switchover replay |

## 7. Commands (done)

The library runs **all protocol mechanics**; the callback module performs **only
the semantic action** and may answer asynchronously. Implemented in
`iec60870_server_ctl` (`command/3`, `clock_sync/3` and helpers); the pure
decode/match/mirror pieces live in `iec60870_command`.

### Callback behaviour (`iec60870_server` behaviour)

```erlang
-callback init(Args) -> {ok, CbState}.

-callback select(iec60870_command:command(), CbState) ->
      {accept, CbState} | {reject, iec60870_cot:cot(), CbState}.

-callback execute(iec60870_command:command(), CbState) ->
      {ok, CbState}
    | {ok, term_info(), CbState}
    | {error, iec60870_cot:cot(), CbState}
    | {async, ref(), CbState}.          %% resolved by iec60870_server:command_result(Ref, Result)

-callback clock_sync(Coa, cp56(), CbState) ->
      {ok, CbState} | {error, iec60870_cot:cot(), CbState}.

-callback interrogation(Coa, qoi(), CbState) ->
      {ok, CbState}                     %% let the data model answer it (default)
    | {ok, [asdu_spec()], CbState}.     %% supply the dump explicitly

-callback counter_interrogation(Coa, qcc(), CbState) -> {ok, CbState}.

-callback connection_event(event(), CbState) -> {ok, CbState}.
      %% event() :: {up | down, peer()} | {activated | deactivated, group()}
```

`command()` is the decoded command map (maps at the public API, decision 5):
`#{type, coa, ioa, value, select, qualifier, orig_addr, test}` — `select`
mirrors the S/E bit, `qualifier` the rest (`#{select, qu}` for single / double
/ regulating step, `#{select, ql}` for the three setpoints). A `select` /
`execute` rejection's `Cot` is sent as the negative confirmation's cause of
transmission (typically `act_con`, or one of `unknown_type_id` /
`unknown_cot` / `unknown_coa` / `unknown_ioa`); an invalid `Cot` falls back to
`act_con` rather than crash the connection. No callback module, or one that
doesn't export `select/2` / `execute/2`, rejects every command — accepting by
default would be unsafe. A missing `clock_sync/3` instead **accepts** by
default, since acknowledging a clock sync has no unsafe side effect.

### Interrogation (C_IC_NA_1) — library-driven

1. recv `act` (COT 6) → validate COA / QOI
2. send `act_con` (COT 7), P/N negative if invalid
3. call `interrogation/3`, then stream the current values with COT
   `interrogated_station` (20) or `interrogated_group_n` (21–36), batched into ASDUs
4. send `act_term` (COT 10)

### Commands (C_SC/C_DC/C_RC/C_SE_NA/NB/NC_1)

- **Direct execute:** recv `act` (no prior select for that `{Coa, Ioa}`) →
  `execute/2` → `act_con` (7, P/N per result) → `act_term` (10) on success; a
  negative `act_con` sends no `act_term`.
- **Select-before-operate:** recv select (S/E = 1, `act`) → `select/2` →
  select `act_con` (positive starts the select timer, config key
  `select_timeout`, default 10 s) → recv operate (S/E = 0, `act`) → if it is
  identical to the selected object (`iec60870_command:matches/2` — same
  type/COA/IOA/value/qualifier, S/E bit disregarded) consume the select and
  run it as a direct execute; a mismatched operate is rejected (negative
  `act_con`) and the select stays armed for a correct retry; an operate that
  arrives after the timeout, with no matching select left, runs as a direct
  execute.
- `{async, Ref, _}` ⇒ positive `act_con` immediately, `act_term` withheld
  until `iec60870_server:command_result(Ref, ok | {error, Cot})` — `Ref` is
  bound to its server in `iec60870_registry` (`bind_command/2` /
  `command_owner/1` / `unbind_command/1`) so the 2-arity call can route
  without carrying a server reference; an unknown/already-resolved `Ref` is
  ignored. The connection process never blocks.
- `{ok, term_info(), CbState}`'s return information (COT 11/12 from the data
  model, for persistent commands) is accepted but not yet wired to the data
  model — treated the same as a plain `{ok, CbState}` for now.

### Clock sync (C_CS_NA_1)

recv → `clock_sync/3` → `act_con` (config key `clock_sync_confirm`, default
`true`, for masters that expect none — a rejection is still always sent).
Feeding the kept clock offset into the timestamping of subsequently generated
events is **not yet implemented** — a later phase threads it through
`iec60870_point:to_object/3`; today the callback only observes the time.

## 8. Sending information objects

### High level (default data model)

```erlang
iec60870_server:update(Server, {Coa, Ioa}, #{
    type    => m_me_nc_1,
    value   => 3.14,
    quality => [],   %% [] | [invalid, not_topical, blocked, substituted, overflow]
    ts      => erlang:system_time(millisecond)  %% omit for the "no timestamp" variant
}).
```

The library writes the current-value store and, **iff changed** (§6 —
value or quality differs), builds a spontaneous ASDU (COT 3) and enqueues it
into every redundancy group's buffer. On flush it batches objects of equal
`{type, COA, COT}` into single ASDUs (≤ 249 octets; SQ=0, or SQ=1 sequence for
contiguous IOAs — `iec60870_batch`), then hands them to each active connection
subject to its `k` window and t1.

Bulk form: `iec60870_server:update(Server, [{{Coa, Ioa}, Spec}, ...])`.

**Phase-3 interim.** There is no per-group buffer yet: `server_ctl` sends batched
ASDUs to every active connection immediately, and holds them in one bounded
drop-oldest queue (`redundancy.buffer`, default 1000) only while *no* connection
is active, flushing it on the next STARTDT.

### Low level (escape hatch)

```erlang
iec60870_server:send_asdu(Server, GroupSelector,
    #{type => ..., coa => ..., cot => ..., objects => [...]}).
```

`GroupSelector :: all | {group, Name} | {coa, Coa}`. Bypasses the current-value
store; still respects buffering and flow control.

### Builders

`iec60870_asdu:single_point/3`, `measured_value_short/4`, `step_position/4`, …
return the internal `#object{}`; used by both the codec and user code assembling
ASDUs by hand.

## 9. Public API

```erlang
{ok, Pid} = iec60870:start_server(my_rtu, #{
    transport => {tcp, [{port, 2404}, {ip, {0,0,0,0}}]},
    common_addresses => [1],
    redundancy => #{mode => single, buffer => 5000},
    data_model => {iec60870_dm_ets, #{points => "priv/points.eterm"}},
    callback   => {my_rtu_app, #{}},
    select_timeout     => 10000,   %% ms; select-before-operate (section 7)
    clock_sync_confirm => true,    %% send act_con for C_CS_NA_1 (section 7)
    params     => #{k => 12, w => 8, t1 => 15000, t2 => 10000, t3 => 20000,
                    max_asdu => 249, coa_size => 2, ioa_size => 3, cot_size => 2,
                    orig_addr => enabled}
}).

iec60870_server:update(my_rtu, {1, 100}, #{type => m_sp_tb_1, value => true, qds => []}).
iec60870_server:command_result(Ref, ok).
iec60870:stop_server(my_rtu).
```

`Name :: atom() | {via, Mod, Term} | pid()`. `iec60870_server:start_link/1`
returns the per-server supervisor for embedding in a user tree;
`iec60870:start_server/2` puts it under the library.

## 10. Type IDs — v1

| Dir | Type IDs |
|---|---|
| Monitor | M_SP_NA_1 (1), M_SP_TB_1 (30), M_DP_NA_1 (3), M_DP_TB_1 (31), M_ST_NA_1 (5), M_ME_NA_1 (9), M_ME_NB_1 (11), M_ME_NC_1 (13), M_ME_TD_1 (34), M_ME_TE_1 (35), M_ME_TF_1 (36), M_IT_NA_1 (15), M_IT_TB_1 (37) |
| Control | C_SC_NA_1 (45), C_DC_NA_1 (46), C_RC_NA_1 (47), C_SE_NA_1 / NB_1 / NC_1 (48–50) |
| System | C_IC_NA_1 (100), C_CI_NA_1 (101), C_RD_NA_1 (102), C_CS_NA_1 (103), C_TS_TA_1 (107), M_EI_NA_1 (70) |

CP56Time2a only for timestamped variants; CP24Time2a / CP16Time2a not in v1.

## 11. TLS (IEC 62351-3)

`transport => {tls, SslOpts}`. Defaults: `versions [tlsv1.2, tlsv1.3]`,
`verify_peer`, `fail_if_no_peer_cert true` (mutual auth is the field norm),
explicit `ciphers`, optional CRL / peer-cert allowlist via `verify_fun`. Secure
port convention 19998. Delivered through `ranch_ssl` — mostly pass-through of OTP
`ssl` options with strict defaults and a `verify_none` opt-out for lab use.

## 12. Decisions

| # | Question | Decision |
|---|---|---|
| 1 | Edition | Edition 2 (2006) — redundancy, CP56Time2a |
| 2 | Acceptor | `ranch` (brings the TLS transport) |
| 3 | Redundancy scope | all three modes from v1 |
| 4 | Data model | pluggable behaviour + default ETS implementation |
| 5 | Data representation | maps at the public API, records internally |
| 6 | Type ID scope | table in §10 |
| 7 | Async commands | yes — `{async, Ref}` + `command_result/2` |
| 8 | Tooling | rebar3, OTP 26+ |

## 13. Implementation phases

0. **Skeleton (done):** rebar3 umbrella, CI matrix (OTP 26–28) running
   compile + xref + eunit + ct + dialyzer, `iec60870_asdu.hrl`, `ranch` dep,
   Apache-2.0 licence. App boots to `iec60870_sup` →
   {`iec60870_registry`, `iec60870_instances_sup`}.
1. **ASDU codec (done):** `iec60870_asdu` (DUI framing, `encode/2` + `decode/2`
   over configurable COT/COA/IOA widths, object builders), `iec60870_type`
   (type-id map + per-element payload codec for all §10 types), `iec60870_cot`,
   `iec60870_cp56`. eunit spec byte-vectors + `proper` full round-trip
   (`decode(encode(A)) == A`) across every type, both structure qualifiers, all
   field widths.
2. **APCI + single connection (done):** `iec60870_104_apci` (I/S/U frame codec
   + 15-bit sequence arithmetic), `iec60870_104_conn` (`gen_statem`:
   `connected`/`active`, STARTDT/STOPDT/TESTFR, k/w window, t1/t2/t3, N(S)/N(R)
   validation, bounded outbox), thin `iec60870_104_listener` over `ranch`. eunit
   spec byte-vectors + `proper` (frame round-trip, sequence arithmetic);
   `common_test` drives the state machine over raw client sockets. Owner seam:
   a per-listener pid (see §4).
3. **Data model + interrogation + spontaneous path (done):**
   `iec60870_data_model` behaviour + shared no-change policy; `iec60870_dm_ets`
   default (`public` ETS, `{COA,IOA}` -> point map, preload); `iec60870_point`
   (point map <-> `#object{}`); `iec60870_batch` (pack objects into ≤ 249-octet
   ASDUs, SQ=1 for contiguous runs); the server backbone —
   `iec60870:start_server/2`, `iec60870_server` (API + callback behaviour),
   `iec60870_server_sup`, `iec60870_server_ctl` (the connection owner: runs the
   `ranch` listener, answers station / group interrogation from the data model,
   turns `update/3` into batched spontaneous ASDUs with a bounded hold-until-
   active buffer). eunit for batch / point / dm_ets; `common_test`
   (`iec60870_server_SUITE`) drives interrogation and the spontaneous path over
   a raw client socket.
4. **Commands (done):** `iec60870_command` (pure decode/match/mirror);
   `iec60870_server_ctl` runs direct execute and select-before-operate for
   C_SC/C_DC/C_RC/C_SE_NA/NB/NC_1 (select timeout, execute-matches-select),
   async execute via `{async, Ref}` + `iec60870_server:command_result/2`
   (`Ref` routed through a small binding in `iec60870_registry`), and clock
   sync (C_CS_NA_1, with a no-`act_con` config option — the offset-into-
   event-timestamps part is deferred). eunit for the pure helpers
   (`iec60870_command_tests`); `iec60870_server_SUITE` drives direct/SBO/
   async commands and clock sync over a raw client socket.
5. **Redundancy (done):** `iec60870_rgroup` (`gen_statem` — members, active
   connection, bounded per-group event buffer with index/`{released, _}`
   accounting and switchover replay) under `iec60870_rgroup_sup` (static groups
   for `single`/`multiple`, one temporary group per connection for
   `connection`); `iec60870_104_conn` gains `send_asdu/3` tags + a resolver-fun
   `owner`; `iec60870_server_ctl` broadcasts spontaneous ASDUs to every group
   and no longer buffers itself. `active_standby` is a group-level property, not
   a connection state; the standalone data-model / supervised-listener nodes
   stay deferred. eunit `iec60870_rgroup_tests` (peer-address matcher);
   multi-socket `iec60870_rgroup_SUITE` (all three modes + switchover replay).
6. TLS transport + 62351-3 defaults.
7. Counter interrogation, end-of-init, test command, background scan, read command, parameter of measured value.
8. Docs, `examples/`, interop test vs `lib60870` / a real master.

Then: **client** (reuses ASDU + APCI + a group-less connection). Then: **101**
(new link layer, same ASDU layer).
