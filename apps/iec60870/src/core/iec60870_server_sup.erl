%%% @doc Per-server supervision subtree (docs/DESIGN.md section 3).
%%%
%%% Phase-3 shape: a single `iec60870_server_ctl' worker, which is also the
%%% connection owner and (for now) starts the `ranch' listener itself and owns
%%% the default data model's ETS table. The `rest_for_one' strategy and the
%%% dedicated `rgroup_sup' / `conn_sup' / data-model children arrive with
%%% phase 5.
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
        [#{id => iec60870_server_ctl,
           start => {iec60870_server_ctl, start_link, [Name, Config]},
           type => worker,
           restart => permanent,
           shutdown => 5000,
           modules => [iec60870_server_ctl]}],
    {ok, {SupFlags, Children}}.
