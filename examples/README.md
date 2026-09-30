# Examples

Runnable examples against the public API (docs/DESIGN.md section 9). These
are plain modules, not part of the `iec60870` app or its build — compile them
by hand from a shell that already has the app on its code path.

## `simple_rtu`

A minimal 104 server: one measured value (IOA 200, a simulated temperature
that walks every 5s and is sent as a spontaneous update on change) and one
remote-controllable switch (IOA 100, a C_SC_NA_1 single command — both direct
execute and select-before-operate — that's mirrored back into the data model
on receipt). Common address 1, listening on port 2404.

```
$ rebar3 shell
1> c("examples/simple_rtu/simple_rtu_callback.erl").
2> c("examples/simple_rtu/simple_rtu.erl").
3> simple_rtu:start().
{ok,<0.123.0>}
```

Point a controlling station at `localhost:2404`, common address 1. Any
IEC 60870-5-104 test master works, including:

- the interop driver built for `iec60870_interop_SUITE`
  (`apps/iec60870/test/interop/master_driver.c`; each `rebar3 ct` run of that
  suite compiles it into the run's `priv_dir` under `_build/test/logs/`, and
  it takes `<host> <port> <scenario>`, e.g. `127.0.0.1 2404 interrogate`);
- `lib60870`'s own `cs104_client` example, built from
  <https://github.com/mz-automation/lib60870>.

To watch a spontaneous update go out immediately instead of waiting up to 5s:

```
4> simple_rtu:tick().
```

Stop it with `simple_rtu:stop().`.
