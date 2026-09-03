# iec60870

An Erlang/OTP library for the IEC 60870-5 telecontrol protocol family.

**Status:** early development. The design is settled — see
[docs/DESIGN.md](docs/DESIGN.md) — and implementation proceeds in phases. A
104 **server** works end to end today: station / group / counter
interrogation, spontaneous and background-scan data from a pluggable data
model, commands (direct execute and select-before-operate), clock sync, the
read and test commands, end-of-initialization, parameter writes, redundancy
groups with switchover replay, and TLS (IEC 62351-3 defaults). The 104
**client** and **IEC 60870-5-101** are next.

## Roadmap

| Phase | Deliverable |
|------:|-------------|
| 0 | Project skeleton, CI, ASDU record header |
| 1 | ASDU wire codec (all v1 type ids) |
| 2 | IEC 60870-5-104 APCI + single-connection state machine |
| 3 | Default ETS data model, interrogation, spontaneous transmission |
| 4 | Commands: single / double / setpoint, direct + select-before-operate, clock sync |
| 5 | Redundancy groups + switchover replay |
| 6 | TLS transport (IEC 62351-3) |
| 7 | Counter interrogation, remaining system functions |
| **8** | Docs, examples, interop tests — *this phase* |

Then: the 104 **client**, then **IEC 60870-5-101** (a new serial link layer over
the same ASDU layer).

## Quick start

```erlang
{ok, _} = iec60870:start_server(my_rtu, #{
    transport => {tcp, [{port, 2404}]},
    common_addresses => [1],
    data_model => {iec60870_dm_ets, #{
        points => [{{1, 100}, #{type => m_sp_na_1, value => false}}]
    }},
    callback => {my_rtu_callback, #{}}
}),
iec60870_server:update(my_rtu, {1, 100}, #{type => m_sp_na_1, value => true}).
```

`my_rtu_callback` implements the `iec60870_server` behaviour (see its module
doc, or [docs/DESIGN.md](docs/DESIGN.md) section 7) to accept commands, clock
sync, etc. See [`examples/simple_rtu`](examples/simple_rtu) for a complete,
runnable version of the above with a remote-controllable point.

## Interop testing

`apps/iec60870/test/iec60870_interop_SUITE.erl` drives a live server with
[`lib60870`](https://github.com/mz-automation/lib60870)'s real CS104 master
implementation rather than a hand-rolled socket client. It fetches and builds
a pinned `lib60870` release into a local cache on first run (needs `git`,
`cmake`, `make`, `gcc` and network access to GitHub) and skips cleanly if any
of that isn't available:

```
rebar3 ct --suite=apps/iec60870/test/iec60870_interop_SUITE
```

## Building

```
rebar3 compile
rebar3 check      # compile + xref + dialyzer + eunit
rebar3 ct         # common_test suites, including the interop one above
```

Requires Erlang/OTP 26 or newer.

## License

Apache-2.0 — see [LICENSE](LICENSE).
