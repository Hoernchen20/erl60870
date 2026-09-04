-module(simple_rtu).
-moduledoc """
Runnable example: a minimal RTU with one measured value (IOA 200, a
simulated temperature) and one remote-controllable switch (IOA 100),
`docs/DESIGN.md` section 9 config shape. See `examples/README.md` for how
to run it and drive it with a test master.
""".

-export([start/0, stop/0, tick/0]).

-define(SERVER, simple_rtu).
-define(COA, 1).

start() ->
    {ok, _} = application:ensure_all_started(iec60870),
    {ok, _Pid} = iec60870:start_server(?SERVER, #{
        transport => {tcp, [{port, 2404}, {ip, {0, 0, 0, 0}}]},
        common_addresses => [?COA],
        redundancy => #{mode => single},
        data_model => {iec60870_dm_ets, #{
            points => [{{?COA, 100}, #{type => m_sp_tb_1, value => false, group => 1}},
                       {{?COA, 200}, #{type => m_me_nc_1, value => 21.5, group => 1}}]
        }},
        callback => {simple_rtu_callback, #{server => ?SERVER}},
        clock_sync_confirm => true,
        coi => 0
    }),
    %% A real RTU would call `iec60870_server:update/3' from wherever it
    %% actually samples hardware; here a timer stands in for that, publishing
    %% a simulated temperature reading every 5s.
    {ok, _Tref} = timer:apply_interval(5000, ?MODULE, tick, []),
    {ok, _Pid}.

stop() ->
    iec60870:stop_server(?SERVER).

-doc """
Publish a simulated temperature reading. Exported so
`timer:apply_interval/4` can call it; also handy to call by hand from the
shell to see a spontaneous ASDU go out immediately. A real RTU would read
actual hardware here instead of a deterministic wave.
""".
tick() ->
    Now = erlang:system_time(millisecond),
    Value = round((21.5 + 2 * math:sin(Now / 60000)) * 10) / 10,
    iec60870_server:update(?SERVER, {?COA, 200}, #{type => m_me_nc_1, value => Value}).
