%%% @doc TLS transport defaults for IEC 62351-3 (docs/DESIGN.md section 11).
%%%
%%% {@link iec60870_104_listener} routes a `{tls, SslOpts}' transport config
%%% through {@link server_opts/1} before handing it to `ranch_ssl' as
%%% `socket_opts'. For every option the caller didn't already set, it fills in
%%% the IEC 62351-3 defaults — TLS 1.2/1.3 only, mutual authentication
%%% (`verify_peer' + `fail_if_no_peer_cert'), a forward-secret AEAD cipher
%%% list, and the secure-104 port convention (19998). Caller-supplied options
%%% always win, including CRL checking or a peer-cert allowlist via
%%% `verify_fun' — that is plain OTP `ssl' pass-through, not implemented here.
%%% Certificates (`cert(file)' / `key(file)' / `cacerts(file)') are always the
%%% caller's; there is no library default for those.
%%%
%%% Passing `{verify, verify_none}' explicitly opts out of mutual auth (lab
%%% use only) — the `fail_if_no_peer_cert' default is then skipped rather than
%%% forced back on top of it.
-module(iec60870_tls).

-export([server_opts/1]).

-define(SECURE_PORT, 19998).

%% TLS 1.2 names (OpenSSL style) and TLS 1.3 names (RFC style) coexist in one
%% `ciphers' list — `ssl' matches each against whichever version the
%% handshake actually negotiates. AEAD only, forward secrecy only (ECDHE, or
%% a TLS 1.3 suite, which is PFS by construction).
-define(CIPHERS,
        ["TLS_AES_256_GCM_SHA384",
         "TLS_CHACHA20_POLY1305_SHA256",
         "TLS_AES_128_GCM_SHA256",
         "ECDHE-ECDSA-AES256-GCM-SHA384",
         "ECDHE-RSA-AES256-GCM-SHA384",
         "ECDHE-ECDSA-CHACHA20-POLY1305",
         "ECDHE-RSA-CHACHA20-POLY1305",
         "ECDHE-ECDSA-AES128-GCM-SHA256",
         "ECDHE-RSA-AES128-GCM-SHA256"]).

%% @doc Fill in the IEC 62351-3 defaults for every option `Opts' doesn't
%% already set.
-spec server_opts(ranch_ssl:opts()) -> ranch_ssl:opts().
server_opts(Opts) when is_list(Opts) ->
    Verify = proplists:get_value(verify, Opts, verify_peer),
    Defaults = [{verify, verify_peer},
                {versions, ['tlsv1.2', 'tlsv1.3']},
                {ciphers, ?CIPHERS},
                {port, ?SECURE_PORT}]
        ++ [{fail_if_no_peer_cert, true} || Verify =:= verify_peer],
    lists:foldl(fun({Key, Default}, Acc) ->
                    case proplists:is_defined(Key, Acc) of
                        true -> Acc;
                        false -> Acc ++ [{Key, Default}]
                    end
                end, Opts, Defaults).
