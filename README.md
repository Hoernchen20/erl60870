# iec60870

An Erlang/OTP library for the IEC 60870-5 telecontrol protocol family.

**Status:** early development. The design is settled — see
[docs/DESIGN.md](docs/DESIGN.md) — and implementation proceeds in phases.
Nothing here is usable yet.

## Roadmap

| Phase | Deliverable |
|------:|-------------|
| **0** | Project skeleton, CI, ASDU record header — *current* |
| 1 | ASDU wire codec (all v1 type ids) |
| 2 | IEC 60870-5-104 APCI + single-connection state machine |
| 3 | Default ETS data model, interrogation, spontaneous transmission |
| 4 | Commands: single / double / setpoint, direct + select-before-operate, clock sync |
| 5 | Redundancy groups + switchover replay |
| 6 | TLS transport (IEC 62351-3) |
| 7 | Counter interrogation, remaining system functions |
| 8 | Docs, examples, interop tests |

Then: the 104 **client**, then **IEC 60870-5-101** (a new serial link layer over
the same ASDU layer).

## Building

```
rebar3 compile
rebar3 check      # compile + xref + dialyzer + eunit
```

Requires Erlang/OTP 26 or newer.

## License

Apache-2.0 — see [LICENSE](LICENSE).
