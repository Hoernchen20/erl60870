-module(iec60870_104_listener).
-moduledoc """
IEC 60870-5-104 listener — a thin wrapper over `ranch:start_listener/5`
that accepts TCP (or TLS) connections and runs `m:iec60870_104_conn` on
each (`docs/DESIGN.md` section 3).

One listener, one static set of protocol options. The `owner` is either a
static pid (every accepted connection reports to it) or a
`fun((PeerIp) -> {ok, pid()} | {error, term()})` that `m:iec60870_104_conn`
resolves per socket after the handshake — that is how phase 5 assigns each
connection to its redundancy group by peer address. `child_spec/2` is
provided so a server subtree can supervise the listener.

`transport => tls` runs over `ranch_ssl`; its `transport_opts` are filled
in with the IEC 62351-3 defaults by `iec60870_tls:server_opts/1` before
being handed to `ranch` (`docs/DESIGN.md` section 11). No further change is
needed here or in `m:iec60870_104_conn` — `ranch_ssl` implements the same
`ranch_transport` behaviour as `ranch_tcp`.
""".

-export([start/2, stop/1, port/1, child_spec/2]).

-export_type([opts/0, owner/0]).

-type owner() :: pid()
               | fun((inet:ip_address()) -> {ok, pid()} | {error, term()}).

-type opts() :: #{owner := owner(),
                  transport => tcp | tls | module(),
                  transport_opts => [term()],
                  params => map()}.

-doc "Start (and register with ranch) a listener named `Name`.".
-spec start(ranch:ref(), opts()) -> {ok, pid()} | {error, term()}.
start(Name, Opts) ->
    {Transport, RanchOpts, ProtoOpts} = translate(Opts),
    ranch:start_listener(Name, Transport, RanchOpts, iec60870_104_conn, ProtoOpts).

-spec stop(ranch:ref()) -> ok | {error, not_found}.
stop(Name) ->
    ranch:stop_listener(Name).

-doc "The TCP port the listener is bound to (useful with an ephemeral port 0).".
-spec port(ranch:ref()) -> inet:port_number().
port(Name) ->
    ranch:get_port(Name).

-doc "A supervisor child spec for embedding the listener in a server subtree.".
-spec child_spec(ranch:ref(), opts()) -> supervisor:child_spec().
child_spec(Name, Opts) ->
    {Transport, RanchOpts, ProtoOpts} = translate(Opts),
    ranch:child_spec(Name, Transport, RanchOpts, iec60870_104_conn, ProtoOpts).

translate(#{owner := Owner} = Opts) when is_pid(Owner); is_function(Owner, 1) ->
    RawTOpts = maps:get(transport_opts, Opts, []),
    {Transport, TOpts} = case maps:get(transport, Opts, tcp) of
                             tcp -> {ranch_tcp, RawTOpts};
                             tls -> {ranch_ssl, iec60870_tls:server_opts(RawTOpts)};
                             Mod when is_atom(Mod) -> {Mod, RawTOpts}
                         end,
    RanchOpts = #{socket_opts => TOpts},
    ProtoOpts = #{owner => Owner, params => maps:get(params, Opts, #{})},
    {Transport, RanchOpts, ProtoOpts}.
