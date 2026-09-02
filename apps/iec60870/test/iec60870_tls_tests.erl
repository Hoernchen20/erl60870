%%% @doc IEC 62351-3 default merging (docs/DESIGN.md section 11).
-module(iec60870_tls_tests).

-include_lib("eunit/include/eunit.hrl").

-define(SECURE_PORT, 19998).

defaults_filled_in_when_absent_test() ->
    Opts = iec60870_tls:server_opts([{certfile, "server.pem"}]),
    ?assertEqual(verify_peer, proplists:get_value(verify, Opts)),
    ?assertEqual(true, proplists:get_value(fail_if_no_peer_cert, Opts)),
    ?assertEqual(['tlsv1.2', 'tlsv1.3'], proplists:get_value(versions, Opts)),
    ?assertEqual(?SECURE_PORT, proplists:get_value(port, Opts)),
    ?assert(is_list(proplists:get_value(ciphers, Opts))),
    ?assert(length(proplists:get_value(ciphers, Opts)) > 0),
    %% the caller's own option is untouched
    ?assertEqual("server.pem", proplists:get_value(certfile, Opts)).

caller_options_win_test() ->
    Opts = iec60870_tls:server_opts(
             [{versions, ['tlsv1.3']}, {ciphers, ["TLS_AES_128_GCM_SHA256"]},
              {port, 2404}, {fail_if_no_peer_cert, false}]),
    ?assertEqual(['tlsv1.3'], proplists:get_value(versions, Opts)),
    ?assertEqual(["TLS_AES_128_GCM_SHA256"], proplists:get_value(ciphers, Opts)),
    ?assertEqual(2404, proplists:get_value(port, Opts)),
    %% verify defaulted to verify_peer, but the explicit fail_if_no_peer_cert
    %% override is kept rather than clobbered
    ?assertEqual(verify_peer, proplists:get_value(verify, Opts)),
    ?assertEqual(false, proplists:get_value(fail_if_no_peer_cert, Opts)).

verify_none_skips_fail_if_no_peer_cert_default_test() ->
    Opts = iec60870_tls:server_opts([{verify, verify_none}]),
    ?assertEqual(verify_none, proplists:get_value(verify, Opts)),
    ?assertNot(proplists:is_defined(fail_if_no_peer_cert, Opts)).

verify_fun_passed_through_test() ->
    Fun = {fun(_, _, S) -> {valid, S} end, []},
    Opts = iec60870_tls:server_opts([{verify_fun, Fun}]),
    ?assertEqual(Fun, proplists:get_value(verify_fun, Opts)),
    %% still defaults to mutual auth alongside the caller's verify_fun
    ?assertEqual(verify_peer, proplists:get_value(verify, Opts)),
    ?assertEqual(true, proplists:get_value(fail_if_no_peer_cert, Opts)).

empty_opts_test() ->
    Opts = iec60870_tls:server_opts([]),
    ?assertEqual(5, length(Opts)).
