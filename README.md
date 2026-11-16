# iec60870

[![CI](https://github.com/Hoernchen20/erl60870/actions/workflows/ci.yml/badge.svg)](https://github.com/Hoernchen20/erl60870/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

An Erlang/OTP library for the **IEC 60870-5** telecontrol protocol family,
starting with an **IEC 60870-5-104 server** (controlled station / RTU side).

> **Status: 0.2.0, early release.** The 104 server is complete and
> tested against a third-party master ([lib60870](https://github.com/mz-automation/lib60870)).
> The public API may still change before 1.0. The 104 client and
> IEC 60870-5-101 (serial) are not implemented yet (see [Roadmap](#roadmap)).

## Features

- **ASDU codec** for the whole v1 type set: single, double, and step
  position points; normalized, scaled, and float measurands; integrated
  totals; commands; system and parameter types. COT, common address, and
  IOA field widths are configurable. See [docs/CONFORMANCE.md](docs/CONFORMANCE.md)
  for the full table.
- **104 transport**: APCI state machine with k/w flow control and t1/t2/t3
  timers, built on [ranch](https://github.com/ninenines/ranch).
- **TLS** with IEC 62351-3 defaults: TLS 1.2/1.3, mutual authentication, and
  AEAD cipher suites with forward secrecy.
- **Station, group, and counter interrogation**, plus spontaneous and
  background-scan transmission. Updates are batched into SQ=0 or SQ=1 ASDUs.
- **Commands**: single, double, and regulating-step commands and set-points,
  either direct execute or select-before-operate (with a select timeout).
  Callbacks can confirm asynchronously.
- **System functions**: clock synchronization, read command, test command,
  end of initialization, and parameter of measured value.
- **Redundancy groups**: one group per connection, one shared group, or
  groups selected by peer IP. Buffered events are replayed on switchover.
- **Pluggable data model**: implement the `iec60870_data_model` behaviour,
  or use the built-in ETS implementation.

## Installation

The library isn't on Hex yet. Add it as a git dependency in `rebar.config`.
The OTP application lives in `apps/iec60870`, so use `git_subdir`:

```erlang
{deps, [
    {iec60870, {git_subdir, "https://github.com/Hoernchen20/erl60870.git",
                {tag, "v0.2.0"}, "apps/iec60870"}}
]}.
```

Requires **Erlang/OTP 27 or newer**. The only runtime dependency is `ranch`
2.x.

## Quick start

Start a server on port 2404 with common address 1 and one single-point
value, then change that value. The change goes out to connected masters as
a spontaneous ASDU:

```erlang
{ok, _} = application:ensure_all_started(iec60870),
{ok, _} = iec60870:start_server(my_rtu, #{
    transport => {tcp, [{port, 2404}]},
    common_addresses => [1],
    data_model => {iec60870_dm_ets, #{
        points => [{{1, 100}, #{type => m_sp_na_1, value => false}}]
    }},
    callback => {my_rtu_callback, #{}}
}),
ok = iec60870_server:update(my_rtu, {1, 100}, #{type => m_sp_na_1, value => true}).
```

`my_rtu_callback` implements the `iec60870_server` behaviour. It decides
whether to accept commands, clock sync, parameter writes, and so on. Only
`init/1` is required. If the callback doesn't handle commands, they're
rejected; clock sync is accepted by default.

```erlang
-module(my_rtu_callback).
-behaviour(iec60870_server).
-export([init/1, execute/2]).

init(Args) -> {ok, Args}.

execute(#{type := c_sc_na_1, coa := Coa, ioa := Ioa, value := V}, State) ->
    %% drive the real output here, then reflect the new state
    ok = iec60870_server:update(my_rtu, {Coa, Ioa}, #{type => m_sp_na_1, value => V}),
    {ok, State};
execute(_Command, State) ->
    {error, unknown_ioa, State}.
```

For a complete runnable example with a simulated measurand and a switch that
supports select-before-operate, see [examples/simple_rtu](examples/simple_rtu)
and [examples/README.md](examples/README.md).

### TLS

Use the `tls` transport and pass the usual `ssl` options. Any option you
leave out gets an IEC 62351-3 default, including port 19998 and
`verify_peer`:

```erlang
transport => {tls, [{certfile, "server.pem"}, {keyfile, "server.key"},
                    {cacertfile, "ca.pem"}]}
```

## Documentation

- **API reference**: written inline as `-moduledoc` / `-doc` attributes.
  In an Erlang shell, use `h(iec60870_server)`. To build the HTML version,
  run `rebar3 ex_doc`; output goes to `apps/iec60870/doc/`.
- **[docs/DESIGN.md](docs/DESIGN.md)**: architecture, supervision tree,
  connection state machine, callback contract, and the reasoning behind
  design decisions.
- **[docs/CONFORMANCE.md](docs/CONFORMANCE.md)**: supported type IDs, field
  widths, timer defaults, redundancy modes, and TLS defaults.

## Development

```sh
rebar3 compile
rebar3 check      # compile + eunit + xref + dialyzer
rebar3 ct         # common_test suites
rebar3 ex_doc     # HTML docs (OTP 27, or 28.1+)
```

Run `rebar3 ct` on its own, not as part of the `check` alias. CI runs every
step separately on OTP 27 and 28.

### Interop test

`iec60870_interop_SUITE` tests the server against lib60870's real CS104
master instead of a hand-written socket client. On the first run it
downloads and builds a pinned lib60870 release into a local cache. This
needs `git`, `cmake`, `make`, `gcc`, and network access. If any of those is
missing, the suite is skipped:

```sh
rebar3 ct --suite=apps/iec60870/test/iec60870_interop_SUITE
```

## Roadmap

- [x] IEC 60870-5-104 **server**, including TLS and redundancy groups (0.1.0)
- [x] Point removal at runtime: `iec60870_server:remove/2` (0.2.0)
- [ ] IEC 60870-5-104 **client** (controlling station)
- [ ] IEC 60870-5-101 (serial link layer on top of the same ASDU layer)
- [ ] Apply the clock-sync offset to generated timestamps
- [ ] Publish on Hex

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
