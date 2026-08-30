%%% @doc Application root supervisor.
%%%
%%% Owns two long-lived children (docs/DESIGN.md section 3):
%%%
%%%   * `iec60870_registry'       — instance name -> pid lookup
%%%   * `iec60870_instances_sup'  — dynamic supervisor holding the per-instance
%%%                                 subtrees created via `iec60870:start_server/2'
-module(iec60870_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec init([]) ->
        {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    SupFlags = #{strategy => one_for_one,
                 intensity => 4,
                 period => 30},
    Children =
        [#{id => iec60870_registry,
           start => {iec60870_registry, start_link, []},
           type => worker,
           restart => permanent,
           shutdown => 5000,
           modules => [iec60870_registry]},
         #{id => iec60870_instances_sup,
           start => {iec60870_instances_sup, start_link, []},
           type => supervisor,
           restart => permanent,
           shutdown => infinity,
           modules => [iec60870_instances_sup]}],
    {ok, {SupFlags, Children}}.
