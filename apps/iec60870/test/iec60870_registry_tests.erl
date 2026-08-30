-module(iec60870_registry_tests).

-include_lib("eunit/include/eunit.hrl").

basic_register_test() ->
    {ok, Reg} = iec60870_registry:start_link(),
    try
        Self = self(),
        ?assertEqual(yes, iec60870_registry:register_name(inst_a, Self)),
        ?assertEqual(no, iec60870_registry:register_name(inst_a, Self)),
        ?assertEqual(Self, iec60870_registry:whereis_name(inst_a)),
        ?assertEqual(undefined, iec60870_registry:whereis_name(missing)),
        ?assertEqual([{inst_a, Self}], iec60870_registry:names()),
        ?assertEqual(ok, iec60870_registry:unregister_name(inst_a)),
        ?assertEqual(undefined, iec60870_registry:whereis_name(inst_a))
    after
        gen_server:stop(Reg)
    end.

send_via_name_test() ->
    {ok, Reg} = iec60870_registry:start_link(),
    try
        ?assertEqual(yes, iec60870_registry:register_name(inst_b, self())),
        iec60870_registry:send(inst_b, hello),
        ?assertEqual(hello, receive M -> M after 1000 -> timeout end),
        ?assertExit({badarg, _}, iec60870_registry:send(nobody, hello))
    after
        gen_server:stop(Reg)
    end.

down_cleanup_test() ->
    {ok, Reg} = iec60870_registry:start_link(),
    try
        {Pid, MRef} = spawn_monitor(fun() -> receive release -> ok end end),
        ?assertEqual(yes, iec60870_registry:register_name(inst_c, Pid)),
        Pid ! release,
        receive {'DOWN', MRef, process, Pid, _} -> ok after 1000 -> ?assert(false) end,
        ?assert(wait_until(fun() ->
            iec60870_registry:whereis_name(inst_c) =:= undefined
        end, 100))
    after
        gen_server:stop(Reg)
    end.

wait_until(_Pred, 0) -> false;
wait_until(Pred, N) ->
    case Pred() of
        true -> true;
        false -> timer:sleep(10), wait_until(Pred, N - 1)
    end.
