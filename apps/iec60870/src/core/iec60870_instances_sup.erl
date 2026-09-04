-module(iec60870_instances_sup).
-moduledoc """
Dynamic supervisor for library-managed instances.

Each child is a per-server (later also per-client) supervision subtree —
see `docs/DESIGN.md` section 3. Children are added from phase 1 onwards via
`iec60870:start_server/2`; for now this supervisor starts empty.
""".
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    SupFlags = #{strategy => one_for_one,
                 intensity => 10,
                 period => 60},
    {ok, {SupFlags, []}}.
