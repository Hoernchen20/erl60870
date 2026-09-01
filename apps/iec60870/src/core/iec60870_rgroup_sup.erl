%%% @doc Supervisor for a server's redundancy groups (docs/DESIGN.md
%%% sections 3, 5).
%%%
%%% `one_for_one'. For `redundancy.mode' `single' / `multiple' the configured
%%% groups are permanent static children started here; for `connection' mode a
%%% fresh temporary group is started per accepted connection via
%%% {@link start_dynamic/4}. Registers itself as `{rgroup_sup, Name}' in
%%% {@link iec60870_registry} so {@link iec60870_server_ctl} can find it
%%% (they are siblings started in the same supervisor init).
-module(iec60870_rgroup_sup).
-behaviour(supervisor).

-export([start_link/2, start_dynamic/4, group_pid/2, which_groups/1]).
-export([init/1]).

-spec start_link(term(), map()) -> supervisor:startlink_ret().
start_link(Name, Config) ->
    supervisor:start_link(?MODULE, {Name, Config}).

%% @doc Start a fresh temporary group for one connection (`connection' mode).
-spec start_dynamic(pid(), pos_integer(), term(), pid()) ->
        supervisor:startchild_ret().
start_dynamic(Sup, BufferMax, Name, ConnPid) ->
    Id = make_ref(),
    Spec = #{id => Id,
             start => {iec60870_rgroup, start_link,
                       [Id, #{buffer_max => BufferMax, ephemeral => true,
                              initial_member => ConnPid}, Name]},
             restart => temporary, shutdown => 5000, type => worker,
             modules => [iec60870_rgroup]},
    supervisor:start_child(Sup, Spec).

%% @doc The pid of the static group with id `Id', or `undefined'.
-spec group_pid(pid(), term()) -> pid() | undefined.
group_pid(Sup, Id) ->
    case lists:keyfind(Id, 1, supervisor:which_children(Sup)) of
        {Id, Pid, _, _} when is_pid(Pid) -> Pid;
        _ -> undefined
    end.

%% @doc Every currently running group.
-spec which_groups(pid()) -> [pid()].
which_groups(Sup) ->
    [Pid || {_, Pid, _, _} <- supervisor:which_children(Sup), is_pid(Pid)].

-spec init({term(), map()}) ->
        {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init({Name, Config}) ->
    _ = iec60870_registry:unregister_name({rgroup_sup, Name}),
    yes = iec60870_registry:register_name({rgroup_sup, Name}, self()),
    Red = maps:get(redundancy, Config, #{}),
    DefaultBuffer = maps:get(buffer, Red, 1000),
    Specs = case maps:get(mode, Red, connection) of
                connection ->
                    [];
                single ->
                    [group_spec(default, DefaultBuffer, Name)];
                multiple ->
                    Groups = maps:get(groups, Red, []),
                    DefaultCfg = maps:get(default, Red, #{}),
                    [group_spec(maps:get(name, G),
                                maps:get(buffer, G, DefaultBuffer), Name)
                     || G <- Groups]
                    ++ [group_spec(default,
                                   maps:get(buffer, DefaultCfg, DefaultBuffer),
                                   Name)]
            end,
    SupFlags = #{strategy => one_for_one, intensity => 10, period => 60},
    {ok, {SupFlags, Specs}}.

group_spec(Id, BufferMax, Name) ->
    #{id => Id,
      start => {iec60870_rgroup, start_link,
                [Id, #{buffer_max => BufferMax}, Name]},
      restart => permanent, shutdown => 5000, type => worker,
      modules => [iec60870_rgroup]}.
