%%% @doc TLS transport (IEC 62351-3, docs/DESIGN.md section 11): a ranch
%%% listener runs {@link iec60870_104_conn} over `ranch_ssl'; the suite plays
%%% the controlling station with a raw `ssl' client, using self-signed test
%%% certificates generated once per suite by `public_key:pkix_test_data/1'
%%% (server_chain / client_chain cross-trust each other's root).
-module(iec60870_104_tls_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("iec60870/include/iec60870_asdu.hrl").

-export([suite/0, all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).

-export([mutual_tls_startdt_and_asdu/1, client_without_cert_rejected/1,
         verify_none_allows_certless_client/1, wrong_cipher_rejected/1]).

-define(PARAMS, #{t1 => 2000, t2 => 1000, t3 => 5000}).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [mutual_tls_startdt_and_asdu, client_without_cert_rejected,
     verify_none_allows_certless_client, wrong_cipher_rejected].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(iec60870),
    Spec = #{server_chain => #{root => [{key, {rsa, 2048, 65537}}],
                               intermediates => [],
                               peer => [{key, {rsa, 2048, 65537}}]},
             client_chain => #{root => [{key, {rsa, 2048, 65537}}],
                               intermediates => [],
                               peer => [{key, {rsa, 2048, 65537}}]}},
    #{server_config := ServerCerts, client_config := ClientCerts} =
        public_key:pkix_test_data(Spec),
    [{server_certs, ServerCerts}, {client_certs, ClientCerts} | Config].

end_per_suite(_Config) ->
    ok.

init_per_testcase(TC, Config) ->
    ServerCerts = ?config(server_certs, Config),
    Extra = extra_transport_opts(TC),
    {ok, _} = iec60870_104_listener:start(
                TC, #{owner => self(), transport => tls,
                      transport_opts => ServerCerts ++
                          [{ip, {127, 0, 0, 1}}, {port, 0} | Extra],
                      params => ?PARAMS}),
    Port = iec60870_104_listener:port(TC),
    [{listener, TC}, {port, Port} | Config].

end_per_testcase(TC, _Config) ->
    _ = iec60870_104_listener:stop(TC),
    ok.

%% `verify_none_allows_certless_client' starts its listener opted out of
%% mutual auth; every other case uses the library's strict default.
extra_transport_opts(verify_none_allows_certless_client) ->
    [{verify, verify_none}];
extra_transport_opts(_TC) ->
    [].

%%%===================================================================
%%% Cases
%%%===================================================================

%% The full APCI layer (STARTDT, I-frame ASDU exchange) works transparently
%% over `ranch_ssl' once both sides present a certificate the other trusts.
mutual_tls_startdt_and_asdu(Config) ->
    S = connect(Config, client_opts(Config)),
    ok = send_frame(S, {u, startdt_act}),
    {u, startdt_con} = recv_frame(S),
    Conn = expect_activated(),
    Asdu = monitored_asdu(1),
    ok = iec60870_104_conn:send_asdu(Conn, Asdu),
    {i, 0, 0, Bin} = recv_frame(S),
    {ok, Asdu, <<>>} = iec60870_asdu:decode(Bin),
    ok = ssl:close(S).

%% Default `fail_if_no_peer_cert => true': a client offering no certificate
%% never reaches the `active' state. In TLS 1.3 the server sends the whole
%% first flight (through its own Finished) before ever seeing the client's
%% Certificate, so a client-side `ssl:connect/4' can return `{ok, _}' even
%% though the server-side `ranch:handshake/1' (and so {@link
%% iec60870_104_conn} `init/1') fails and the connection never runs —
%% `activated' never arriving is the reliable signal, not the client's
%% `connect' return value.
client_without_cert_rejected(Config) ->
    Port = ?config(port, Config),
    Opts = [binary, {active, false}, {verify, verify_none}],
    case ssl:connect({127, 0, 0, 1}, Port, Opts, 2000) of
        {ok, S} -> catch send_frame(S, {u, startdt_act});
        {error, _} -> ok
    end,
    ok = expect_no_activated(500).

%% `{verify, verify_none}' in `transport_opts' opts a listener out of mutual
%% auth for lab use — a certless client now completes the handshake.
verify_none_allows_certless_client(Config) ->
    Port = ?config(port, Config),
    Opts = [binary, {active, false}, {verify, verify_none}],
    {ok, S} = ssl:connect({127, 0, 0, 1}, Port, Opts, 2000),
    ok = send_frame(S, {u, startdt_act}),
    {u, startdt_con} = recv_frame(S),
    _Conn = expect_activated(),
    ok = ssl:close(S).

%% A client restricted to a cipher outside the server's strict default list
%% cannot agree on a suite with it.
wrong_cipher_rejected(Config) ->
    Opts = [{ciphers, ["ECDHE-RSA-AES256-SHA384"]}, {versions, ['tlsv1.2']}
            | client_opts(Config)],
    Port = ?config(port, Config),
    {error, _} = ssl:connect({127, 0, 0, 1}, Port, Opts, 2000),
    ok = expect_no_activated(500).

%%%===================================================================
%%% Client helpers
%%%===================================================================

%% Peer identity here rests on the mutual cert-chain trust set up by
%% `pkix_test_data/1', not on DNS-name matching (irrelevant to a fixed RTU/
%% master pair) — the test cert's SAN doesn't name the loopback address, so
%% the usual hostname check is turned off.
client_opts(Config) ->
    ClientCerts = ?config(client_certs, Config),
    [binary, {active, false},
     {customize_hostname_check, [{match_fun, fun(_Ref, _Pres) -> true end}]}
     | ClientCerts].

connect(Config, ExtraOpts) ->
    Port = ?config(port, Config),
    {ok, S} = ssl:connect({127, 0, 0, 1}, Port, ExtraOpts, 2000),
    S.

expect_activated() ->
    receive
        {iec60870, Conn, activated} -> Conn
    after 2000 -> ct:fail(no_activated)
    end.

expect_no_activated(Timeout) ->
    receive
        {iec60870, _, activated} -> ct:fail(unexpected_activated)
    after Timeout -> ok
    end.

send_frame(S, Frame) ->
    ssl:send(S, iec60870_104_apci:encode(Frame)).

recv_frame(S) -> recv_frame(S, 2000).

recv_frame(S, Timeout) ->
    {ok, <<16#68, Len>>} = ssl:recv(S, 2, Timeout),
    {ok, Body} = ssl:recv(S, Len, Timeout),
    {ok, Frame, <<>>} = iec60870_104_apci:decode(<<16#68, Len, Body/binary>>),
    Frame.

monitored_asdu(Ioa) ->
    #asdu{type = m_sp_na_1, cot = spontaneous, coa = 1,
          objects = [#object{ioa = Ioa, value = true, quality = []}]}.
