%%% @doc Per-server supervision subtree (docs/DESIGN.md section 3).
%%%
%%% `rest_for_one', children in start order:
%%%
%%% <ol>
%%%   <li>{@link iec60870_rgroup_sup} — the redundancy groups. Started first so
%%%       {@link iec60870_server_ctl} can resolve it (`{rgroup_sup, Name}' in
%%%       {@link iec60870_registry}). A ctl-only crash therefore leaves the
%%%       groups, their buffered events and the live connections intact.</li>
%%%   <li>{@link iec60870_server_ctl} — config, data model, callback state,
%%%       command routing; also starts the `ranch' listener (interim — see the
%%%       phase-3 note in docs/DESIGN.md section 3).</li>
%%% </ol>
-module(iec60870_server_sup).
-behaviour(supervisor).

-export([start_link/2, ctl/1]).
-export([init/1]).

-spec start_link(term(), map()) -> supervisor:startlink_ret().
start_link(Name, Config) ->
    supervisor:start_link(?MODULE, {Name, Config}).

%% @doc The `iec60870_server_ctl' pid of a running subtree, or `undefined'.
-spec ctl(pid()) -> pid() | undefined.
ctl(Sup) ->
    case lists:keyfind(iec60870_server_ctl, 1, supervisor:which_children(Sup)) of
        {_, Pid, _, _} when is_pid(Pid) -> Pid;
        _ -> undefined
    end.

-spec init({term(), map()}) ->
        {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init({Name, Config}) ->
    SupFlags = #{strategy => rest_for_one, intensity => 4, period => 30},
    Children =
        [#{id => iec60870_rgroup_sup,
           start => {iec60870_rgroup_sup, start_link, [Name, Config]},
           type => supervisor,
           restart => permanent,
           shutdown => infinity,
           modules => [iec60870_rgroup_sup]},
         #{id => iec60870_server_ctl,
           start => {iec60870_server_ctl, start_link, [Name, Config]},
           type => worker,
           restart => permanent,
           shutdown => 5000,
           modules => [iec60870_server_ctl]}],
    {ok, {SupFlags, Children}}.
